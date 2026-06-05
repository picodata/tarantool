#ifndef INCLUDES_TARANTOOL_BOX_VY_QUOTA_H
#define INCLUDES_TARANTOOL_BOX_VY_QUOTA_H
/*
 * Copyright 2010-2017, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <small/rlist.h>
#include <tarantool_ev.h>

#include "trivia/util.h"
#include "vy_quota_consumer.h"
#include "vy_regulator.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct fiber;
struct vy_scheduler;

/** Rate limit state. */
struct vy_rate_limit {
	/** Max allowed rate, per second. */
	size_t rate;
	/** Current quota. */
	ssize_t value;
};

/** Initialize a rate limit state. */
static inline void
vy_rate_limit_create(struct vy_rate_limit *rl)
{
	rl->rate = SIZE_MAX;
	rl->value = SSIZE_MAX;
}

/** Set rate limit. */
static inline void
vy_rate_limit_set(struct vy_rate_limit *rl, size_t rate)
{
	rl->rate = rate;
}

/**
 * Return true if quota may be consumed without exceeding
 * the configured rate limit.
 */
static inline bool
vy_rate_limit_may_use(struct vy_rate_limit *rl)
{
	return rl->value > 0;
}

/** Consume the given amount of quota. */
static inline void
vy_rate_limit_use(struct vy_rate_limit *rl, size_t size)
{
	rl->value -= size;
}

/**
 * Replenish quota by the amount accumulated for the given
 * time interval.
 */
static inline void
vy_rate_limit_refill(struct vy_rate_limit *rl, double time)
{
	double size = rl->rate * time;
	double value = rl->value + size;
	/* Allow bursts up to 2x rate. */
	value = MIN(value, size * 2);
	rl->value = MIN((ssize_t)value, SSIZE_MAX);
}

/**
 * Apart from memory usage accounting and limiting, vy_quota is
 * responsible for consumption rate limiting (aka throttling).
 * There are multiple rate limits, each of which is associated
 * with a particular resource type. Different kinds of consumers
 * respect different limits. The following enumeration defines
 * the resource types for which vy_quota enables throttling.
 *
 * See also vy_quota_consumer_resource_map.
 */
enum vy_quota_resource_type {
	/**
	 * The goal of disk-based throttling is to keep LSM trees
	 * in a good shape so that read and space amplification
	 * stay within bounds. It is enabled when compaction does
	 * not keep up with dumps.
	 */
	VY_QUOTA_RESOURCE_DISK = 0,
	/**
	 * Memory-based throttling is needed to avoid long stalls
	 * caused by hitting the memory size limit. It is set so
	 * that by the time the size limit is hit, the last memory
	 * dump will have completed.
	 */
	VY_QUOTA_RESOURCE_MEMORY = 1,

	vy_quota_resource_type_MAX,
};

struct vy_quota_wait_node {
	/** Link in vy_quota::wait_queue. */
	struct rlist in_wait_queue;
	/** Fiber waiting for quota. */
	struct fiber *fiber;
	/**
	 * Ticket assigned to this fiber when it was put to
	 * sleep, see vy_quota::wait_ticket for more details.
	 */
	int64_t ticket;
};

/**
 * Accounting half of the vinyl quota: the byte counters and rate
 * limits, split off from the wait queue and the regulator.
 *
 * Bytes are charged on the statement-insertion path (vy_mem_acct),
 * which runs in a no-yield window -- a transaction's statements
 * must all land in the same in-memory tree, so prepare does not
 * yield while inserting them. Accounting there therefore must not
 * block. Giving that path only a vy_quota_acct, with no pointer to
 * the wait queue, makes this guarantee structural rather than
 * conventional: there is nothing reachable here to wait on. The
 * waiting that admission needs is done earlier, in vy_quota_wait,
 * before the no-yield window.
 */
struct vy_quota_acct {
	/**
	 * Memory size limit, in bytes. Once used memory hits it,
	 * new transactions are throttled until memory is reclaimed.
	 */
	size_t size_limit;
	/** Current memory consumption, in bytes. */
	size_t used;
	/** Rate limit state, one per each resource type. */
	struct vy_rate_limit rate_limit[vy_quota_resource_type_MAX];
};

/**
 * Quota used for accounting and limiting memory consumption
 * in the vinyl engine. It is NOT multi-threading safe.
 */
struct vy_quota {
	/** See struct vy_quota_acct. */
	struct vy_quota_acct acct;
	/** Number of consumers waiting for quota. */
	int n_blocked;
	/**
	 * If vy_quota_wait() takes longer than the given
	 * value, warn about it in the log.
	 */
	double too_long_threshold;
	/**
	 * Reclaim policy: started in vy_quota_enable, fed memory usage
	 * by the timer and dump statistics at dump completion, and
	 * consulted for the dump watermark and the rate limits the quota
	 * installs.
	 */
	struct vy_regulator regulator;
	/**
	 * Scheduler the quota triggers dumps on when memory runs
	 * low. The quota requests a dump; the scheduler reports
	 * completion back via vy_quota_dump_complete().
	 */
	struct vy_scheduler *scheduler;
	/**
	 * Total number of quota timer ticks. The regulator's estimate
	 * is refreshed once every VY_REGULATOR_TIMER_PERIOD, i.e. on
	 * every (VY_REGULATOR_TIMER_PERIOD / VY_QUOTA_TIMER_PERIOD)-th
	 * tick of the finer rate-refill timer.
	 */
	int tick_count;
	/**
	 * Monotonically growing counter assigned to consumers
	 * waiting for quota. It is used for balancing wakeups
	 * among wait queues: if two fibers from different wait
	 * queues may proceed, the one with the lowest ticket
	 * will be picked.
	 *
	 * See also vy_quota_wait_node::ticket.
	 */
	int64_t wait_ticket;
	/**
	 * Queue of consumers waiting for quota, one per each
	 * consumer type, linked by vy_quota_wait_node::state.
	 * Newcomers are added to the tail.
	 */
	struct rlist wait_queue[vy_quota_consumer_type_MAX];
	/**
	 * Periodic timer that is used for refilling the rate
	 * limit value.
	 */
	ev_timer timer;
};

