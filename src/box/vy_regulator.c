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
#include "vy_regulator.h"

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "histogram.h"
#include "say.h"
#include "trivia/util.h"

#include "vy_stat.h"

/**
 * Time window over which the write rate is averaged,
 * in seconds.
 */
static const double VY_WRITE_RATE_AVG_WIN = 5;

/**
 * Histogram percentile used for estimating dump bandwidth.
 * For details see the comment to vy_regulator::dump_bandwidth_hist.
 */
static const int VY_DUMP_BANDWIDTH_PCT = 10;

/*
 * Until we dump anything, assume bandwidth to be 10 MB/s,
 * which should be fine for initial guess.
 */
static const size_t VY_DUMP_BANDWIDTH_DEFAULT = 10 * 1024 * 1024;

/**
 * Do not take into account small dumps when estimating dump
 * bandwidth, because they have too high overhead associated
 * with file creation.
 */
static const size_t VY_DUMP_SIZE_ACCT_MIN = 1024 * 1024;

/**
 * Number of dumps to take into account for rate limit calculation.
 * Shouldn't be too small to avoid uneven RPS. Shouldn't be too big
 * either - otherwise the rate limit will adapt too slowly to workload
 * changes. 100 feels like a good choice.
 */
static const int VY_RECENT_DUMP_COUNT = 100;

size_t
vy_regulator_dump_begin(struct vy_regulator *regulator, size_t used)
{
	/*
	 * To avoid unpredictably long stalls, we must limit
	 * the write rate when a dump is in progress so that
	 * we don't hit the size limit before the dump has
	 * completed, i.e.
	 *
	 *    mem_left        mem_used
	 *   ---------- >= --------------
	 *   write_rate    dump_bandwidth
	 */
	size_t mem_left = (used < regulator->size_limit ?
			   regulator->size_limit - used : 0);
	size_t max_write_rate = (double)mem_left / (used + 1) *
					regulator->dump_bandwidth;
	max_write_rate = MIN(max_write_rate, regulator->dump_bandwidth);

	say_info("dumping %zu bytes, expected rate %.1f MB/s, "
		 "ETA %.1f s, write rate (avg/max) %.1f/%.1f MB/s",
		 used, (double)regulator->dump_bandwidth / 1024 / 1024,
		 (double)used / (regulator->dump_bandwidth + 1),
		 (double)regulator->write_rate / 1024 / 1024,
		 (double)regulator->write_rate_max / 1024 / 1024);

	regulator->write_rate_max = regulator->write_rate;
	return max_write_rate;
}

/** Update the moving-average write rate from a memory-usage sample. */
static void
vy_regulator_update_write_rate(struct vy_regulator *regulator, size_t used)
{
	size_t used_curr = used;
	size_t used_last = regulator->quota_used_last;

	/*
	 * Memory can be dumped between two subsequent timer
	 * callback invocations, in which case memory usage
	 * will decrease. Ignore such observations - it's not
	 * a big deal, because dump is a rare event.
	 */
	if (used_curr < used_last) {
		regulator->quota_used_last = used_curr;
		return;
	}

	size_t rate_avg = regulator->write_rate;
	size_t rate_curr = (used_curr - used_last) / VY_REGULATOR_TIMER_PERIOD;

	double weight = 1 - exp(-VY_REGULATOR_TIMER_PERIOD /
				VY_WRITE_RATE_AVG_WIN);
	rate_avg = (1 - weight) * rate_avg + weight * rate_curr;

	regulator->write_rate = rate_avg;
	if (regulator->write_rate_max < rate_curr)
		regulator->write_rate_max = rate_curr;
	regulator->quota_used_last = used_curr;
}

static void
vy_regulator_update_dump_watermark(struct vy_regulator *regulator)
{
	size_t limit = regulator->size_limit;
	/*
	 * A dump returns a whole generation's memory to the quota
	 * at once on completion, not gradually as it runs. So we
	 * configure the watermark so that by the time we hit the
	 * size limit, a dump has completed, i.e.
	 *
	 *   limit - watermark      watermark
	 *   ----------------- = --------------
	 *       write_rate      dump_bandwidth
	 *
	 * Be pessimistic when predicting the write rate - use the
	 * max observed write rate multiplied by 1.5 - because it's
	 * better to start memory dump early than delay it as long
	 * as possible at the risk of experiencing unpredictably
	 * long stalls.
	 */
	size_t write_rate = regulator->write_rate_max * 3 / 2;
	regulator->dump_watermark =
			(double)limit * regulator->dump_bandwidth /
			(regulator->dump_bandwidth + write_rate + 1);
	/*
	 * It doesn't make sense to set the watermark below 50%
	 * of the memory size limit because the write rate can exceed
	 * the dump bandwidth under no circumstances.
	 */
	regulator->dump_watermark = MAX(regulator->dump_watermark, limit / 2);
}

