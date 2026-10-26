#ifndef TARANTOOL_LIB_CORE_FIBER_H_INCLUDED
#define TARANTOOL_LIB_CORE_FIBER_H_INCLUDED
/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
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
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "trivia/config.h"

#include <stdbool.h>
#include <stdint.h>
#include "tt_pthread.h"
#include <tarantool_ev.h>
#include "cord_on_demand.h"
#include "diag.h"
#include "trivia/util.h"
#include "small/mempool.h"
#include "small/region.h"
#include "small/rlist.h"
#include "salad/stailq.h"
#include "clock_lowres.h"
#include "insn_counter.h"
#include "backtrace.h"
#include "exception.h"

#include <coro/coro.h>

/*
 * This constant is the same as LUA_NOREF. It should be used
 * to initialize all Lua references in struct fiber.
 * Since this module is independent on Lua the constant is
 * defined directly. Value should be checked with
 * static_assert in appropriate places to catch possible
 * LUA_NOREF value changes in future.
 */
#define FIBER_LUA_NOREF (-2)

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

/* A fiber reports used up CPU time with nanosecond resolution. */
#define FIBER_TIME_RES 1000000000

/**
 * A struct containing all the info gathered for current fiber or
 * thread as a whole when fiber.top() is enabled.
 */
struct clock_stat {
	/**
	 * Accumulated clock value calculated using exponential
	 * moving average.
	 */
	uint64_t acc;
	/**
	 * Clock delta counter used on current event loop
	 * iteration.
	 */
	uint64_t delta;
	/**
	 * Clock delta calculated on previous event loop
	 * iteration.
	 */
	uint64_t prev_delta;
	/**
	 * Total processor time this fiber (or cord as a whole)
	 * has spent with 1 / FIBER_TIME_RES second precision.
	 */
	uint64_t cputime;
};

/**
 * A struct encapsulating all knowledge this cord has about cpu
 * clocks and their state.
 */
struct cpu_stat {
	uint64_t prev_clock;
	/**
	 * This thread's CPU time at the beginning of event loop
	 * iteration. Used to calculate how much cpu time has
	 * each loop iteration consumed and update fiber cpu
	 * times propotionally. The resolution is
	 * 1 / FIBER_TIME_RES seconds.
	 */
	uint64_t prev_cputime;
};

enum {
	/** Both limits include terminating 0. */
	FIBER_NAME_INLINE = 40,
	FIBER_NAME_MAX = 256
};

/**
 * Fiber ids [0; 100] are reserved.
 */
enum {
	FIBER_ID_SCHED		= 1,
	FIBER_ID_MAX_RESERVED	= 100
};

enum {
	/**
	 * Indicates that a fiber has been requested to end
	 * prematurely.
	 */
	FIBER_IS_CANCELLED	= 1 << 0,
	/**
	 * The fiber will garbage collect automatically
	 * when fiber function ends. The alternative
	 * is that some other fiber will wait for
	 * the end of this fiber and garbage collect it
	 * with fiber_join().
	 */
	FIBER_IS_JOINABLE	= 1 << 1,
	/**
	 * The fiber is in cord->ready list or in
	 * a call chain created by fiber_schedule_list().
	 * The flag is set to help fiber_wakeup() avoid
	 * double wakeup of an already scheduled fiber.
	 */
	FIBER_IS_READY		= 1 << 2,
	/**
	 * This flag is set when fiber function ends and before
	 * the fiber is recycled.
	 */
	FIBER_IS_DEAD		= 1 << 3,
	/**
	 * This flag is set when fiber uses custom stack size.
	 */
	FIBER_CUSTOM_STACK	= 1 << 4,
	/**
	 * The flag is set for the fiber currently being executed by the cord.
	 */
	FIBER_IS_RUNNING	= 1 << 5,
	/**
	 * This flag is set when fiber is in the idle list
	 * of fiber_pool.
	 */
	FIBER_IS_IDLE		= 1 << 6,
	/**
	 * This flag is set when fiber has custom max slice.
	 */
	FIBER_CUSTOM_SLICE	= 1 << 7,
	/**
	 * This flag idicates, if the fiber can be killed from the Lua world.
	 */
	FIBER_IS_SYSTEM         = 1 << 8,
	/**
	 * Someone has joined the fiber already. So this fiber can't be joined
	 * once again nor can its joinability be changed.
	 */
	FIBER_JOIN_BEEN_INVOKED = 1 << 9,
	FIBER_DEFAULT_FLAGS	= 0
};

/** \cond public */

/**
 * Fiber attributes container
 */
struct fiber_attr;

/**
 * Create a new fiber attribute container and initialize it
 * with default parameters.
 * Can be used for many fibers creation, corresponding fibers
 * will not take ownership.
 */
API_EXPORT struct fiber_attr *
fiber_attr_new(void);

/**
 * Delete the fiber_attr and free all allocated resources.
 * This is safe when fibers created with this attribute still exist.
 *
 *\param fiber_attr fiber attribute
 */
API_EXPORT void
fiber_attr_delete(struct fiber_attr *fiber_attr);

/**
 * Set stack size for the fiber attribute.
 *
 * \param fiber_attribute fiber attribute container
 * \param stacksize stack size for new fibers
 */
API_EXPORT int
fiber_attr_setstacksize(struct fiber_attr *fiber_attr, size_t stack_size);

/**
 * Get stack size from the fiber attribute.
 *
 * \param fiber_attribute fiber attribute container or NULL for default
 * \retval stack size
 */
API_EXPORT size_t
fiber_attr_getstacksize(struct fiber_attr *fiber_attr);

struct fiber;
/**
 * Fiber - contains information about fiber
 */

typedef int (*fiber_func)(va_list);

/**
 * Return the current fiber
 */
API_EXPORT struct fiber *
fiber_self(void);

/**
 * Create a new fiber.
 *
 * Takes a fiber from fiber cache, if it's not empty.
 * Can fail only if there is not enough memory for
 * the fiber structure or fiber stack.
 *
 * The created fiber automatically returns itself
 * to the fiber cache when its "main" function
 * completes.
 *
 * \param name       string with fiber name
 * \param fiber_func func for run inside fiber
 *
 * \sa fiber_start
 */