/**
 * Initialize a quota object. The size limit is not imposed until
 * vy_quota_enable() is called.
 *
 * @param[out] q          Quota to initialize.
 * @param[in]  scheduler  Dump executor the quota requests dumps on.
 * @param[in]  limit      Initial memory size limit, in bytes.
 */
void
vy_quota_create(struct vy_quota *q, struct vy_scheduler *scheduler,
		size_t limit);

/**
 * Enable the configured memory size limit (vinyl_memory) for a quota
 * object: arm the initial memory rate limit and start the periodic timer.
 */
void
vy_quota_enable(struct vy_quota *q);

/**
 * Destroy a quota object.
 */
void
vy_quota_destroy(struct vy_quota *q);

/**
 * Set the memory size limit and recompute the dump watermark for it.
 * Wakes any consumers the larger size limit admits.
 */
void
vy_quota_set_size_limit(struct vy_quota *q, size_t limit);

/**
 * Set the dump bandwidth (reset its estimate to the default, capped at
 * @max) and install the resulting memory rate limit. Called when
 * box.cfg.snap_io_rate_limit changes.
 */
void
vy_quota_set_dump_bandwidth(struct vy_quota *q, size_t max);

/**
 * Return the rate limit applied to a consumer of the given type.
 */
size_t
vy_quota_get_rate_limit(struct vy_quota *q, enum vy_quota_consumer_type type);

/**
 * Charge the given number of bytes against the accounted total and the
 * rate limits applicable to the consumer type.
 */
void
vy_quota_acct(struct vy_quota_acct *a, enum vy_quota_consumer_type type,
	      size_t size);

/**
 * Subtract the given number of bytes from the accounted total. Pure
 * arithmetic; unacct deliberately wakes no waiters.
 *
 * Waking would only matter while writers are blocked, that is while
 * used is over the size limit -- which also puts it over the dump
 * watermark, so a dump is already running. Two paths reach unacct
 * then. A rollback or an upsert squash returns a single statement's
 * bytes: a trickle next to the dump that is doing the real reclaim. A
 * retired mem returns its whole footprint at once, and the waiters
 * that frees are woken at dump-round completion by
 * vy_quota_dump_complete. So the bytes unacct returns are never the
 * thing that unblocks a writer.
 *
 * Were a small return to leave a waiter admissible anyway, the
 * periodic timer wakes it within one VY_QUOTA_TIMER_PERIOD, so nothing
 * waits long. And in a healthy system it does not arise at all: the
 * regulator keeps the watermark low enough that dumps finish before
 * used reaches the size limit, so writers pace on the rate limit and
 * never block on the quota.
 */
void
vy_quota_unacct(struct vy_quota_acct *a, size_t size);

/**
 * Finish a dump round: refresh the memory rate limit from the new dump
 * bandwidth, recompute the disk rate limit, wake the consumers the freed
 * memory unblocked, and re-evaluate the watermark so the next dump fires
 * immediately if writes piled up over it while this one ran.
 *
 * @param[in,out] q                   Quota to update.
 * @param[in]     stat                Latest cumulative scheduler stats.
 * @param[in]     compaction_threads  Number of compaction threads.
 */
void
vy_quota_dump_complete(struct vy_quota *q, const struct vy_scheduler_stat *stat,
		       int compaction_threads);

/**
 * Block until there is quota left (used <= the size limit) or the timeout
 * elapses. Returns 0 once admitted, -1 on timeout. The size limit is soft:
 * this gates admission on there being any room, but reserves nothing, so the
 * caller may then allocate and charge (via vy_quota_acct) more than was
 * left, overshooting the size limit by its own write set. Admission therefore
 * only ever blocks above the size limit -- and thus above the dump watermark
 * -- so a blocked consumer is always one a dump can release.
 *
 * Reserving nothing might seem to admit many waiters at once -- they all
 * see room and all charge past the limit together. With cooperative
 * multi-tasking, it works a bit differently, because waiters are
 * admitted one at a time. Under contention the fast path above
 * is skipped (it returns only when the wait queue is empty), so consumers
 * queue in the order they arrived. vy_quota_signal then wakes a single
 * waiter, the one that has waited longest among those that can proceed,
 * and that waiter calls vy_quota_signal once more to wake the next before
 * it returns. Fibers run cooperatively, and each one charges its write set
 * in the no-yield prepare window before the next woken fiber runs, so every
 * wakeup in the chain already accounts for the bytes the earlier waiters
 * added, and the chain stops once used is over the limit. Because a waiter
 * wakes the next one just before charging its own bytes, the fiber that
 * pushes used over the limit still wakes one more, which proceeds without
 * re-checking. The overshoot is therefore at most a transaction or two in
 * flight, not one per queued waiter.
 */
int
vy_quota_wait(struct vy_quota *q, enum vy_quota_consumer_type type,
	      double timeout);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */

#endif /* INCLUDES_TARANTOOL_BOX_VY_QUOTA_H */
