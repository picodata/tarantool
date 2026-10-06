/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2026, Tarantool AUTHORS, please see AUTHORS file.
 */

/*
 * Sampling of the instructions of EXPLAIN ANALYZE. While the statement
 * runs, its timer sends a signal a number of times a second of the CPU
 * time of the thread (99 by default). If the fiber of the statement runs,
 * the handler of the signal adds 1 to the sample count of the instruction
 * that the statement is in.
 *
 * The statement tells the handler where it is with the pointer
 * VdbeExplain.op_perf. Each instruction of the run sets it, and it
 * is NULL when the statement is in no instruction, for example between two
 * runs. An instruction can call a function that runs other statements:
 * they do not change this pointer, so their time is the time of the
 * instruction.
 *
 * The mode "wait_samples" has a second timer, on the wall clock. It also
 * sends its signal while the fiber of the statement waits: the thread
 * runs other fibers or sleeps in the event loop. Then the handler adds 1
 * to the wait samples of the instruction that the statement is in. The
 * timer of the CPU time cannot do this, because it does not count while
 * the thread sleeps.
 */
#include "sqlInt.h"
#include "vdbeInt.h"
#include "fiber.h"
#include "diag.h"

#include <errno.h>

#ifdef VDBE_HAS_SAMPLES

#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef sigev_notify_thread_id
#define sigev_notify_thread_id _sigev_un._tid
#endif

/*
 * The signal of the timers. SIGPROF is not used: the profilers of LuaJIT
 * use it, and they restore their old handler of SIGPROF when they stop,
 * even if a timer of EXPLAIN ANALYZE still runs.
 *
 * The signal must have its default action when the first sampling starts.
 * If another part of the process uses it, the sampling does not start.
 * The signal has the default action again when the last sampling stops.
 */
#define VDBE_SAMPLE_SIGNAL SIGRTMIN

/** The samplings that run now. */
static RLIST_HEAD(vdbe_samples);

/**
 * The value of the signal of a timer is the address of its sampling. The
 * timer of the wall clock also sets the lowest bit of the address, which
 * is 0 because of the alignment of the structure.
 */
enum {
	VDBE_SAMPLE_WAIT_BIT = 1,
};

/** Find the sampling whose timer sent the signal. */
static VdbeSample *
vdbe_sample_find(const siginfo_t *info)
{
	if (info->si_code != SI_TIMER)
		return NULL;
	uintptr_t value = (uintptr_t)info->si_value.sival_ptr;
	value &= ~(uintptr_t)VDBE_SAMPLE_WAIT_BIT;
	VdbeSample *sample;
	rlist_foreach_entry(sample, &vdbe_samples, link) {
		if ((uintptr_t)sample == value)
			return sample;
	}
	return NULL;
}

/** Handle the signal of a timer. */
static void
vdbe_sample_handler(int signo, siginfo_t *info, void *context)
{
	(void)signo;
	(void)context;
	VdbeSample *sample = vdbe_sample_find(info);
	if (sample == NULL)
		return;
	VdbeOpPerfStats *perf =
		__atomic_load_n(&sample->vdbe->explain_data->op_perf,
				__ATOMIC_RELAXED);
	if (perf == NULL)
		return;
	bool is_running = sample->fiber == fiber();
	uintptr_t value = (uintptr_t)info->si_value.sival_ptr;
	if ((value & VDBE_SAMPLE_WAIT_BIT) != 0) {
		/* The statement waits in the instruction that it started. */
		if (!is_running)
			perf->wait_sample_count++;
		return;
	}
	if (is_running)
		perf->sample_count++;
}

/** Add a sampling to the list or delete it from the list. */
static void
vdbe_sample_link(VdbeSample *sample, bool is_added)
{
	/* The handler reads the list, so it must not see it change. */
	sigset_t set;
	sigset_t old;
	sigemptyset(&set);
	sigaddset(&set, VDBE_SAMPLE_SIGNAL);
	pthread_sigmask(SIG_BLOCK, &set, &old);
	if (is_added)
		rlist_add_entry(&vdbe_samples, sample, link);
	else
		rlist_del_entry(sample, link);
	pthread_sigmask(SIG_SETMASK, &old, NULL);
}

/**
 * Set the handler of the signal. Fail with EBUSY if the signal does not
 * have its default action: then another part of the process uses it.
 */
static int
vdbe_sample_set_handler(void)
{
	struct sigaction action;
	struct sigaction old_action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = vdbe_sample_handler;
	action.sa_flags = SA_SIGINFO | SA_RESTART;
	sigemptyset(&action.sa_mask);
	if (sigaction(VDBE_SAMPLE_SIGNAL, &action, &old_action) != 0)
		return -1;
	if ((old_action.sa_flags & SA_SIGINFO) == 0 &&
	    old_action.sa_handler == SIG_DFL)
		return 0;
	sigaction(VDBE_SAMPLE_SIGNAL, &old_action, NULL);
	errno = EBUSY;
	return -1;
}

