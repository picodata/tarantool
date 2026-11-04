/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2026, Tarantool AUTHORS, please see AUTHORS file.
 */
#include "insn_counter.h"

#include <assert.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

#include "diag.h"
#include "small/util.h"

#if defined(__linux__)
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#else
#include <errno.h>
#include "trivia/util.h"
#endif

#if defined(__linux__)

void
insn_counter_create(struct insn_counter *counter)
{
	counter->event_count = 0;
}

#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
/** The events can be read in user space with the rdpmc instruction. */
#define INSN_COUNTER_HAS_RDPMC 1
#endif

#ifndef PERF_PMU_TYPE_SHIFT
/* The PMU type of a PERF_TYPE_HARDWARE event, since Linux 5.13. */
#define PERF_PMU_TYPE_SHIFT 32
#endif

const char *insn_counter_pmu_dir = "/sys/bus/event_source/devices";

/**
 * Return true if the CPU is known to have one type of cores. Only x86
 * tells it, with the hybrid flag of CPUID.
 */
static bool
insn_counter_cpu_is_uniform(void)
{
#if defined(__x86_64__) || defined(__i386__)
	unsigned int eax, ebx, ecx, edx;
	/*
	 * A CPU without leaf 7 is older than the hybrid CPUs.
	 * __get_cpuid_count() would be shorter, but GCC has it since 7.
	 */
	if (__get_cpuid_max(0, NULL) < 7)
		return true;
	__cpuid_count(7, 0, eax, ebx, ecx, edx);
	return (edx & (1U << 15)) == 0;
#else
	return false;
#endif
}

int
insn_counter_find_core_pmus(const char *dir, uint32_t *types, int max)
{
	DIR *d = opendir(dir);
	if (d == NULL)
		return -1;
	int count = 0;
	struct dirent *entry;
	while ((entry = readdir(d)) != NULL && count <= max) {
		if (entry->d_name[0] == '.')
			continue;
		/* Only the PMUs of CPU cores have the file "cpus". */
		char path[PATH_MAX];
		snprintf(path, sizeof(path), "%s/%s/cpus", dir, entry->d_name);
		if (access(path, F_OK) != 0)
			continue;
		snprintf(path, sizeof(path), "%s/%s/type", dir, entry->d_name);
		FILE *f = fopen(path, "r");
		if (f == NULL)
			continue;
		unsigned int type;
		int rc = fscanf(f, "%u", &type);
		fclose(f);
		if (rc != 1)
			continue;
		if (count < max)
			types[count] = type;
		count++;
	}
	closedir(d);
	return count;
}

/**
 * Open a perf event of the user-space instructions of the current
 * thread. Return 0 on success, -1 and set diag on failure.
 */