void
vy_regulator_tick(struct vy_regulator *regulator, size_t used)
{
	vy_regulator_update_write_rate(regulator, used);
	vy_regulator_update_dump_watermark(regulator);
}

void
vy_regulator_create(struct vy_regulator *regulator, size_t limit)
{
	enum { KB = 1024, MB = KB * KB };
	static int64_t dump_bandwidth_buckets[] = {
		100 * KB, 200 * KB, 300 * KB, 400 * KB, 500 * KB, 600 * KB,
		700 * KB, 800 * KB, 900 * KB,   1 * MB,   2 * MB,   3 * MB,
		  4 * MB,   5 * MB,   6 * MB,   7 * MB,   8 * MB,   9 * MB,
		 10 * MB,  15 * MB,  20 * MB,  25 * MB,  30 * MB,  35 * MB,
		 40 * MB,  45 * MB,  50 * MB,  55 * MB,  60 * MB,  65 * MB,
		 70 * MB,  75 * MB,  80 * MB,  85 * MB,  90 * MB,  95 * MB,
		100 * MB, 200 * MB, 300 * MB, 400 * MB, 500 * MB, 600 * MB,
		700 * MB, 800 * MB, 900 * MB,
	};
	memset(regulator, 0, sizeof(*regulator));
	regulator->dump_bandwidth_hist = histogram_new(dump_bandwidth_buckets,
					lengthof(dump_bandwidth_buckets));
	if (regulator->dump_bandwidth_hist == NULL)
		panic("failed to allocate dump bandwidth histogram");

	regulator->size_limit = limit;
	regulator->dump_bandwidth = VY_DUMP_BANDWIDTH_DEFAULT;
	regulator->dump_watermark = SIZE_MAX;
	regulator->disk_rate_limit = SIZE_MAX;
}

void
vy_regulator_start(struct vy_regulator *regulator, size_t used)
{
	regulator->quota_used_last = used;
}

void
vy_regulator_destroy(struct vy_regulator *regulator)
{
	histogram_delete(regulator->dump_bandwidth_hist);
}

void
vy_regulator_acct_dump(struct vy_regulator *regulator,
		       size_t bytes, double time)
{
	if (bytes < VY_DUMP_SIZE_ACCT_MIN || time <= 0)
		return;
	histogram_collect(regulator->dump_bandwidth_hist, bytes / time);
}

/** Revise the disk (compaction) rate limit from a round's scheduler stats. */
static void
vy_regulator_update_disk_rate_limit(struct vy_regulator *regulator,
				    const struct vy_scheduler_stat *stat,
				    int compaction_threads);

void
vy_regulator_dump_complete(struct vy_regulator *regulator,
			   const struct vy_scheduler_stat *stat,
			   int compaction_threads)
{
	/*
	 * Refresh the dump bandwidth estimate from samples folded in
	 * by vy_regulator_acct_dump over the round. We need the
	 * worst (smallest) dump bandwidth to avoid unpredictably long
	 * stalls caused by overestimating throughput, so use a
	 * lower-bound percentile estimate.
	 *
	 * The memory rate limit is reset to this bandwidth: it makes no
	 * sense to let memory fill faster than it can be dumped.
	 */
	regulator->dump_bandwidth = histogram_percentile_lower(
		regulator->dump_bandwidth_hist, VY_DUMP_BANDWIDTH_PCT);
	/*
	 * Revise the disk (compaction) rate limit from the same round's
	 * scheduler statistics, if they hold a fresh enough sample.
	 */
	vy_regulator_update_disk_rate_limit(regulator, stat,
					    compaction_threads);
}

void
vy_regulator_set_size_limit(struct vy_regulator *regulator, size_t limit)
{
	regulator->size_limit = limit;
	vy_regulator_update_dump_watermark(regulator);
}

void
vy_regulator_set_dump_bandwidth(struct vy_regulator *regulator, size_t max)
{
	histogram_reset(regulator->dump_bandwidth_hist);
	regulator->dump_bandwidth = VY_DUMP_BANDWIDTH_DEFAULT;
	if (max > 0 && regulator->dump_bandwidth > max)
		regulator->dump_bandwidth = max;
}

void
vy_regulator_reset_stat(struct vy_regulator *regulator)
{
	memset(&regulator->sched_stat_last, 0,
	       sizeof(regulator->sched_stat_last));
}