API_EXPORT struct fiber *
fiber_new(const char *name, fiber_func f);

/**
 * Create a new fiber with defined attributes.
 *
 * Can fail only if there is not enough memory for
 * the fiber structure or fiber stack.
 *
 * The created fiber automatically returns itself
 * to the fiber cache if has default stack size
 * when its "main" function completes.
 *
 * \param name       string with fiber name
 * \param fiber_attr fiber attributes
 * \param fiber_func func for run inside fiber
 *
 * \sa fiber_start
 */
API_EXPORT struct fiber *
fiber_new_ex(const char *name, const struct fiber_attr *fiber_attr, fiber_func f);

/**
 * Return control to another fiber and wait until it'll be woken.
 *
 * \note this is not a cancellation point (\sa fiber_testcancel()), but it is
 * considered a good practice to call fiber_testcancel() after each yield.
 *
 * \sa fiber_wakeup
 */
API_EXPORT void
fiber_yield(void);

/**
 * Start execution of created fiber.
 *
 * \param callee fiber to start
 * \param ...    arguments to start the fiber with
 *
 * \sa fiber_new
 */
API_EXPORT void
fiber_start(struct fiber *callee, ...);

/**
 * Set a pointer to context for the fiber. Can be used to avoid calling
 * fiber_start which means no yields.
 *
 * \param f     fiber to set the context for
 *              if NULL, the current fiber is used
 * \param f_arg context for the fiber function
 */
API_EXPORT void
fiber_set_ctx(struct fiber *f, void *f_arg);

/**
 * Get the context for the fiber which was set via the fiber_set_ctx
 * function. Can be used to avoid calling fiber_start which means no yields.
 * If \a f is NULL, the current fiber is used.
 *
 * \retval      context for the fiber function set by fiber_set_ctx function
 *
 * \sa fiber_set_ctx
 */
API_EXPORT void *
fiber_get_ctx(struct fiber *f);

/**
 * Interrupt a synchronous wait of a fiber. Nop for the currently running fiber.
 *
 * \param f fiber to be woken up
 */
API_EXPORT void
fiber_wakeup(struct fiber *f);

/**
 * Cancel the subject fiber.
 *
 * Cancellation is asynchronous. Use fiber_join() to wait for the cancellation
 * to complete.
 *
 * After fiber_cancel() is called, the fiber may or may not check whether it
 * was cancelled. If the fiber does not check it, it cannot ever be cancelled.
 * However, as long as most of the cooperative code calls fiber_testcancel(),
 * most of the fibers are cancellable.
 *
 * \param f fiber to be cancelled
 */
API_EXPORT void
fiber_cancel(struct fiber *f);

/**
 * Deprecated.
 *
 * @return true
 */
API_EXPORT bool
fiber_set_cancellable(bool yesno);

/**
 * Set fiber to be joinable (false by default).
 * The fiber must not be joined already nor dead.
 *
 * @pre the fiber is not dead (panic if not).
 * @pre the fiber is not joined yet (panic if not).
 *
 * \param fiber to (un)set the joinable property.
 *              If set to NULL, the current fiber is used.
 * \param yesno status to set
 */
API_EXPORT void
fiber_set_joinable(struct fiber *fiber, bool yesno);

/**
 * Wait until the fiber is dead and then move its execution
 * status to the caller.
 * The fiber must not be detached (@sa fiber_set_joinable()).
 *
 * @pre FIBER_IS_JOINABLE flag is set (panic if not).
 * @pre the fiber is not joined yet (panic if not).
 * @pre the fiber is different from current (panic if not).
 *
 * \param f fiber to be woken up
 * \return fiber function ret code
 */
API_EXPORT int
fiber_join(struct fiber *f);

/**
 * Wait until the fiber is dead or timeout exceeded.
 * In case timeout == TIMEOUT_INFINITY, this function
 * same as fiber_join function.
 * Return fiber execution status to the caller or -1
 * if timeout exceeded and set diag.
 * The fiber must not be detached (@sa fiber_set_joinable()).
 *
 * @pre FIBER_IS_JOINABLE flag is set.
 * @pre the fiber is not joined yet (panic if not).
 *
 * \param f fiber to be woken up
 * \param timeout time during which we wait for the fiber completion
 * \return fiber function ret code or -1 in case if timeout exceeded
 */
API_EXPORT int
fiber_join_timeout(struct fiber *f, double timeout);

/**
 * Put the current fiber to sleep for at least 's' seconds.
 *
 * \param s time to sleep
 *
 * \note this is a cancellation point (\sa fiber_is_cancelled)
 */
API_EXPORT void
fiber_sleep(double s);

/**
 * Check current fiber for cancellation (it must be checked
 * manually).
 */
API_EXPORT bool
fiber_is_cancelled(void);

/**
 * Report loop begin time as double (cheap).
 * Uses real time clock.
 */
API_EXPORT double
fiber_time(void);

/**
 * Report loop begin time as 64-bit int.
 * Uses real time clock.
 */
API_EXPORT int64_t
fiber_time64(void);

/**
 * Report loop begin time as double (cheap).
 * Uses monotonic clock.
 */
API_EXPORT double
fiber_clock(void);

/**
 * Report loop begin time as 64-bit int.
 * Uses monotonic clock.
 */
API_EXPORT int64_t
fiber_clock64(void);

/**
 * Reschedule fiber to end of event loop cycle.
 */
API_EXPORT void
fiber_reschedule(void);

/**
 * Set fiber name.
 * @param fiber Target fiber, if it's NULL the current fiber is used.
 * @param name A new name of @a fiber.
 * @param len Length of the string pointed to by @a name.
 */
API_EXPORT void
fiber_set_name_n(struct fiber *fiber, const char *name, uint32_t len);

/**
 * Get fiber name.
 * @param fiber Target fiber, if it's NULL the current fiber is used.
 * @return pointer to a nul-terminated string.
 */
API_EXPORT const char *
fiber_name(const struct fiber *fiber);