static int
insn_counter_event_open(struct insn_counter_event *event, uint64_t config)
{
	struct perf_event_attr attr;
	memset(&attr, 0, sizeof(attr));
	attr.size = sizeof(attr);
	attr.type = PERF_TYPE_HARDWARE;
	attr.config = config;
	/*
	 * Count only user space. This is permitted to unprivileged
	 * processes with the default kernel.perf_event_paranoid = 2.
	 */
	attr.exclude_kernel = 1;
	attr.exclude_hv = 1;
	/*
	 * If there are more events than hardware counters, the kernel
	 * multiplexes them, and each event counts only a part of the
	 * time. A pinned event always stays on a hardware counter. If no
	 * counter is free, it goes into an error state and does not count.
	 */
	attr.pinned = 1;
	int fd = syscall(SYS_perf_event_open, &attr, /*pid=*/0, /*cpu=*/-1,
			 /*group_fd=*/-1, PERF_FLAG_FD_CLOEXEC);
	if (fd < 0) {
		diag_set(SystemError, "failed to open a perf event of "
			 "CPU instructions");
		return -1;
	}
	void *page = MAP_FAILED;
#if defined(INSN_COUNTER_HAS_RDPMC)
	/*
	 * If the mapping fails, the event still works, but it is read
	 * with a slow system call.
	 *
	 * Map the page before the first read(). A read() stores the raw
	 * value of the hardware counter in the kernel, and the offset of
	 * a page that is mapped after that is wrong by 2^48 until the
	 * thread is rescheduled.
	 */
	page = mmap(NULL, small_getpagesize(), PROT_READ, MAP_SHARED, fd, 0);
#endif
	/* A read of an event in the error state gives 0 bytes. */
	uint64_t value;
	ssize_t rc = read(fd, &value, sizeof(value));
	if (rc != sizeof(value)) {
		int saved_errno = errno;
		if (page != MAP_FAILED)
			munmap(page, small_getpagesize());
		close(fd);
		if (rc == 0) {
			errno = EBUSY;
			diag_set(SystemError, "no free hardware counter for "
				 "CPU instructions");
		} else {
			errno = saved_errno;
			diag_set(SystemError, "failed to read a perf event of "
				 "CPU instructions");
		}
		return -1;
	}
	event->fd = fd;
	event->page = page != MAP_FAILED ? page : NULL;
	event->value = 0;
	event->is_lock_valid = false;
	return 0;
}

int
insn_counter_open_pmus(struct insn_counter *counter, const uint32_t *types,
		       int count)
{
	assert(!insn_counter_is_open(counter));
	assert(count >= 0 && count <= INSN_COUNTER_EVENT_MAX);
	int event_count = count > 0 ? count : 1;
	for (int i = 0; i < event_count; i++) {
		uint64_t config = PERF_COUNT_HW_INSTRUCTIONS;
		if (count > 0)
			config |= (uint64_t)types[i] << PERF_PMU_TYPE_SHIFT;
		if (insn_counter_event_open(&counter->events[i], config) != 0) {
			counter->event_count = i;
			insn_counter_close(counter);
			return -1;
		}
	}
	counter->event_count = event_count;
	return 0;
}

int
insn_counter_open(struct insn_counter *counter)
{
	uint32_t types[INSN_COUNTER_EVENT_MAX];
	int count = insn_counter_find_core_pmus(insn_counter_pmu_dir, types,
						INSN_COUNTER_EVENT_MAX);
	if (count < 0) {
		/*
		 * The PMUs cannot be listed, for example, in a container
		 * without sysfs. One event without a PMU type is correct
		 * if the CPU has one type of cores.
		 */
		if (insn_counter_cpu_is_uniform())
			return insn_counter_open_pmus(counter, NULL, 0);
		diag_set(SystemError, "failed to list the PMUs in %s to count "
			 "CPU instructions", insn_counter_pmu_dir);
		return -1;
	}
	if (count > INSN_COUNTER_EVENT_MAX) {
		errno = ENOTSUP;
		diag_set(SystemError, "too many types of CPU cores to count "
			 "CPU instructions");
		return -1;
	}
	/*
	 * A CPU with one type of cores needs one event. A CPU with
	 * several types of cores needs one event for each type. If they
	 * cannot be opened, for example on a kernel before Linux 5.13,
	 * the counter is unavailable: one event would count only on the
	 * cores of one type, and nothing would tell that.
	 */
	if (count > 1)
		return insn_counter_open_pmus(counter, types, count);
	return insn_counter_open_pmus(counter, NULL, 0);
}

void
insn_counter_close(struct insn_counter *counter)
{
	for (int i = 0; i < counter->event_count; i++) {
		struct insn_counter_event *event = &counter->events[i];
		if (event->page != NULL)
			munmap(event->page, small_getpagesize());
		close(event->fd);
	}
	insn_counter_create(counter);
}

/**
 * Read an event with a system call. If `lock` is not NULL, it is the
 * lock of the page of the event, which is not on a hardware counter.
 */