/*
 * The goal of rate limiting is to ensure LSM trees stay close to
 * their perfect shape, as defined by run_size_ratio. When dump rate
 * is too high, we have to throttle database writes to ensure
 * compaction can keep up with dumps. We can't deduce optimal dump
 * bandwidth from LSM configuration, such as run_size_ratio or
 * run_count_per_level, since different spaces or different indexes
 * within a space can have different configuration settings. The
 * workload can also vary significantly from space to space. So,
 * when setting the disk rate limit, we have to consider dump and
 * compaction activities of the database as a whole.
 *
 * To this end, we keep track of compaction bandwidth and write
 * amplification of the entire database, across all LSM trees.
 * The idea is simple: observe the current write amplification
 * and compaction bandwidth, and set maximal write rate to a value
 * somewhat below the implied rate, so as to make room for
 * compaction to do more work if necessary.
 *
 * We use the following metrics to calculate the disk rate limit:
 *  - dump_output - number of bytes dumped to disk over the last
 *    observation period. The period itself is measured in dumps,
 *    not seconds, and is defined by constant VY_RECENT_DUMP_COUNT.
 *  - compaction_output - number of bytes produced by compaction
 *    over the same period.
 *  - compaction_rate - total compaction output, in bytes, divided
 *    by total time spent on doing compaction by compaction threads,
 *    both measured over the same observation period. This gives an
 *    estimate of the speed at which compaction can write output.
 *    In the real world this speed is dependent on the disk write
 *    throughput, number of dump threads, and actual dump rate, but
 *    given the goal of rate limiting is providing compaction with
 *    extra bandwidth, this metric is considered an accurate enough
 *    approximation of the disk bandwidth available to compaction.
 *
 * We calculate the compaction rate with the following formula:
 *
 *                                            compaction_output
 *     compaction_rate = compaction_threads * -----------------
 *                                             compaction_time
 *
 * where compaction_threads represents the total number of available
 * compaction threads and compaction_time is the total time, in
 * seconds, spent by all threads doing compaction. You can look at
 * the formula this way: compaction_ouptut / compaction_time gives
 * the average write speed of a single compaction thread, and by
 * multiplying it by the number of compaction threads we get the
 * compaction rate of the entire database.
 *
 * In an optimal system dump rate must be proportional to compaction
 * rate and inverse to write amplification:
 *
 *     dump_rate = compaction_rate / (write_amplification - 1)
 *
 * The latter can be obtained by dividing total output of compaction
 * by total output of dumps over the observation period:
 *
 *                           dump_output + compaction_output
 *     write_amplification = ------------------------------- =
 *                                    dump_output
 *
 *                         = 1 + compaction_output / dump_output
 *
 * Putting this all together and taking into account data compaction
 * during memory dump, we get for the max transaction rate:
 *
 *                           dump_input
 *     tx_rate = dump_rate * ----------- =
 *                           dump_output
 *
 *                                    compaction_output
 *             = compaction_threads * ----------------- *
 *                                     compaction_time
 *
 *                              dump_output      dump_input
 *                         * ----------------- * ----------- =
 *                           compaction_output   dump_output
 *
 *             = compaction_threads * dump_input / compaction_time
 *
 * We set the rate limit to 0.75 of the approximated optimal to
 * leave the database engine enough room needed to use more disk
 * bandwidth for compaction if necessary. As soon as compaction gets
 * enough disk bandwidth to keep LSM trees in optimal shape
 * compaction speed becomes stable, as does write amplification.
 */
static void
vy_regulator_update_disk_rate_limit(struct vy_regulator *regulator,
				    const struct vy_scheduler_stat *stat,
				    int compaction_threads)
{
	struct vy_scheduler_stat *last = &regulator->sched_stat_last;
	struct vy_scheduler_stat *recent = &regulator->sched_stat_recent;

	int32_t dump_count = stat->dump_count - last->dump_count;
	int64_t dump_input = stat->dump_input - last->dump_input;
	double compaction_time = stat->compaction_time - last->compaction_time;
	*last = *stat;

	if (dump_input < (ssize_t)VY_DUMP_SIZE_ACCT_MIN || compaction_time == 0)
		return;

	recent->dump_count += dump_count;
	recent->dump_input += dump_input;
	recent->compaction_time += compaction_time;

	double rate = 0.75 * compaction_threads * recent->dump_input /
						  recent->compaction_time;
	/*
	 * We can't simply use (size_t)MIN(rate, SIZE_MAX) to cast
	 * the rate from double to size_t here, because on a 64-bit
	 * system SIZE_MAX equals 2^64-1, which can't be represented
	 * as double without loss of precision and hence is rounded
	 * up to 2^64, which in turn can't be converted back to size_t.
	 * So we first convert the rate to uint64_t using exp2(64) to
	 * check if it fits and only then cast the uint64_t to size_t.
	 */
	uint64_t rate64;
	if (rate < exp2(64))
		rate64 = rate;
	else
		rate64 = UINT64_MAX;
	regulator->disk_rate_limit = (size_t)MIN(rate64, SIZE_MAX);

	/*
	 * Periodically rotate statistics for quicker adaptation
	 * to workload changes.
	 */
	if (recent->dump_count > VY_RECENT_DUMP_COUNT) {
		recent->dump_count /= 2;
		recent->dump_input /= 2;
		recent->compaction_time /= 2;
	}
}