/**
 * Get fiber id.
 * @param fiber Target fiber, if it's NULL the current fiber is used.
 */
API_EXPORT uint64_t
fiber_id(const struct fiber *fiber);

/**
 * Get number of context switches of the given fiber.
 * @param fiber Target fiber, if it's NULL the current fiber is used.
 */
API_EXPORT uint64_t
fiber_csw(const struct fiber *fiber);

/**
 * Counters that each fiber keeps. They show how much work a fiber did,
 * for example, to find performance regressions in tests. The counters
 * are off by default. cord_pmu_start() and cord_pmu_stop()
 * turn them on and off for all the fibers of the current cord, also for
 * the fibers that start later. fiber_pmu_start() and
 * fiber_pmu_stop() do it for one fiber. The last call wins.
 * For example, after cord_pmu_start() and then
 * fiber_pmu_stop() of one fiber, the counters count for all
 * the fibers except that one.
 *
 * The values of the counters do not change between releases. New
 * counters are added at the end.
 *
 * To measure a job, get the counters before and after it and subtract.
 * The result includes the work of the fiber only, not of the fibers
 * that ran while it was suspended. The result is correct if the counters
 * are on all the time between the two reads. A running SQL statement
 * sees that the counters were enabled or disabled only at its next row.
 * On Linux, the instructions are not counted while other pinned perf
 * events take all the hardware counters, and nothing tells that.
 *
 * A fiber of a fiber pool, for example, the one of an iproto request,
 * serves many requests. It keeps its setting and its values between
 * them.
 */
enum fiber_pmu_counter {
	/**
	 * CPU instructions executed by the fiber. On Linux it uses a
	 * hardware performance counter (perf_event) and counts only user
	 * space. The counter can be unavailable, for example, in a virtual
	 * machine or in a container that blocks the perf_event_open()
	 * system call. If the counter cannot be read in user space (with
	 * rdpmc on x86), for example, on ARM or if a virtual machine does
	 * not allow it, each run of a fiber reads it with a system call.
	 * On macOS it uses the counters of the thread
	 * (thread_selfcounts()), which count the kernel too, so each run
	 * of a fiber also counts about one system call that reads the
	 * counter. On other systems it is not counted.
	 */
	FIBER_PMU_CPU_INSTRUCTIONS = 0,
	/** VDBE opcodes executed by SQL statements. */
	FIBER_PMU_VDBE_OPCODES = 1,
	/**
	 * Rows read from spaces: by SQL statements, by select, get, min,
	 * max and random requests, and by index iterators. Rows of the
	 * ephemeral spaces of SQL and internal reads are not counted.
	 */
	FIBER_PMU_ROWS_READ = 2,
	/**
	 * Rows inserted, replaced, updated, deleted or upserted by the
	 * transactions that were committed. A delete or an update that
	 * finds no row is not counted. A delete or an upsert of vinyl
	 * that writes without looking for the row is counted even though
	 * it sets no tuple. Rows of the ephemeral spaces of SQL are not
	 * counted. A transaction that is submitted without a wait for its
	 * end, by the applier or by the recovery, is counted when it is
	 * submitted, though it can still roll back, for example, by a
	 * ROLLBACK of synchronous replication.
	 */
	FIBER_PMU_ROWS_WRITTEN = 3,
	/**
	 * Rows that SQL statements give as their result. The rows of
	 * EXPLAIN and EXPLAIN ANALYZE are not counted.
	 */
	FIBER_PMU_ROWS_RETURNED = 4,
	/** Number of counters in this version. */
	fiber_pmu_counter_MAX,
};

/**
 * Start the counters for all the fibers of the current cord, also for the
 * fibers that start later. This cancels the settings of single fibers.
 * If the hardware counter of instructions is unavailable, log the reason
 * once and do not count the instructions until the next
 * cord_pmu_stop().
 */
API_EXPORT void
cord_pmu_start(void);

/**
 * Stop the counters for all the fibers of the current cord, also for the
 * fibers that start later. This cancels the settings of single fibers.
 * The fibers keep the values that they have.
 */
API_EXPORT void
cord_pmu_stop(void);

/**
 * Reset the sums of the counters of all the fibers of the current cord:
 * cord_pmu_read() gives zeroes after it. The counters of single fibers
 * are not changed.
 */
API_EXPORT void
cord_pmu_reset(void);

/**
 * Start the counters for one fiber. The setting stays until the fiber
 * dies or until the next cord_pmu_start() or
 * cord_pmu_stop(). If the hardware counter of
 * instructions is unavailable, log the reason once and do not count the
 * instructions until the next cord_pmu_stop().
 *
 * @param fiber Target fiber of the current cord. If it is NULL, the
 *        current fiber is used.
 */
API_EXPORT void
fiber_pmu_start(struct fiber *fiber);

/**
 * Stop the counters for one fiber. The setting stays until the fiber dies
 * or until the next cord_pmu_start() or cord_pmu_stop().
 * The fiber keeps the values that it has.
 *
 * @param fiber Target fiber of the current cord. If it is NULL, the
 *        current fiber is used.
 */
API_EXPORT void
fiber_pmu_stop(struct fiber *fiber);

/**
 * Reset the counters of one fiber: fiber_pmu_read() gives zeroes after
 * it for that fiber. The setting of the counters, on or off, is not
 * changed.
 *
 * @param fiber Target fiber of the current cord. If it is NULL, the
 *        current fiber is used.
 */
API_EXPORT void
fiber_pmu_reset(struct fiber *fiber);

/**
 * Return true if the counters are on for all the fibers of the current
 * cord: the state that cord_pmu_start() and cord_pmu_stop() set. The
 * counters of single fibers that fiber_pmu_start() started do not
 * change it.
 */
API_EXPORT bool
cord_pmu_is_enabled(void);

/**
 * Return true if the counters are on for one fiber.
 *
 * @param fiber Target fiber of the current cord. If it is NULL, the
 *        current fiber is used.
 */
API_EXPORT bool
fiber_pmu_is_enabled(const struct fiber *fiber);

