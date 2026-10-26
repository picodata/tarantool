/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2026, Tarantool AUTHORS, please see AUTHORS file.
 */
#pragma once

/**
 * Counter of the CPU instructions that the current thread executes.
 * On Linux it uses a hardware performance counter (perf_event) and
 * counts only user space. On macOS it uses the counters of the thread
 * (thread_selfcounts()), which count the kernel too.
 * Not thread-safe: open, read and close the counter in one thread.
 */

#include <stdbool.h>
#include <stdint.h>

#if __cplusplus
extern "C" {
#endif

#if defined(__linux__)

struct perf_event_mmap_page;

/**
 * Maximal number of perf events of a counter: one for each type of CPU
 * core, for example the P-cores and the E-cores of a hybrid CPU.
 */
enum { INSN_COUNTER_EVENT_MAX = 4 };

/** One perf event of struct insn_counter. */
struct insn_counter_event {
	/** The perf_event file descriptor. */
	int fd;
	/**
	 * The first page of the event, mapped to memory. It lets us read
	 * the event with the rdpmc instruction instead of a system call.
	 * NULL if it is not mapped, always on the architectures without
	 * rdpmc.
	 */
	struct perf_event_mmap_page *page;
	/** The last value read from the event. */
	uint64_t value;
	/**
	 * The lock of the page when `value` was read with a system call
	 * while the event was not on a hardware counter. While the lock
	 * stays the same, the event does not count, and `value` is valid.
	 */
	uint32_t lock;
	/** True if `lock` is set. */
	bool is_lock_valid;
};

/**
 * Counter of the user-space CPU instructions of one thread.
 *
 * A perf event of a hybrid CPU counts only on one type of cores, so the
 * counter has one event for each type and adds their values. Only one
 * event is on a hardware counter at a time: the one of the core where
 * the thread runs.
 */
struct insn_counter {
	/** The events, `event_count` of them. */
	struct insn_counter_event events[INSN_COUNTER_EVENT_MAX];
	/** The number of the events, 0 if the counter is closed. */
	int event_count;
};

/** Return true if the counter is open. */
static inline bool
insn_counter_is_open(const struct insn_counter *counter)
{
	return counter->event_count > 0;
}

#else /* !defined(__linux__) */

/**
 * Counter of the CPU instructions of one thread, which reads the
 * counter of the system.
 */
struct insn_counter {
	/** The value of the counter of the system when it was opened. */
	uint64_t base;
	/** The last value read from the counter of the system. */
	uint64_t value;
	/** True if the counter is open. */
	bool is_open;
};

/** Return true if the counter is open. */
static inline bool
insn_counter_is_open(const struct insn_counter *counter)
{
	return counter->is_open;
}

#endif /* !defined(__linux__) */

/** Initialize a closed counter. */
void
insn_counter_create(struct insn_counter *counter);

/**
 * Open the counter for the current thread. The counter starts at 0.
 * The counter keeps a hardware counter all the time, so it counts all
 * the instructions. It fails if no hardware counter is free.
 * Returns 0 on success, -1 and sets diag on failure.
 */
int
insn_counter_open(struct insn_counter *counter);

/** Close the counter. Do nothing if it is closed. */
void
insn_counter_close(struct insn_counter *counter);

/**
 * Open the counter with one event for each PMU type in `types`. If
 * `count` is 0, open one event that the kernel puts on the default PMU.
 * For tests, use insn_counter_open() in other code. Only on Linux.
 */
int
insn_counter_open_pmus(struct insn_counter *counter, const uint32_t *types,
		       int count);

/**
 * Find the PMUs of the CPU cores in a directory like
 * /sys/bus/event_source/devices. Write their perf types to `types`.
 * Return the number of the PMUs. If there are more than `max`, return
 * max + 1 and write only `max` of them. Return -1 and keep errno if the
 * directory cannot be read. For tests. Only on Linux.
 */
int
insn_counter_find_core_pmus(const char *dir, uint32_t *types, int max);

/** The directory of the PMUs in sysfs. Tests change it. Only on Linux. */
extern const char *insn_counter_pmu_dir;

/**
 * Return the number of instructions that the current thread has
 * executed since the counter was opened.
 * The counter must be open.
 */
uint64_t
insn_counter_read(struct insn_counter *counter);

#if __cplusplus
}
#endif