/** Give the signal its default action again. Keep errno. */
static void
vdbe_sample_reset_handler(void)
{
	int saved_errno = errno;
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = SIG_DFL;
	sigemptyset(&action.sa_mask);
	sigaction(VDBE_SAMPLE_SIGNAL, &action, NULL);
	errno = saved_errno;
}

/**
 * Create a timer of a sampling on a clock and start it. value is the
 * value of its signal.
 */
static int
vdbe_sample_start_timer(clockid_t clock, void *value, int freq, timer_t *timer)
{
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_THREAD_ID;
	event.sigev_signo = VDBE_SAMPLE_SIGNAL;
	event.sigev_value.sival_ptr = value;
	event.sigev_notify_thread_id = syscall(SYS_gettid);
	if (timer_create(clock, &event, timer) != 0)
		return -1;
	const long nsec_in_sec = 1000000000;
	long interval = nsec_in_sec / freq;
	struct itimerspec spec;
	memset(&spec, 0, sizeof(spec));
	spec.it_interval.tv_sec = interval / nsec_in_sec;
	spec.it_interval.tv_nsec = interval % nsec_in_sec;
	spec.it_value = spec.it_interval;
	if (timer_settime(*timer, 0, &spec, NULL) == 0)
		return 0;
	int saved_errno = errno;
	timer_delete(*timer);
	errno = saved_errno;
	return -1;
}

/** Delete the timers of a sampling. Keep errno. */
static void
vdbe_sample_delete_timers(VdbeSample *sample)
{
	int saved_errno = errno;
	if (sample->has_cpu_timer)
		timer_delete(sample->cpu_timer);
	if (sample->has_wait_timer)
		timer_delete(sample->wait_timer);
	sample->has_cpu_timer = false;
	sample->has_wait_timer = false;
	errno = saved_errno;
}

/** Create and start the timers that the modes of the statement need. */
static int
vdbe_sample_start_timers(VdbeSample *sample)
{
	struct Vdbe *p = sample->vdbe;
	int freq = p->explain_data->opts.sample_freq;
	uint8_t mode = p->explain_data->opts.analyze_mode;
	if ((mode & EXPLAIN_ANALYZE_SAMPLES) != 0) {
		if (vdbe_sample_start_timer(CLOCK_THREAD_CPUTIME_ID, sample,
					    freq, &sample->cpu_timer) != 0)
			return -1;
		sample->has_cpu_timer = true;
	}
	if ((mode & EXPLAIN_ANALYZE_WAIT_SAMPLES) != 0) {
		void *value = (char *)sample + VDBE_SAMPLE_WAIT_BIT;
		if (vdbe_sample_start_timer(CLOCK_MONOTONIC, value, freq,
					    &sample->wait_timer) != 0) {
			vdbe_sample_delete_timers(sample);
			return -1;
		}
		sample->has_wait_timer = true;
	}
	return 0;
}

int
vdbe_sample_start(VdbeSample *sample, struct Vdbe *p)
{
	bool is_first = rlist_empty(&vdbe_samples);
	if (is_first && vdbe_sample_set_handler() != 0)
		goto error;
	sample->vdbe = p;
	sample->fiber = fiber();
	sample->has_cpu_timer = false;
	sample->has_wait_timer = false;
	p->explain_data->op_perf = NULL;
	vdbe_sample_link(sample, true);
	if (vdbe_sample_start_timers(sample) == 0)
		return 0;
	vdbe_sample_link(sample, false);
	if (is_first)
		vdbe_sample_reset_handler();
error:
	diag_set(SystemError, "EXPLAIN ANALYZE cannot sample the "
		 "instructions");
	return -1;
}

/**
 * Stop to sample. When timer_delete() returns, the thread has got all the
 * signals of the timer, so the sampling can leave the list, and the
 * default action of the signal does not get them.
 */
void
vdbe_sample_stop(VdbeSample *sample)
{
	vdbe_sample_delete_timers(sample);
	vdbe_sample_link(sample, false);
	if (rlist_empty(&vdbe_samples))
		vdbe_sample_reset_handler();
}

#else /* VDBE_HAS_SAMPLES */

/** This build cannot sample: fail as if the timer cannot start. */
int
vdbe_sample_start(VdbeSample *sample, struct Vdbe *p)
{
	(void)sample;
	(void)p;
	errno = ENOTSUP;
	diag_set(SystemError, "EXPLAIN ANALYZE cannot sample the "
		 "instructions");
	return -1;
}

void
vdbe_sample_stop(VdbeSample *sample)
{
	(void)sample;
}

#endif /* VDBE_HAS_SAMPLES */
