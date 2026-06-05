/*
 * Copyright 2010-2018, Tarantool AUTHORS, please see AUTHORS file.
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
#include "vy_quota.h"

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <tarantool_ev.h>

#include "diag.h"
#include "error.h"
#include "errcode.h"
#include "errinj.h"
#include "fiber.h"
#include "say.h"
#include "trivia/util.h"
#include "vy_scheduler.h"

/**
 * Quota timer period, in seconds.
 *
 * The timer is used for replenishing the rate limit value so
 * its period defines how long throttled transactions will wait.
 * Therefore use a relatively small period.
 */
static const double VY_QUOTA_TIMER_PERIOD = 0.1;

/** Schedule a memory dump if one is not already running. */
static void
vy_quota_trigger_dump(struct vy_quota *q);

/** Trigger a dump once used memory reaches the dump watermark. */
static void
vy_quota_check_dump_watermark(struct vy_quota *q);

/**
 * Bit mask of resources used by a particular consumer type.
 */
static unsigned
vy_quota_consumer_resource_map[] = {
	/**
	 * Transaction throttling pursues two goals. First, it is
	 * capping memory consumption rate so that the hard memory
	 * limit will not be hit before memory dump has completed
	 * (memory-based throttling). Second, we must make sure
	 * that compaction jobs keep up with dumps to keep read and
	 * space amplification within bounds (disk-based throttling).
	 * Transactions ought to respect them both.
	 */
	[VY_QUOTA_CONSUMER_TX] = (1 << VY_QUOTA_RESOURCE_DISK) |
				 (1 << VY_QUOTA_RESOURCE_MEMORY),
	/**
	 * Compaction jobs may need some quota too, because they
	 * may generate deferred DELETEs for secondary indexes.
	 * Apparently, we must not impose the rate limit that is
	 * supposed to speed up compaction on them (disk-based),
	 * however they still have to respect memory-based throttling
	 * to avoid long stalls.
	 */
	[VY_QUOTA_CONSUMER_COMPACTION] = (1 << VY_QUOTA_RESOURCE_MEMORY),
	/**
	 * Since DDL is triggered by the admin, it can be deliberately
	 * initiated when the workload is known to be low. Throttling
	 * it along with DML requests would only cause exasperation in
	 * this case. So we don't apply the disk rate limit to DDL.
	 * This should be fine, because the disk rate limit is set
	 * rather strictly to let the workload some space to grow, see
	 * vy_regulator_disk_rate_limit(), and in contrast to the
	 * memory rate limit, exceeding the disk rate limit doesn't
	 * result in abrupt stalls - it may only lead to a gradual
	 * accumulation of disk space usage and read latency.
	 */
	[VY_QUOTA_CONSUMER_DDL] = (1 << VY_QUOTA_RESOURCE_MEMORY),
};

/**
 * Check if the rate limit corresponding to resource @resource_type
 * should be applied to a consumer of type @consumer_type.
 */
static inline bool
vy_rate_limit_is_applicable(enum vy_quota_consumer_type consumer_type,
			    enum vy_quota_resource_type resource_type)
{
	return (vy_quota_consumer_resource_map[consumer_type] &
					(1 << resource_type)) != 0;
}

/**
 * Is the quota enabled? The periodic timer runs exactly between
 * vy_quota_enable() and vy_quota_destroy(), so its active state is the
 * enabled state.
 */
static inline bool
vy_quota_is_enabled(struct vy_quota *q)
{
	return ev_is_active(&q->timer);
}

/**
 * Pure predicate: is there any quota left right now (used < the size
 * limit and the rate limit is not exhausted)? Side-effect-free; callers
 * that need to react to "no" kick the regulator explicitly at the moment
 * a fiber actually fails to make progress (see vy_quota_wait's wait-queue
 * path).
 */
static inline bool
vy_quota_may_use(struct vy_quota *q, enum vy_quota_consumer_type type)
{
	if (!vy_quota_is_enabled(q))
		return true;
	/*
	 * Is the memory size limit reached? Admit only while used is
	 * strictly below it, so vinyl_memory == 0 admits nothing. This is
	 * the only condition a dump can relieve, so it -- and not the rate
	 * limit -- is what gates the dump trigger when a fiber blocks (see
	 * vy_quota_wait). The rate limit is a pacing knob replenished by
	 * the timer, not a memory shortage.
	 */
	if (q->acct.used >= q->acct.size_limit)
		return false;
	for (int i = 0; i < vy_quota_resource_type_MAX; i++) {
		struct vy_rate_limit *rl = &q->acct.rate_limit[i];
		if (vy_rate_limit_is_applicable(type, i) &&
		    !vy_rate_limit_may_use(rl))
			return false;
	}
	return true;
}

/**
 * Wake up the first feasible consumer in the wait queue. Pure
 * waiter-management: never advances the dump generation. Reclaim is
 * triggered separately by vy_quota_check_dump_watermark, which runs
 * on admission (vy_quota_wait), the periodic timer, and dump
 * completion.
 */
