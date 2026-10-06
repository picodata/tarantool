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

/** Find the sampling whose timer sent the signal. */
static VdbeSample *
vdbe_sample_find(const siginfo_t *info)
{
	if (info->si_code != SI_TIMER)
		return NULL;
	VdbeSample *sample;
	rlist_foreach_entry(sample, &vdbe_samples, link) {
		if (sample == info->si_value.sival_ptr)
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
	if (sample == NULL || sample->fiber != fiber())
		return;
	VdbeOpPerfStats *perf =
		__atomic_load_n(&sample->vdbe->explain_data->op_perf,
				__ATOMIC_RELAXED);
	if (perf != NULL)
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

/** Create the timer of a sampling and start it. */
static int
vdbe_sample_start_timer(VdbeSample *sample, int freq)
{
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_THREAD_ID;
	event.sigev_signo = VDBE_SAMPLE_SIGNAL;
	event.sigev_value.sival_ptr = sample;
	event.sigev_notify_thread_id = syscall(SYS_gettid);
	if (timer_create(CLOCK_THREAD_CPUTIME_ID, &event, &sample->timer) != 0)
		return -1;
	const long nsec_in_sec = 1000000000;
	long interval = nsec_in_sec / freq;
	struct itimerspec spec;
	memset(&spec, 0, sizeof(spec));
	spec.it_interval.tv_sec = interval / nsec_in_sec;
	spec.it_interval.tv_nsec = interval % nsec_in_sec;
	spec.it_value = spec.it_interval;
	if (timer_settime(sample->timer, 0, &spec, NULL) == 0)
		return 0;
	int saved_errno = errno;
	timer_delete(sample->timer);
	errno = saved_errno;
	return -1;
}

int
vdbe_sample_start(VdbeSample *sample, struct Vdbe *p)
{
	bool is_first = rlist_empty(&vdbe_samples);
	if (is_first && vdbe_sample_set_handler() != 0)
		goto error;
	sample->vdbe = p;
	sample->fiber = fiber();
	p->explain_data->op_perf = NULL;
	vdbe_sample_link(sample, true);
	int freq = p->explain_data->opts.sample_freq;
	if (vdbe_sample_start_timer(sample, freq) == 0)
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
	timer_delete(sample->timer);
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