static uint64_t
insn_counter_event_read_slow(struct insn_counter_event *event,
			     const uint32_t *lock)
{
	uint64_t value;
	ssize_t rc = read(event->fd, &value, sizeof(value));
	event->is_lock_valid = false;
	if (rc == sizeof(value)) {
		event->value = value;
		if (lock != NULL) {
			event->lock = *lock;
			event->is_lock_valid = true;
		}
	} else if (rc == 0) {
		/*
		 * The event is in the error state: other pinned events took
		 * all the hardware counters. Enable it again, so that the
		 * kernel tries to put it on a counter at the next context
		 * switch. The instructions until then are not counted.
		 */
		ioctl(event->fd, PERF_EVENT_IOC_ENABLE, 0);
	}
	/* Keep the last value if the read fails, so it does not go back. */
	return event->value;
}

#if defined(INSN_COUNTER_HAS_RDPMC)

/**
 * Order execution around RDPMC. See Intel SDM, rev. 093 (September
 * 2026), order no. 325462-093US:
 * - Vol. 2B, Ch. 4, "RDPMC", Description, p. 4-552: exact event counts
 *   require a serializing instruction before and/or after RDPMC.
 * - Vol. 2A, Ch. 3, "LFENCE", Description, p. 3-552: all prior
 *   instructions complete locally before LFENCE, and no later
 *   instruction begins execution until LFENCE completes.
 */
static inline void
insn_counter_serialize(void)
{
	__atomic_signal_fence(__ATOMIC_SEQ_CST);
	__asm__ volatile("lfence" ::: "memory");
	__atomic_signal_fence(__ATOMIC_SEQ_CST);
}

/**
 * Read an event in user space with the rdpmc instruction.
 * See the description of struct perf_event_mmap_page in
 * <linux/perf_event.h>. Fall back to the system call when rdpmc
 * is not permitted.
 *
 * If the event is not on a hardware counter now, for example because
 * the thread runs on a core of another type, it does not count. Its
 * value changes only after the kernel changes the page. So read it with
 * the system call only once after each change of the page.
 */
static uint64_t
insn_counter_event_read_fast(struct insn_counter_event *event)
{
	struct perf_event_mmap_page *pc = event->page;
	uint32_t seq;
	uint64_t value;
	/*
	 * The kernel changes the page at any time. Load each field once,
	 * so that rdpmc gets the index that was checked.
	 */
	do {
		seq = __atomic_load_n(&pc->lock, __ATOMIC_RELAXED);
		__atomic_signal_fence(__ATOMIC_SEQ_CST);
		uint32_t idx = __atomic_load_n(&pc->index, __ATOMIC_RELAXED);
		uint16_t width = __atomic_load_n(&pc->pmc_width,
						 __ATOMIC_RELAXED);
		if (!pc->cap_user_rdpmc || width == 0 || width > 64)
			return insn_counter_event_read_slow(event, NULL);
		if (idx == 0) {
			if (event->is_lock_valid && event->lock == seq)
				return event->value;
			return insn_counter_event_read_slow(event, &seq);
		}
		value = __atomic_load_n(&pc->offset, __ATOMIC_RELAXED);
		uint32_t lo, hi;
		insn_counter_serialize();
		__asm__ volatile("rdpmc" : "=a"(lo), "=d"(hi) : "c"(idx - 1));
		insn_counter_serialize();
		/* Sign-extend the pmc_width bits of the hardware counter. */
		unsigned int shift = 64 - width;
		int64_t pmc = (int64_t)(((uint64_t)hi << 32 | lo) << shift);
		value += (uint64_t)(pmc >> shift);
		__atomic_signal_fence(__ATOMIC_SEQ_CST);
	} while (__atomic_load_n(&pc->lock, __ATOMIC_RELAXED) != seq);
	event->value = value;
	return value;
}

#endif /* defined(INSN_COUNTER_HAS_RDPMC) */