static void
vy_quota_signal(struct vy_quota *q)
{
	/*
	 * To prevent starvation, wake up a consumer that has
	 * waited most irrespective of its type.
	 */
	struct vy_quota_wait_node *oldest = NULL;
	for (int i = 0; i < vy_quota_consumer_type_MAX; i++) {
		struct rlist *wq = &q->wait_queue[i];
		if (rlist_empty(wq))
			continue;

		struct vy_quota_wait_node *n;
		n = rlist_first_entry(wq, struct vy_quota_wait_node,
				      in_wait_queue);
		/*
		 * No need in waking up a consumer if it will have
		 * to go back to sleep immediately.
		 */
		if (!vy_quota_may_use(q, i))
			continue;

		if (oldest == NULL || oldest->ticket > n->ticket)
			oldest = n;
	}
	if (oldest != NULL)
		fiber_wakeup(oldest->fiber);
}

static void
vy_quota_timer_cb(ev_loop *loop, ev_timer *timer, int events)
{
	(void)loop;
	(void)events;

	struct vy_quota *q = timer->data;

	for (int i = 0; i < vy_quota_resource_type_MAX; i++) {
		struct vy_rate_limit *rl = &q->acct.rate_limit[i];
		vy_rate_limit_refill(rl, VY_QUOTA_TIMER_PERIOD);
	}
	vy_quota_signal(q);

	/*
	 * Drive the regulator's slower estimation cadence off this
	 * timer: once every regulator period refresh the write-rate and
	 * watermark estimate and re-check the watermark, so a dump still
	 * starts when memory creeps up with no consumer actively blocking.
	 */
	int cadence = VY_REGULATOR_TIMER_PERIOD / VY_QUOTA_TIMER_PERIOD;
	if (++q->tick_count % cadence == 0) {
		vy_regulator_tick(&q->regulator, q->acct.used);
		vy_quota_check_dump_watermark(q);
	}
}

void
vy_quota_create(struct vy_quota *q, struct vy_scheduler *scheduler,
		size_t limit)
{
	q->n_blocked = 0;
	q->acct.size_limit = limit;
	q->acct.used = 0;
	q->too_long_threshold = TIMEOUT_INFINITY;
	q->scheduler = scheduler;
	q->tick_count = 0;
	vy_regulator_create(&q->regulator, limit);
	q->wait_ticket = 0;
	for (int i = 0; i < vy_quota_consumer_type_MAX; i++)
		rlist_create(&q->wait_queue[i]);
	for (int i = 0; i < vy_quota_resource_type_MAX; i++)
		vy_rate_limit_create(&q->acct.rate_limit[i]);
	ev_timer_init(&q->timer, vy_quota_timer_cb, 0, VY_QUOTA_TIMER_PERIOD);
	q->timer.data = q;
}

void
vy_quota_enable(struct vy_quota *q)
{
	assert(!vy_quota_is_enabled(q));
	/*
	 * Arm the initial memory rate limit before the first dump so it
	 * runs in the background instead of stalling once the watermark
	 * is hit.
	 */
	vy_regulator_start(&q->regulator, q->acct.used);
	vy_rate_limit_set(&q->acct.rate_limit[VY_QUOTA_RESOURCE_MEMORY],
			  q->regulator.dump_bandwidth);
	ev_timer_start(loop(), &q->timer);
}

void
vy_quota_destroy(struct vy_quota *q)
{
	ev_timer_stop(loop(), &q->timer);
	vy_regulator_destroy(&q->regulator);
}

void
vy_quota_set_size_limit(struct vy_quota *q, size_t limit)
{
	q->acct.size_limit = limit;
	vy_regulator_set_size_limit(&q->regulator, limit);
	vy_quota_signal(q);
}

/**
 * Request a memory dump from the scheduler if one isn't already
 * running. Installs the write throttle the regulator advises for
 * the duration of the dump.
 *
 * Skip the request when nothing is in memory to dump. Normally
 * used >= dump_watermark implies used > 0, but at vinyl_memory == 0
 * the watermark is zero too, so the check fires at used == 0 -- and
 * without this guard the scheduler would spin empty dump rounds.
 */
static void
vy_quota_trigger_dump(struct vy_quota *q)
{
	if (q->acct.used == 0)
		return;
	if (vy_scheduler_dump_in_progress(q->scheduler))
		return;
	size_t rate = vy_regulator_dump_begin(&q->regulator, q->acct.used);
	vy_rate_limit_set(&q->acct.rate_limit[VY_QUOTA_RESOURCE_MEMORY], rate);
	vy_scheduler_trigger_dump(q->scheduler);
}

static void
vy_quota_check_dump_watermark(struct vy_quota *q)
{
	if (q->acct.used >= q->regulator.dump_watermark)
		vy_quota_trigger_dump(q);
}