/**
 * Get the counters of a fiber.
 *
 * @param fiber Target fiber of the current cord. If it is NULL, the
 *        current fiber is used.
 * @param[out] values Array of `count` elements. Element `i` gets the
 *        value of the counter `i` of enum fiber_pmu_counter.
 * @param count Size of the array. It can be different from
 *        fiber_pmu_counter_MAX of this version.
 * @return Number of elements set: the minimum of `count` and the number
 *         of counters in this version.
 */
API_EXPORT size_t
fiber_pmu_read(const struct fiber *fiber, uint64_t *values, size_t count);

/**
 * Get the sums of the counters of all the fibers of the current cord:
 * the work that they did while the counters were on for them. The work
 * of the fibers that are dead is included.
 *
 * @param[out] values Array of `count` elements, as in fiber_pmu_read().
 * @param count Size of the array.
 * @return Number of elements set, as in fiber_pmu_read().
 */
API_EXPORT size_t
cord_pmu_read(uint64_t *values, size_t count);

/**
 * Get a pointer to a live fiber in the current cord by the given fiber id,
 * which may be used for getting other info about the fiber (name, csw, etc.).
 *
 * @param fid Target fiber id.
 * @return fiber on success, NULL if fiber was not found.
 *
 * @sa fiber_name, fiber_csw, fiber_id
 */
API_EXPORT struct fiber *
fiber_find(uint64_t fid);

/**
 * Return slab_cache suitable to use with tarantool/small library
 */
struct slab_cache;
API_EXPORT struct slab_cache *
cord_slab_cache(void);

/**
 * box region allocator
 *
 * It is the region allocator from the small library. It is useful
 * for allocating tons of small objects and free them at once.
 *
 * Typical usage is illustrated in the sketch below.
 *
 *  | size_t region_svp = box_region_used();
 *  | while (<...>) {
 *  |     char *buf = box_region_alloc(<...>);
 *  |     <...>
 *  | }
 *  | box_region_truncate(region_svp);
 *
 * There are module API functions that return a result on
 * this region. In this case a caller is responsible to free the
 * result:
 *
 *  | size_t region_svp = box_region_used();
 *  | char *buf = box_<...>(<...>);
 *  | <...>
 *  | box_region_truncate(region_svp);
 *
 * This API provides better compatibility guarantees over using
 * the small library directly in a module. A binary layout of
 * internal structures may be changed in a future, but
 * <box_region_*>() functions will remain API and ABI compatible.
 *
 * Each fiber has its own box region. It means that a call of,
 * say, <box_region_used>() will give its own value in different
 * fibers. It also means that a yield does not invalidate data in
 * the box region.
 *
 * Prior to version 2.11, the box region was implicitly cleaned up
 * on transaction commit (see <box_txn_commit>()) so that
 * <box_region_truncate>() wasn't strictly necessary. Starting from
 * version 2.11, it isn't true anymore, and the client code must free
 * all its allocations explicitly.
 */

/** How much memory is used by the box region. */
API_EXPORT size_t
box_region_used(void);

/**
 * Allocate size bytes from the box region.
 *
 * Don't use this function to allocate a memory block for a value
 * or array of values of a type with alignment requirements. A
 * violation of alignment requirements leads to undefined
 * behaviour.
 *
 * In case of a memory error set a diag and return NULL.
 * @sa <box_error_last>().
 */
API_EXPORT void *
box_region_alloc(size_t size);

/**
 * Allocate size bytes from the box region with given alignment.
 *
 * Alignment must be a power of 2.
 *
 * In case of a memory error set a diag and return NULL.
 * @sa <box_error_last>().
 */
API_EXPORT void *
box_region_aligned_alloc(size_t size, size_t alignment);

/**
 * Return a contiguous allocation of the most recently allocated @a size
 * bytes.
 *
 * If the @a size worth of most recent allocations are already contiguous,
 * then the pointer into that allocation is returned. Otherwise a new allocation
 * is made and data from previous allocations is copied into it.
 * @sa <box_region_alloc>().
 *
 * @a size must be non zero.
 * @a size must be less then or equal to value returned by <box_region_used>().
 *
 * In case of a memory error set a diag and return NULL.
 * @sa <box_error_last>().
 */
API_EXPORT void *
box_region_join(size_t size);

/**
 * Truncate the box region to the given size.
 */
API_EXPORT void
box_region_truncate(size_t size);

/** \endcond public */

/**
 * Fiber attribute container
 */
struct fiber_attr {
	/** Fiber stack size. */
	size_t stack_size;
	/** Fiber flags. */
	uint32_t flags;
};

/**
 * Init fiber attr with default values
 */
void
fiber_attr_create(struct fiber_attr *fiber_attr);

/**
 * Under no circumstances this header file is allowed to include
 * application-specific headers like session.h or txn.h. One only
 * is allowed to announce a struct and add opaque pointer to it.
 */
struct session;
struct txn;
struct credentials;
struct lua_State;
struct ipc_wait_pad;

/**
 * Warning and error slices.
 */
struct fiber_slice {
	/**
	 * If warning slice is exceeded, the warning will
	 * be written in log when you check slice.
	 */
	double warn;
	/**
	 * If error slice is exceeded, fiber_check_slice()
	 * will set diag and return -1.
	 */
	double err;
};

/** The setting of the counters of one fiber. */
enum fiber_pmu_mode {
	/** Follow the setting of the cord. */
	FIBER_PMU_DEFAULT = 0,
	/** On after fiber_pmu_start(). */
	FIBER_PMU_ON,
	/** Off after fiber_pmu_stop(). */
	FIBER_PMU_OFF,
};

/**
 * A counter that is kept outside of the fiber struct while a function
 * runs, so that the hot code of the function does not change the fiber.
 * For example, the VDBE counts its opcodes in its own step counter.
 * The fiber adds the increments of the source to its counter when it
 * yields, when it reads its counters and when the source is removed.
 */
struct fiber_pmu_source {
	/** The fiber counter that the source adds to. */
	enum fiber_pmu_counter counter;
	/** The source value, NULL if the fiber has no source. */
	const uint64_t *value;
	/** The part of the source value that is already added. */
	uint64_t base;
};

