#ifndef INCLUDES_TARANTOOL_BOX_VY_REGULATOR_H
#define INCLUDES_TARANTOOL_BOX_VY_REGULATOR_H
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

#include <stdbool.h>
#include <stddef.h>

#include "vy_stat.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct histogram;
struct vy_regulator;

/**
 * Period, in seconds, at which the regulator's estimates are
 * expected to be refreshed via vy_regulator_tick(). The regulator
 * owns no timer; the quota drives the updates at this cadence, and
 * the write-rate average is computed against this period.
 */
static const double VY_REGULATOR_TIMER_PERIOD = 1.0;

/**
 * The regulator sets vinyl memory-management policy: it tracks write
 * rate and dump bandwidth and, from those plus the current memory
 * usage, computes the dump watermark and the rate limits. It
 * holds no references and performs no side effects -- it is fed
 * observations and returns the resulting rate limits and watermark,
 * which its owner (the quota) applies.
 */
struct vy_regulator {
	/**
	 * Average rate at which transactions are writing to
	 * the database, in bytes per second.
	 */
	size_t write_rate;
	/**
	 * Max write rate observed since the last time when
	 * memory dump was triggered, in bytes per second.
	 */
	size_t write_rate_max;
	/**
	 * Amount of memory that was used when the timer was
	 * executed last time. Needed to update @write_rate.
	 */
	size_t quota_used_last;
	/**
	 * Current dump bandwidth estimate, in bytes per second.
	 * See @dump_bandwidth_hist for more details.
	 */
	size_t dump_bandwidth;
	/**
	 * Dump bandwidth is needed for calculating the watermark.
	 * The higher the bandwidth, the later we can start dumping
	 * w/o suffering from transaction throttling. So we want to
	 * be very conservative about estimating the bandwidth.
	 *
	 * To make sure we don't overestimate it, we maintain a
	 * histogram of all observed measurements and assume the
	 * bandwidth to be equal to the 10th percentile, i.e. the
	 * best result among 10% worst measurements.
	 */
	struct histogram *dump_bandwidth_hist;
	/**
	 * Memory size limit, in bytes, the watermark and write throttle
	 * are computed against. A cached copy of vy_quota_acct::size_limit,
	 * set together with it by vy_quota_set_size_limit().
	 */
	size_t size_limit;
	/**
	 * Memory watermark. Exceeding it does not result in
	 * throttling new transactions, but it does trigger
	 * background memory reclaim.
	 */
	size_t dump_watermark;
	/**
	 * Disk (compaction) rate limit, in bytes per second, recomputed
	 * at dump-round completion when a fresh sample is available and
	 * left unchanged otherwise. SIZE_MAX until the first sample,
	 * i.e. no disk throttle.
	 */
	size_t disk_rate_limit;
	/**
	 * Snapshot of scheduler statistics taken at the time of
	 * the last disk rate limit update.
	 */
	struct vy_scheduler_stat sched_stat_last;
	/**
	 * Scheduler statistics for the most recent few dumps.
	 * Used for calculating the disk rate limit.
	 */
	struct vy_scheduler_stat sched_stat_recent;
};

/**
 * Initialize a regulator.
 *
 * @param[out] regulator  Regulator to initialize.
 * @param[in]  limit      Initial memory size limit, in bytes.
 */
void
vy_regulator_create(struct vy_regulator *regulator, size_t limit);

/**
 * Free the resources owned by a regulator.
 *
 * @param[in,out] regulator  Regulator to destroy.
 */
void
vy_regulator_destroy(struct vy_regulator *regulator);

/**
 * Set the memory size limit and recompute the dump watermark for it.
 *
 * @param[in,out] regulator  Regulator being reconfigured.
 * @param[in]     limit      New memory size limit, in bytes.
 */
void
vy_regulator_set_size_limit(struct vy_regulator *regulator, size_t limit);

/**
 * Set the dump bandwidth: reset its estimate to the default, capped at
 * @max. Called when box.cfg.snap_io_rate_limit changes. The resulting
 * regulator->dump_bandwidth is the memory rate limit to install.
 *
 * @param[in,out] regulator  Regulator being reconfigured.
 * @param[in]     max        Upper bound on the bandwidth, in bytes per
 *                           second, or 0 for no bound.
 */
void
vy_regulator_set_dump_bandwidth(struct vy_regulator *regulator, size_t max);

/**
 * Reset the scheduler-statistics snapshot, on box.stat.reset().
 *
 * @param[in,out] regulator  Regulator whose snapshot is reset.
 */
void
vy_regulator_reset_stat(struct vy_regulator *regulator);

/**
 * Note the initial memory usage before the first dump. Called once
 * from vy_quota_enable(). The memory rate limit to arm is
 * regulator->dump_bandwidth.
 *
 * @param[in,out] regulator  Regulator recording the baseline usage.
 * @param[in]     used       Current memory usage, in bytes.
 */
void
vy_regulator_start(struct vy_regulator *regulator, size_t used);

/**
 * Periodic estimation update: refresh the write-rate estimate and
 * recompute the dump watermark. Driven by the quota timer once every
 * VY_REGULATOR_TIMER_PERIOD.
 *
 * @param[in,out] regulator  Regulator whose estimates are refreshed.
 * @param[in]     used       Current memory usage, in bytes.
 */
void
vy_regulator_tick(struct vy_regulator *regulator, size_t used);

/**
 * Feed the dump-bandwidth histogram with one completed primary-index
 * dump's measurement. A round's samples are folded into the bandwidth
 * estimate by vy_regulator_dump_complete().
 *
 * @param[in,out] regulator  Regulator accumulating the sample.
 * @param[in]     bytes      Bytes written by the dump.
 * @param[in]     time       Wall-clock seconds the dump took.
 */
void
vy_regulator_acct_dump(struct vy_regulator *regulator,
		       size_t bytes, double time);

/**
 * Begin a dump round: compute the memory rate limit writers should be
 * throttled to while the dump runs (slow enough that the size limit is
 * not hit before the dump completes).
 *
 * @param[in,out] regulator  Regulator (resets its max-write-rate window).
 * @param[in]     used       Current memory usage, in bytes.
 * @return the memory rate limit, in bytes per second.
 */
size_t
vy_regulator_dump_begin(struct vy_regulator *regulator, size_t used);

/**
 * Finish a dump round: refresh both rate-limit estimates from the
 * round's data. The dump-bandwidth estimate is folded from the
 * per-task samples into regulator->dump_bandwidth (the memory rate
 * limit to install), and the disk (compaction) rate limit is revised
 * from the scheduler statistics when they hold a fresh enough sample,
 * leaving regulator->disk_rate_limit unchanged otherwise. The caller
 * reads both fields back.
 *
 * @param[in,out] regulator           Regulator whose estimates are refreshed.
 * @param[in]     stat                Latest cumulative scheduler stats.
 * @param[in]     compaction_threads  Number of compaction threads.
 */
void
vy_regulator_dump_complete(struct vy_regulator *regulator,
			   const struct vy_scheduler_stat *stat,
			   int compaction_threads);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */

#endif /* INCLUDES_TARANTOOL_BOX_VY_REGULATOR_H */