void
vy_quota_dump_complete(struct vy_quota *q, const struct vy_scheduler_stat *stat,
		       int compaction_threads)
{
	/*
	 * Refresh both rate-limit estimates from the round's data, then
	 * install them. The memory rate is the dump bandwidth -- memory
	 * must not fill faster than it can be dumped; the disk rate keeps
	 * compaction able to keep up. A round without a fresh disk sample
	 * leaves disk_rate_limit at its previous value.
	 */
	vy_regulator_dump_complete(&q->regulator, stat, compaction_threads);
	vy_rate_limit_set(&q->acct.rate_limit[VY_QUOTA_RESOURCE_MEMORY],
			  q->regulator.dump_bandwidth);
	vy_rate_limit_set(&q->acct.rate_limit[VY_QUOTA_RESOURCE_DISK],
			  q->regulator.disk_rate_limit);
	/*
	 * Wake the consumers the freed memory unblocked, then re-check
	 * the watermark: writes that piled up while the dump ran may
	 * already have put us back over it. A dump request is a standing
	 * condition, not a one-shot edge -- any trigger raised mid-dump
	 * was dropped, so re-evaluate here rather than wait for the timer.
	 */
	vy_quota_signal(q);
	vy_quota_check_dump_watermark(q);
}

void
vy_quota_set_dump_bandwidth(struct vy_quota *q, size_t max)
{
	vy_regulator_set_dump_bandwidth(&q->regulator, max);
	vy_rate_limit_set(&q->acct.rate_limit[VY_QUOTA_RESOURCE_MEMORY],
			  q->regulator.dump_bandwidth);
}

size_t
vy_quota_get_rate_limit(struct vy_quota *q, enum vy_quota_consumer_type type)
{
	size_t rate = SIZE_MAX;
	for (int i = 0; i < vy_quota_resource_type_MAX; i++) {
		struct vy_rate_limit *rl = &q->acct.rate_limit[i];
		if (vy_rate_limit_is_applicable(type, i))
			rate = MIN(rate, rl->rate);
	}
	return rate;
}

void
vy_quota_acct(struct vy_quota_acct *a, enum vy_quota_consumer_type type,
	      size_t size)
{
	a->used += size;
	for (int i = 0; i < vy_quota_resource_type_MAX; i++) {
		struct vy_rate_limit *rl = &a->rate_limit[i];
		if (vy_rate_limit_is_applicable(type, i))
			vy_rate_limit_use(rl, size);
	}
}

void
vy_quota_unacct(struct vy_quota_acct *a, size_t size)
{
	/*
	 * Rate limit state is intentionally untouched: a dump
	 * completion must not snap the throttle back.
	 */
	assert(a->used >= size);
	a->used -= size;
}

int
vy_quota_wait(struct vy_quota *q, enum vy_quota_consumer_type type,
	      double timeout)
{
	q->n_blocked++;
	ERROR_INJECT_YIELD(ERRINJ_VY_QUOTA_DELAY);
	q->n_blocked--;

	/*
	 * The size limit is not imposed until vy_quota_enable(); until
	 * then there is no admission control, so let the consumer in.
	 */
	if (!vy_quota_is_enabled(q))
		return 0;

	/*
	 * Schedule a dump if memory is at or above the watermark. Doing
	 * this on every admission attempt starts background reclaim early
	 * and guarantees forward progress: a consumer about to block on a
	 * full quota (used above the size limit, hence above the watermark)
	 * schedules the dump that frees the memory and wakes it, so this
	 * call eventually returns. A consumer blocked only by the rate
	 * limit (used below the watermark) schedules nothing -- the timer
	 * replenishes the rate.
	 */
	vy_quota_check_dump_watermark(q);

	/*
	 * Proceed only if there is quota left *and* the wait queue is
	 * empty. The latter is necessary to ensure fairness and avoid
	 * starvation among fibers queued earlier.
	 */
	if (rlist_empty(&q->wait_queue[type]) && vy_quota_may_use(q, type))
		return 0;

	/*
	 * vinyl_memory == 0 grants no quota at all. Only a transaction is
	 * admission-gated: it blocks below and times out, so no new writes
	 * land. An index build and compaction's deferred deletes must
	 * write for correctness -- their wait is only a pace, which at
	 * limit 0 can never complete, so let them proceed and overshoot.
	 * The scheduler dumps the overshoot.
	 */
	if (q->acct.size_limit == 0 && type != VY_QUOTA_CONSUMER_TX)
		return 0;

	/* Wait for quota. */
	double wait_start = ev_monotonic_now(loop());
	struct vy_quota_wait_node wait_node = {
		.fiber = fiber(),
		.ticket = ++q->wait_ticket,
	};
	rlist_add_tail_entry(&q->wait_queue[type], &wait_node, in_wait_queue);
	q->n_blocked++;
	bool timed_out = fiber_yield_timeout(timeout);
	q->n_blocked--;
	rlist_del_entry(&wait_node, in_wait_queue);

	if (timed_out) {
		diag_set(ClientError, ER_VY_QUOTA_TIMEOUT);
		return -1;
	}

	double wait_time = ev_monotonic_now(loop()) - wait_start;
	if (wait_time > q->too_long_threshold) {
		say_warn_ratelimited("waited for vinyl memory quota for "
				     "too long: %.3f sec", wait_time);
	}

	/*
	 * We were admitted; a fiber queued behind us may be admissible
	 * now too. Hand the baton on so waiters wake in order.
	 */
	vy_quota_signal(q);
	return 0;
}