/** The counters of one fiber and their settings. */
struct fiber_pmu {
	/** The value of cord->pmu.gen when mode was set. */
	uint32_t gen;
	/**
	 * The setting of the counters of this fiber. It is valid only if
	 * gen is equal to the one of the cord.
	 */
	enum fiber_pmu_mode mode;
	/** A value that is counted outside of the fiber. */
	struct fiber_pmu_source source;
	/**
	 * Values of the counters of this fiber. The work of the current
	 * fiber since the last fiber_pmu_sync() is not included.
	 * @sa fiber_pmu_read
	 */
	uint64_t values[fiber_pmu_counter_MAX];
};

/** The counters of the fibers of one cord and their settings. */
struct cord_pmu {
	/**
	 * Generation of the settings of the counters. It is incremented when
	 * the counters are turned on or off for all the fibers, and so the
	 * settings of single fibers become invalid.
	 */
	uint32_t gen;
	/** The hardware counter of instructions of this cord. */
	struct insn_counter insn_counter;
	/**
	 * Value of insn_counter at the start of the current run of the
	 * current fiber.
	 */
	uint64_t insn_count_last;
	/** True if the counters are on for the fibers without a setting. */
	bool enabled : 1;
	/**
	 * True if the counters can count for some fiber of the cord: they
	 * are on for all the fibers, or on for some fibers. The hardware
	 * counter of instructions is open while it is true.
	 */
	bool active : 1;
	/** True if the hardware counter of instructions worked at least once.
	 * The counters of the instructions stay visible after the hardware
	 * counter closes.
	 */
	bool insn_seen : 1;
	/**
	 * True if the hardware counter of instructions failed to open. It
	 * is not tried again until the counters are turned off for all
	 * the fibers.
	 */
	bool insn_failed : 1;
	/**
	 * The number of the fibers whose own setting turns the counters
	 * on. It is reset when the settings of single fibers are cancelled.
	 */
	uint32_t on_count;
	/**
	 * Sums of the counters of all the fibers of the cord, also of the
	 * dead ones. A fiber adds its work to them while the counters are
	 * on for it. The work of the current fiber since the last
	 * fiber_pmu_sync() is not included.
	 * @sa cord_pmu_read
	 */
	uint64_t values[fiber_pmu_counter_MAX];
};

struct fiber {
	coro_context ctx;
	/** Coro stack slab. */
	struct slab *stack_slab;
	/** Coro stack addr. */
	void *stack;
#ifdef HAVE_MADV_DONTNEED
	/**
	 * We want to keep total stack memory usage low while still
	 * allowing tasks that need a greater than average stack.
	 * To achieve that, we write some poison values to stack
	 * at "watermark" position and call madvise(MADV_DONTNEED)
	 * when a fiber is recycled in case a poison value has been
	 * overwritten. This allows to keep per-fiber stack memory
	 * usage below the watermark while avoiding any performance
	 * penalty if there are no tasks eager for stack.
	 */
	void *stack_watermark;
#endif
	/** Coro stack size. */
	size_t stack_size;
	/** Fiber's custom slice if fiber has it, zero otherwise. */
	struct fiber_slice max_slice;
	/** Valgrind stack id. */
	unsigned int stack_id;
	/** A garbage-collected memory pool. */
	struct region gc;
#ifdef ENABLE_BACKTRACE
	/**
	 * Backtrace of the first fiber gc allocation that does not
	 * truncated yet. NULL if backtrace is not supported by the
	 * platform or fiber_leak_backtrace_enable == false.
	 */
	struct backtrace *first_alloc_bt;
#endif
	/**
	 * This much size of fiber gc at the beginning is used for
	 * fiber internal purpuses.
	 */
	size_t gc_initial_size;
	/**
	 * The fiber which should be scheduled when
	 * this fiber yields.
	 */
	struct fiber *caller;
	/** Number of context switches. */
	int csw;
	/** Fiber id. */
	uint64_t fid;
	/** Fiber flags */
	uint32_t flags;
	struct clock_stat clock_stat;
	/** Link in cord->alive or cord->dead list. */
	struct rlist link;
	/** Link in cord->ready list. */
	struct rlist state;

	/** Triggers invoked before this fiber yields. Must not throw. */
	struct rlist on_yield;
	/**
	 * Triggers invoked before this fiber is stopped/reset/
	 * recycled/destroyed/reused. In other words, each time
	 * when the fiber has finished execution of a request.
	 * In particular, for fibers not from a fiber pool the
	 * stop event is emitted before destruction and death.
	 * Pooled fibers receive the stop event after each
	 * request, even if they are never destroyed.
	 */
	struct rlist on_stop;
	/** Triggers invoked before fiber is recycled. */
	struct rlist on_destroy;
	/**
	 * The list of fibers awaiting for this fiber's timely
	 * (or untimely) death.
	 */
	struct rlist wake;

	/**
	 * This struct is considered as non-POD when compiling by g++.
	 * You can safely ignore all offset_of-related warnings.
	 * See http://gcc.gnu.org/bugzilla/show_bug.cgi?id=31488
	 */
	fiber_func f;
	union {
		/**
		 * Argument list passed when the fiber is invoked in a blocking
		 * way, so the caller may pass arguments from its own stack.
		 */
		va_list f_data;
		/**
		 * Fiber function argument which passed asynchronously. Can be
		 * used not to call fiber_start to avoid yields, but still pass
		 * something into the fiber.
		 */
		void *f_arg;
	};
	int f_ret;
	/** Fiber local storage. */
	struct {
		/**
		 * Current transaction, session and the active
		 * user credentials are shared among multiple
		 * requests and valid even out of a former.
		 */
		struct session *session;
		struct credentials *credentials;
		struct txn *txn;
		/** Fields related to Lua code execution. */
		struct {
			/**
			 * Optional Lua state (may be NULL).
			 * Useful as a temporary Lua state to save
			 * time and resources on creating it.
			 * Should not be used in other fibers.
			 */
			struct lua_State *stack;
			/**
			 * Optional reference to userdata
			 * representing current fiber id in Lua.
			 */
			int fid_ref;
			/**
			 * Optional fiber.storage Lua reference.
			 */
			int storage_ref;
			/** Optional reference to the Lua object f.pmu. */
			int pmu_ref;
		} lua;
		/**
		 * Iproto sync.
		 */
		struct {
			uint64_t sync;
		} net;
	} storage;
	/** An object to wait for incoming message or a reader. */
	struct ipc_wait_pad *wait_pad;
	/** Exception which caused this fiber's death. */
	struct diag diag;
	/**
	 * Name points at inline_name in case it is short. Long
	 * name is allocated on the heap.
	 */
	char *name;
	char inline_name[FIBER_NAME_INLINE];
	/** The counters of this fiber and their settings. */
	struct fiber_pmu pmu;
#ifdef ENABLE_BACKTRACE
	/* Fiber parent's backtrace allocated on the 'gc' region. */
	struct backtrace_lua *parent_bt;
#endif /* ENABLE_BACKTRACE */
};