/** Read one event of the counter. */
static uint64_t
insn_counter_event_read(struct insn_counter_event *event)
{
#if defined(INSN_COUNTER_HAS_RDPMC)
	if (event->page != NULL)
		return insn_counter_event_read_fast(event);
#endif
	return insn_counter_event_read_slow(event, NULL);
}

uint64_t
insn_counter_read(struct insn_counter *counter)
{
	assert(insn_counter_is_open(counter));
	uint64_t value = 0;
	for (int i = 0; i < counter->event_count; i++)
		value += insn_counter_event_read(&counter->events[i]);
	return value;
}

#else /* !defined(__linux__) */

void
insn_counter_create(struct insn_counter *counter)
{
	counter->base = 0;
	counter->value = 0;
	counter->is_open = false;
}

int
insn_counter_find_core_pmus(const char *dir, uint32_t *types, int max)
{
	(void)dir;
	(void)types;
	(void)max;
	return 0;
}

int
insn_counter_open_pmus(struct insn_counter *counter, const uint32_t *types,
		       int count)
{
	(void)counter;
	(void)types;
	(void)count;
	errno = ENOTSUP;
	diag_set(SystemError, "perf events of PMUs are supported only on "
		 "Linux");
	return -1;
}

void
insn_counter_close(struct insn_counter *counter)
{
	counter->is_open = false;
}

#if defined(__APPLE__)

/**
 * The performance counters of the current thread since its start, from
 * XNU. It is not in the public headers, see bsd/sys/resource_private.h.
 */
extern int
thread_selfcounts(int kind, void *buf, size_t size);

/** The kind of thread_selfcounts() that gives struct thsc_cpi. */
enum { THSC_CPI = 1 };

/** The counters of THSC_CPI, the same on all the architectures. */
struct thsc_cpi {
	/** The instructions executed by the thread. */
	uint64_t tcpi_instructions;
	/** The CPU cycles of the thread. */
	uint64_t tcpi_cycles;
};

/**
 * Read the counter of the instructions of the thread from the system.
 * Return 0 on success, -1 and keep errno on failure. It does not set
 * diag: a read at a context switch must not replace the error of the
 * fiber.
 */
static int
insn_counter_read_system(uint64_t *value)
{
	struct thsc_cpi counts;
	if (thread_selfcounts(THSC_CPI, &counts, sizeof(counts)) != 0)
		return -1;
	*value = counts.tcpi_instructions;
	return 0;
}

int
insn_counter_open(struct insn_counter *counter)
{
	assert(!insn_counter_is_open(counter));
	uint64_t value;
	if (insn_counter_read_system(&value) != 0) {
		diag_set(SystemError, "failed to read the CPU instructions "
			 "of the thread");
		return -1;
	}
	/*
	 * The thread has executed instructions since its start, so 0
	 * means that the system does not count them, for example, in a
	 * virtual machine.
	 */
	if (value == 0) {
		errno = ENOTSUP;
		diag_set(SystemError, "the system does not count the CPU "
			 "instructions of the thread");
		return -1;
	}
	counter->base = value;
	counter->value = value;
	counter->is_open = true;
	return 0;
}

uint64_t
insn_counter_read(struct insn_counter *counter)
{
	assert(insn_counter_is_open(counter));
	/* Keep the last value if the read fails, so it does not go back. */
	uint64_t value;
	if (insn_counter_read_system(&value) == 0)
		counter->value = value;
	return counter->value - counter->base;
}

#else /* !defined(__APPLE__) */

int
insn_counter_open(struct insn_counter *counter)
{
	(void)counter;
	errno = ENOTSUP;
	diag_set(SystemError, "CPU instruction counting is not supported "
		 "on this system");
	return -1;
}

uint64_t
insn_counter_read(struct insn_counter *counter)
{
	(void)counter;
	unreachable();
	return 0;
}

#endif /* !defined(__APPLE__) */

#endif /* !defined(__linux__) */