/** Invoke on_stop triggers and delete them. */
void
fiber_on_stop(struct fiber *f);

struct cord_on_exit;

/**
 * @brief An independent execution unit that can be managed by a separate OS
 * thread. Each cord consists of fibers to implement cooperative multitasking
 * model.
 */
struct cord {
	/** The fiber that is currently being executed. */
	struct fiber *fiber;
	struct ev_loop *loop;
	/**
	 * Every new fiber gets a new monotonic id. Ids 0 - 100 are
	 * reserved.
	 */
	uint64_t next_fid;
	struct clock_stat clock_stat;
	struct cpu_stat cpu_stat;
	/** The counters of the fibers of this cord and their settings. */
	struct cord_pmu pmu;
	pthread_t id;
	const struct cord_on_exit *on_exit;
	/** A helper hash to map id -> fiber. */
	struct mh_i64ptr_t *fiber_registry;
	/** All fibers */
	struct rlist alive;
	/** Fibers, ready for execution */
	struct rlist ready;
	/** A cache of dead fibers for reuse */
	struct rlist dead;
	/**
	 * Latest dead fiber which couldn't be reused and waits for its
	 * deletion. A fiber can't be reused if it is somehow non-standard. For
	 * instance, has a special stack.
	 * A fiber can't be deleted if it is the current fiber - can't delete
	 * own stack safely. Then it schedules own deletion for later. The
	 * approach is very similar to pthread stacks deletion - pthread can't
	 * delete own stack, so they are saved and deleted later by a newer
	 * pthread or by some other dying pthread. Same here with fibers.
	 */
	struct fiber *garbage;
	/** A watcher to have a single async event for all ready fibers.
	 * This technique is necessary to be able to suspend
	 * a single fiber on a few watchers (for example,
	 * a timeout and an event from network, whichever comes
	 * first).
	 * */
	ev_async wakeup_event;
	/**
	 * libev sleeps at least backend_mintime, which is 1 ms in
	 * case of poll()/Linux, unless there are idle watchers.
	 * This is a special hack to speed up fiber_sleep(0),
	 * i.e. a sleep with a zero timeout, to ensure that there
	 * is no 1 ms delay in case of zero sleep timeout.
	 */
	ev_idle idle_event;
	/** An event triggered on every event loop iteration start. */
	ev_check check_event;
	/**
	 * An event triggered on every event loop iteration end.
	 * Just like the event above it is used in per-fiber cpu
	 * time calculations.
	 */
	ev_prepare prepare_event;
	/** A memory cache for (struct fiber) */
	struct mempool fiber_mempool;
	/** A runtime slab cache for general use in this cord. */
	struct slab_cache slabc;
	/** The "main" fiber of this cord, the scheduler. */
	struct fiber sched;
	/**
	 * Time when the current fiber was called.
	 * Needed for checking slices. A low resolution
	 * monotonic clock is used to measure the time
	 * to reduce performance as little as possible.
	 */
	double call_time;
	/**
	 * Default max slice for fibers in seconds.
	 * It is used if running fiber has no custom max slice.
	 */
	struct fiber_slice max_slice;
	/** Slice for current fiber execution in seconds. */
	struct fiber_slice slice;
	/**
	 * Seed for rand_r(), initialized when the cord is created.
	 * The goal of using an own seed is to minimize the impact
	 * of randomness between cords.
	 */
	unsigned int seed;
	char name[FIBER_NAME_INLINE];
};

extern __thread struct cord *cord_ptr;

/**
 * True if the fiber counters are on for the current fiber. It is set on
 * each context switch.
 * It is not in struct cord, so that the check of the counters that are
 * off does not need the cord.
 */
extern __thread bool fiber_pmu_enabled;

/** Names of the fiber counters, as fiber.info() shows them. */
extern const char *fiber_pmu_counter_strs[fiber_pmu_counter_MAX];

/**
 * Returns a thread-local cord object.
 *
 * If the cord object wasn't initialized at thread start (cord_create()
 * wasn't called), a cord object is created automatically and destroyed
 * at thread exit.
 */
#define cord() ({							\
	if (unlikely(cord_ptr == NULL))					\
		cord_ptr = cord_on_demand();				\
	cord_ptr;							\
})

#define fiber() cord()->fiber
#define loop() (cord()->loop)

/**
 * Return true if the counters are on for the current fiber. It answers
 * the same question as fiber_pmu_is_enabled() asked about the current
 * fiber, but from a thread-local cache that is kept fresh at fiber
 * switches, so it costs one read. Use it in the paths that count events.
 */
static inline bool
fiber_pmu_is_enabled_for_self(void)
{
	return fiber_pmu_enabled;
}

/**
 * Add a value to a counter of the current fiber and to the sums of the
 * cord, if the counters are on.
 */
static inline void
fiber_pmu_add(enum fiber_pmu_counter counter, uint64_t value)
{
	if (fiber_pmu_is_enabled_for_self()) {
		struct cord *cord = cord();
		cord->fiber->pmu.values[counter] += value;
		cord->pmu.values[counter] += value;
	}
}

/**
 * Add the increment of the counter source of the current fiber of a cord
 * to its counter.
 */
static inline void
fiber_pmu_source_flush(struct cord *cord)
{
	struct fiber_pmu_source *source = &cord->fiber->pmu.source;
	if (source->value == NULL)
		return;
	uint64_t value = *source->value;
	fiber_pmu_add(source->counter, value - source->base);
	source->base = value;
}

/**
 * Make a value the counter source of the current fiber. The previous
 * source is saved to `prev`. Call fiber_pmu_source_pop() with it
 * before the value is freed.
 */
static inline void
fiber_pmu_source_push(enum fiber_pmu_counter counter, const uint64_t *value,
		      struct fiber_pmu_source *prev)
{
	struct fiber *fiber = fiber();
	fiber_pmu_source_flush(cord());
	*prev = fiber->pmu.source;
	fiber->pmu.source.counter = counter;
	fiber->pmu.source.value = value;
	fiber->pmu.source.base = *value;
}

/** Remove the counter source of the current fiber, restore `prev`. */
static inline void
fiber_pmu_source_pop(const struct fiber_pmu_source *prev)
{
	fiber_pmu_source_flush(cord());
	fiber()->pmu.source = *prev;
}

void
cord_create(struct cord *cord, const char *name);

/**
 * Perform all the thread-specific deinitialization. Must be called in the
 * exiting thread.
 */
void
cord_exit(struct cord *cord);

void
cord_destroy(struct cord *cord);

/**
 * Start a cord with the given thread function.
 * The return value of the function can be collected
 * with cord_join(). The function *must catch* all
 * exceptions and leave them in the diagnostics
 * area, cord_join() moves the exception from the
 * terminated cord to the caller of cord_join().
 */
int
cord_start(struct cord *cord, const char *name,
	   void *(*f)(void *), void *arg);

/**
 * Like cord_start(), but starts the event loop and
 * a fiber in the event loop. The event loop ends when the
 * fiber in main fiber dies/returns. The exception of the main
 * fiber is propagated to cord_cojoin().
 */
int
cord_costart(struct cord *cord, const char *name, fiber_func f, void *arg);

/**
 * Yield until \a cord has terminated.
 *
 * On success:
 *
 * If \a cord has terminated with an uncaught exception
 * the exception is moved to the current fiber's diagnostics
 * area, otherwise the current fiber's diagnostics area is
 * cleared.
 * @param cord cord
 * @sa pthread_join()
 *
 * @return 0 on success, -1 if pthread_join failed or the
 * thread function terminated with an exception.
 */
int
cord_cojoin(struct cord *cord);

/**
 * Wait for \a cord to terminate. If \a cord has already
 * terminated, then returns immediately.
 *
 * @post If the subject cord terminated with an exception,
 * preserves the exception in the caller's cord.
 *
 * @param cord cord
 * @return 0 on success, -1 if pthread_join failed or the
 * thread function terminated with an exception.
 */
int
cord_join(struct cord *cord);

void
cord_set_name(const char *name);

/** Set the cord-local random seed used by rand_r(). */
API_EXPORT void
cord_set_seed(unsigned int seed);

static inline const char *
cord_name(struct cord *cord)
{
	return cord->name;
}

/** @return a current cord name. */
API_EXPORT const char *
current_cord_name(void);

/** True if this cord represents the process main thread. */
bool
cord_is_main(void);

/**
 * Like `cord_is_main` but without creating a new cord
 * if it doesn't exists.
 */
API_EXPORT bool
cord_is_main_dont_create(void);

/**
 * Delete the latest garbage fiber which couldn't be deleted somewhy before. Can
 * safely rely on the fiber being not the current one. Because if it was added
 * here before, it means some previous fiber put itself here, then died
 * immediately afterwards for good, and gave control to another fiber. It
 * couldn't be scheduled again.
 */
void
cord_collect_garbage(struct cord *cord);

/**
 * Pthread-cancel the thread and join it in a blocking way, without yielding.
 * That way is the only possible one if the event loop is already destroyed.
 * Should only be used as an emergency, because all the cord resources simply
 * leak.
 */
void
cord_cancel_and_join(struct cord *cord);

/**
 * @brief Create a new system fiber.
 *
 * @details
 * Works the same way as fiber_new(), but uses fiber_attr_default
 * supplemented by the FIBER_IS_SYSTEM flag in order to create a
 * fiber.
 *
 * @param name       string with fiber name
 * @param fiber_func func for run inside fiber
 */
struct fiber *
fiber_new_system(const char *name, fiber_func f);

void
fiber_init(int (*fiber_invoke)(fiber_func f, va_list ap));

void
fiber_free(void);

/**
 * Manually init signals needed for fiber module.
 * This function is re-entrant.
 * All needed signals are initialized in fiber_init,
 * but you may need this functions to init signals
 * after they have been reset before fork.
 */
void
fiber_signal_init(void);

/**
 * Reset signals needed for fiber module.
 * See fiber_signal_init description.
 */
void
fiber_signal_reset(void);

/**
 * Set fiber name.
 * @param fiber Fiber to set name for.
 * @param name A new name of @a fiber.
 */
static inline void
fiber_set_name(struct fiber *fiber, const char *name)
{
	fiber_set_name_n(fiber, name, strlen(name));
}

/** Helper function to check if slice is valid. */
static inline bool
fiber_slice_is_valid(struct fiber_slice slice)
{
	return slice.err >= 0 && slice.warn >= 0;
}

/**
 * Time since current fiber was called.
 * A low resolution monotonic clock is used to measure
 * the time to reduce performance as little as possible.
 */
static inline double
fiber_time_from_call(void)
{
	return clock_lowres_monotonic() - cord()->call_time;
}

/**
 * Set slice for current fiber execution.
 * Slices must be greater than 0.
 */
static inline void
fiber_set_slice(struct fiber_slice slice)
{
	assert(cord_is_main());
	assert(fiber_slice_is_valid(slice));
	cord()->slice = slice;
}

/**
 * Extend slice for current fiber execution.
 * Slices must be greater than 0.
 */
static inline void
fiber_extend_slice(struct fiber_slice slice)
{
	assert(cord_is_main());
	assert(fiber_slice_is_valid(slice));
	cord()->slice.err += slice.err;
	cord()->slice.warn += slice.warn;
}

/**
 * Set max slice for current cord.
 * It will be used for fibers without custom max slice.
 * Slices must be greater than 0.
 */
static inline void
fiber_set_default_max_slice(struct fiber_slice slice)
{
	assert(cord_is_main());
	assert(fiber_slice_is_valid(slice));
	cord()->max_slice = slice;
	if ((fiber()->flags & FIBER_CUSTOM_SLICE) == 0)
		cord()->slice = slice;
}

/**
 * Set max slice to fiber. Must be called in the thread in which the cord
 * that manages this fiber is located.
 * Slices must be greater than 0.
 */
static inline void
fiber_set_max_slice(struct fiber *fib, struct fiber_slice slice)
{
	assert(cord_is_main());
	assert(fiber_slice_is_valid(slice));
	fib->max_slice = slice;
	fib->flags |= FIBER_CUSTOM_SLICE;
	if (fiber() == fib)
		cord()->slice = slice;
}

/**
 * Returns the max effective slice applied to the given fiber.
 */
static inline struct fiber_slice
fiber_get_max_slice(struct fiber *fib)
{
	assert(cord_is_main());
	return (fib->flags & FIBER_CUSTOM_SLICE) != 0 ?
	       fib->max_slice : cord()->max_slice;
}

/**
 * Check if slice is over for current cord.
 */
static inline int
fiber_check_slice(void)
{
	assert(cord_is_main());
	double time_from_call = fiber_time_from_call();
	struct fiber_slice slice = cord()->slice;
	if (unlikely(slice.warn < time_from_call)) {
		say_warn("fiber has not yielded for more than %.3lf seconds",
			 slice.warn);
		cord()->slice.warn = TIMEOUT_INFINITY;
	}
	if (unlikely(slice.err < time_from_call)) {
		diag_set(FiberSliceIsExceeded);
		return -1;
	}
	return 0;
}

bool
fiber_checkstack(void);

/**
 * @brief yield & check for timeout
 * @return true if timeout exceeded
 */
bool
fiber_yield_timeout(ev_tstamp delay);

/**
 * Yield and check for deadline.
 * Return true if deadline exceeded.
 */
bool
fiber_yield_deadline(ev_tstamp deadline);

/**
 * Add current fiber to f->wake and yield.
 * Return true if deadline exceeded.
 */
bool
fiber_wait_on_deadline(struct fiber *f, double deadline);

void
fiber_destroy_all(struct cord *cord);

void
fiber_call(struct fiber *callee);

void
fiber_schedule_cb(ev_loop * /* loop */, ev_watcher *watcher, int revents);

static inline bool
fiber_is_dead(struct fiber *f)
{
	return f->flags & FIBER_IS_DEAD;
}

typedef int (*fiber_stat_cb)(struct fiber *f, void *ctx);

int
fiber_stat(fiber_stat_cb cb, void *cb_ctx);

bool
fiber_top_is_enabled(void);

void
fiber_top_enable(void);

void
fiber_top_disable(void);

#ifdef ENABLE_BACKTRACE
/**
 * Returns current value of fiber parent backtrace collection option.
 */
bool
fiber_parent_backtrace_is_enabled(void);

/**
 * Enables collection of fiber parent's backtrace.
 */
void
fiber_parent_backtrace_enable(void);

/**
 * Disables collection of fiber parent's backtrace.
 */
void
fiber_parent_backtrace_disable(void);
#endif /* ENABLE_BACKTRACE */

/** Useful for C unit tests */
static inline int
fiber_c_invoke(fiber_func f, va_list ap)
{
	return f(ap);
}

#ifdef ENABLE_BACKTRACE
/**
 * Whether leak backtrace is provided when leak is found or not.
 *
 * By default is true in debug build and false otherwise.
 */
extern bool fiber_leak_backtrace_enable;
#endif

/**
 * Whether we should abort if leak is found.
 *
 * By default is true if compiled with ABORT_ON_LEAK and false otherwise.
 */
extern bool fiber_abort_on_gc_leak;

/**
 * Check if region gc has no allocations except for fiber itself internal
 * usage.
 */
void
fiber_check_gc(void);

/**
 * Return fiber's Lua state or NULL if it doesn't exist.
 */
struct lua_State *
fiber_lua_state(struct fiber *f);

#if defined(__cplusplus)
} /* extern "C" */

/**
 * Test if this fiber is in a cancellable state and was indeed
 * cancelled, and raise an exception (FiberIsCancelled) if
 * that's the case.
 */
static inline void
fiber_testcancel(void)
{
	/*
	 * Fiber can catch FiberIsCancelled using try..catch
	 * block in C or pcall()/xpcall() in Lua. However,
	 * FIBER_IS_CANCELLED flag is still set and the subject
	 * fiber will be killed by subsequent unprotected call of
	 * this function.
	 */
	if (fiber_is_cancelled())
		tnt_raise(FiberIsCancelled);
}

static inline struct fiber *
fiber_new_xc(const char *name, fiber_func func)
{
	struct fiber *f = fiber_new(name, func);
	if (f == NULL) {
		diag_raise();
		unreachable();
	}
	return f;
}

/**
 * The same as fiber_new_system(), but throws an exception
 */
static inline struct fiber *
fiber_new_system_xc(const char *name, fiber_func func)
{
	struct fiber *f = fiber_new_system(name, func);
	if (f == NULL) {
		diag_raise();
		unreachable();
	}
	return f;
}

static inline int
fiber_cxx_invoke(fiber_func f, va_list ap)
{
	try {
		return f(ap);
	} catch (struct error *e) {
		return -1;
	}
}

/**
 * Helper to check fiber gc when exiting current scope.
 */
struct FiberGCChecker {
	~FiberGCChecker()
	{
		fiber_check_gc();
	}
};

#endif /* defined(__cplusplus) */

#endif /* TARANTOOL_LIB_CORE_FIBER_H_INCLUDED */
