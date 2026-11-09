#include "memory.h"
#include "fiber.h"

#include <sys/wait.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#endif

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

/** Return the count of instructions of a fiber. */
static uint64_t
insn_count(const struct fiber *fiber)
{
	uint64_t values[fiber_pmu_counter_MAX];
	fail_if(fiber_pmu_read(fiber, values, lengthof(values)) !=
		fiber_pmu_counter_MAX);
	return values[FIBER_PMU_CPU_INSN];
}

/** Each iteration of the work loop takes at least one instruction. */
enum { WORK_SMALL = 100000, WORK_BIG = 10000000 };

static volatile uint64_t work_sink;

/** Execute at least `n` instructions. */
static void
work(uint64_t n)
{
	for (uint64_t i = 0; i < n; i++)
		work_sink += i;
}

/** The count of the current fiber grows when the fiber does work. */
static void
test_basic(void)
{
	plan(3);
	header();

	cord_pmu_start();
	ok(cord_pmu_is_enabled(), "start again is a no-op");
	/*
	 * The instructions of an iteration depend on the compiler: at -O0
	 * on ARM64 it is 15. So the count is compared with the hardware
	 * counter.
	 */
	struct insn_counter *counter = &cord()->pmu.insn_counter;
	uint64_t raw_start = insn_counter_read(counter);
	uint64_t start = insn_count(NULL);
	work(WORK_SMALL);
	uint64_t end = insn_count(NULL);
	uint64_t raw = insn_counter_read(counter) - raw_start;
	ok(end - start >= WORK_SMALL, "count includes the work");
	ok(end - start <= raw, "count is not larger than the hardware counted");

	footer();
	check_plan();
}

static uint64_t big_fiber_count;

static int
big_f(va_list ap)
{
	(void)ap;
	uint64_t start = insn_count(NULL);
	work(WORK_BIG);
	big_fiber_count = insn_count(NULL) - start;
	return 0;
}

/**
 * The count of a fiber does not include the instructions of the fibers
 * that run while it waits.
 */
static void
test_yield(void)
{
	plan(5);
	header();

	struct fiber *f = fiber_new("big", big_f);
	fail_if(f == NULL);
	fiber_set_joinable(f, true);
	is(insn_count(f), 0, "count of a new fiber is 0");

	uint64_t start = insn_count(NULL);
	fiber_wakeup(f);
	fiber_sleep(0);
	uint64_t end = insn_count(NULL);
	ok(big_fiber_count >= WORK_BIG, "other fiber counts its work");
	ok(end - start < WORK_BIG / 10, "current fiber does not count it");

	uint64_t f_count = insn_count(f);
	ok(f_count >= WORK_BIG, "count of other fiber includes its work");
	work(WORK_SMALL);
	is(insn_count(f), f_count,
	   "count of a suspended fiber does not change");
	fiber_join(f);

	footer();
	check_plan();
}

/** Disable freezes the counts, enable continues them. */
static void
test_disable(void)
{
	plan(3);
	header();

	uint64_t start = insn_count(NULL);
	work(WORK_SMALL);
	cord_pmu_stop();
	uint64_t frozen = insn_count(NULL);
	ok(frozen - start >= WORK_SMALL, "disable keeps the counted work");
	work(WORK_SMALL);
	is(insn_count(NULL), frozen, "count does not change when off");

	cord_pmu_start();
	work(WORK_SMALL);
	ok(insn_count(NULL) - frozen >= WORK_SMALL,
	   "count continues after enable");

	footer();
	check_plan();
}

/**
 * A fiber that dies without a join does not pass its count to a new
 * fiber that reuses its struct.
 */
static void
test_insn_dead_fiber(void)
{
	plan(1);
	header();

	struct fiber *f = fiber_new("big", big_f);
	fail_if(f == NULL);
	fiber_wakeup(f);
	fiber_sleep(0);
	struct fiber *g = fiber_new("big", big_f);
	fail_if(g != f);
	is(insn_count(g), 0, "count of a new fiber is 0");
	fiber_wakeup(g);
	fiber_sleep(0);

	footer();
	check_plan();
}

static int
work_big_f(va_list ap)
{
	(void)ap;
	work(WORK_BIG);
	return 0;
}

/** The sums of the cord include the last run of a fiber that dies. */
static void
test_insn_total_dead_fiber(void)
{
	plan(1);
	header();

	uint64_t values[fiber_pmu_counter_MAX];
	cord_pmu_read(values, lengthof(values));
	uint64_t start = values[FIBER_PMU_CPU_INSN];
	struct fiber *f = fiber_new("big", work_big_f);
	fail_if(f == NULL);
	fiber_wakeup(f);
	fiber_sleep(0);
	cord_pmu_read(values, lengthof(values));
	ok(values[FIBER_PMU_CPU_INSN] - start >= WORK_BIG,
	   "sum includes the work of a dead fiber");

	footer();
	check_plan();
}

/**
 * The instructions that are on for one fiber are not counted for the
 * other fibers. The hardware counter is open while some fiber counts.
 */
static void
test_insn_for_one_fiber(void)
{
	plan(8);
	header();

	struct insn_counter *counter = &cord()->pmu.insn_counter;
	struct fiber *f = fiber_new("big", big_f);
	fail_if(f == NULL);
	fiber_set_joinable(f, true);
	fiber_pmu_start(f);
	ok(insn_counter_is_open(counter), "hardware counter is open");

	uint64_t start = insn_count(NULL);
	fiber_wakeup(f);
	fiber_sleep(0);
	work(WORK_SMALL);
	is(insn_count(NULL), start, "current fiber does not count");
	ok(big_fiber_count >= WORK_BIG, "other fiber counts its work");
	fiber_join(f);
	ok(!insn_counter_is_open(counter),
	   "hardware counter is closed when the last fiber that counts dies");

	fiber_pmu_start(NULL);
	ok(insn_counter_is_open(counter), "hardware counter is open again");
	start = insn_count(NULL);
	work(WORK_SMALL);
	ok(insn_count(NULL) - start >= WORK_SMALL, "current fiber counts");
	fiber_pmu_stop(NULL);
	ok(!insn_counter_is_open(counter),
	   "hardware counter is closed when the last fiber setting is off");
	fiber_pmu_start(NULL);
	cord_pmu_stop();
	ok(!insn_counter_is_open(counter),
	   "hardware counter is closed when the counters are off for all");

	footer();
	check_plan();
}

/** Return the count of rows read of a fiber. */
static uint64_t
fiber_rows_read(const struct fiber *fiber)
{
	uint64_t values[fiber_pmu_counter_MAX];
	fiber_pmu_read(fiber, values, lengthof(values));
	return values[FIBER_PMU_ROWS_READ];
}

/** Return the count of rows read of the current fiber. */
static uint64_t
rows_read(void)
{
	return fiber_rows_read(NULL);
}

static int
add_rows_f(va_list ap)
{
	(void)ap;
	fiber_pmu_add(FIBER_PMU_ROWS_READ, 1);
	return 0;
}

/** Make a fiber that adds one row read when it runs. */
static struct fiber *
rows_fiber_new(void)
{
	struct fiber *f = fiber_new("rows", add_rows_f);
	fail_if(f == NULL);
	fiber_set_joinable(f, true);
	return f;
}

/** Run a fiber of rows_fiber_new(), return its rows read and join it. */
static uint64_t
rows_fiber_run(struct fiber *f)
{
	fiber_wakeup(f);
	fiber_sleep(0);
	uint64_t count = fiber_rows_read(f);
	fiber_join(f);
	return count;
}

/**
 * The setting of one fiber does not change the other fibers. The setting
 * for all the fibers cancels the settings of single fibers.
 */
static void
test_api_for_one_fiber(void)
{
	plan(12);
	header();

	enum fiber_pmu_counter c = FIBER_PMU_ROWS_READ;
	fiber_pmu_start(NULL);
	ok(fiber_pmu_is_enabled(fiber()), "on for current fiber");
	ok(!cord_pmu_is_enabled(), "off for the cord");
	is(rows_fiber_run(rows_fiber_new()), 0, "other fiber does not count");
	uint64_t start = rows_read();
	fiber_pmu_add(c, 1);
	is(rows_read() - start, 1, "current fiber counts");

	cord_pmu_start();
	fiber_pmu_stop(NULL);
	ok(!fiber_pmu_is_enabled(NULL), "off for current fiber");
	is(rows_fiber_run(rows_fiber_new()), 1, "other fiber counts");
	fiber_pmu_add(c, 1);
	is(rows_read() - start, 1, "current fiber does not count");

	struct fiber *f = rows_fiber_new();
	ok(fiber_pmu_is_enabled(f), "new fiber follows the cord");
	fiber_pmu_stop(f);
	ok(!fiber_pmu_is_enabled(f), "off for the new fiber");
	is(rows_fiber_run(f), 0, "new fiber does not count");

	cord_pmu_start();
	ok(fiber_pmu_is_enabled(NULL),
	   "enable for all cancels the setting of a fiber");
	cord_pmu_stop();
	f = rows_fiber_new();
	ok(!fiber_pmu_is_enabled(f), "new fiber is off");
	rows_fiber_run(f);

	footer();
	check_plan();
}

static int
enable_self_f(va_list ap)
{
	(void)ap;
	fiber_pmu_start(NULL);
	return 0;
}

/**
 * The counters of the last fiber that turned them on for itself stop
 * when it dies without a join.
 */
static void
test_dead_fiber(void)
{
	plan(1);
	header();

	struct fiber *f = fiber_new("self", enable_self_f);
	fail_if(f == NULL);
	fiber_wakeup(f);
	fiber_sleep(0);
	uint64_t start = rows_read();
	fiber_pmu_add(FIBER_PMU_ROWS_READ, 1);
	is(rows_read(), start, "current fiber does not count");

	footer();
	check_plan();
}

/** Return the sum of the rows read of all the fibers. */
static uint64_t
total_rows_read(void)
{
	uint64_t values[fiber_pmu_counter_MAX];
	fail_if(cord_pmu_read(values, lengthof(values)) !=
		fiber_pmu_counter_MAX);
	return values[FIBER_PMU_ROWS_READ];
}

/**
 * The sums of the counters include the work of all the fibers while the
 * counters are on for them, also of the dead fibers and of the counter
 * sources.
 */
static void
test_total(void)
{
	plan(4);
	header();

	uint64_t start = total_rows_read();
	cord_pmu_start();
	rows_fiber_run(rows_fiber_new());
	fiber_pmu_add(FIBER_PMU_ROWS_READ, 2);
	is(total_rows_read() - start, 3, "sum of all the fibers");

	cord_pmu_stop();
	struct fiber *f = rows_fiber_new();
	fiber_pmu_start(f);
	rows_fiber_run(f);
	rows_fiber_run(rows_fiber_new());
	fiber_pmu_add(FIBER_PMU_ROWS_READ, 1);
	is(total_rows_read() - start, 4, "sum of the fibers that count");

	fiber_pmu_start(NULL);
	uint64_t value = 10;
	struct fiber_pmu_source prev;
	fiber_pmu_source_push(FIBER_PMU_ROWS_READ, &value, &prev);
	value += 5;
	is(total_rows_read() - start, 9, "sum includes the counter source");
	fiber_pmu_source_pop(&prev);
	is(total_rows_read() - start, 9, "source is counted once");
	cord_pmu_stop();

	footer();
	check_plan();
}

/**
 * The generic API: start and stop of the counters, reset, the size of
 * the array. The counters that do not need the hardware.
 */
static void
test_api(void)
{
	plan(13);
	header();

	enum fiber_pmu_counter c = FIBER_PMU_ROWS_READ;
	ok(!cord_pmu_is_enabled(), "counters are off by default");
	fiber_pmu_add(c, 5);
	is(rows_read(), 0, "counter that is off does not count");

	fiber_pmu_reset(NULL);
	is(rows_read(), 0, "reset of a fiber that counted nothing");

	cord_pmu_start();
	ok(cord_pmu_is_enabled(), "counters are on");
	fiber_pmu_add(c, 5);
	cord_pmu_stop();
	ok(!cord_pmu_is_enabled(), "counters are off");
	fiber_pmu_add(c, 5);
	is(rows_read(), 5, "counter counts only while it is on");

	/* Reset one fiber: the sums of the cord keep their values. */
	fiber_pmu_reset(NULL);
	is(rows_read(), 0, "reset of the current fiber");
	is(total_rows_read(), 5, "cord sums do not change");
	cord_pmu_start();
	fiber_pmu_add(c, 7);
	cord_pmu_stop();
	is(rows_read(), 7, "counter counts from zero after the reset");
	is(total_rows_read(), 12, "cord sums count from their old value");

	cord_pmu_reset();
	is(total_rows_read(), 0, "reset of the sums of the cord");

	uint64_t values[fiber_pmu_counter_MAX + 2];
	is(fiber_pmu_read(NULL, values, lengthof(values)),
	   fiber_pmu_counter_MAX, "larger array gets all the counters");
	values[1] = 42;
	is(fiber_pmu_read(NULL, values, 1) * 100 + values[1], 142,
	   "smaller array gets only its size");

	footer();
	check_plan();
}

#if defined(__linux__)

/** The directory of the PMUs in sysfs. */
static const char *pmu_dir = "/sys/bus/event_source/devices";

/**
 * Open a pinned event that counts the instructions of this thread on
 * the cores of a PMU type, or on the default cores if the type is 0.
 */
static int
pinned_insn_event_open(uint32_t type)
{
	struct perf_event_attr attr;
	memset(&attr, 0, sizeof(attr));
	attr.size = sizeof(attr);
	attr.type = PERF_TYPE_HARDWARE;
	attr.config = PERF_COUNT_HW_INSTRUCTIONS | (uint64_t)type << 32;
	attr.exclude_kernel = 1;
	attr.exclude_hv = 1;
	attr.pinned = 1;
	return syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
}

/**
 * The counter does not open if other pinned events took all the
 * hardware counters, so it never counts only a part of the time.
 */
static void
test_insn_busy(void)
{
	plan(3);
	header();

	/*
	 * Take all the hardware counters of every type of cores, so that
	 * the test does not depend on the core that runs it. A CPU with
	 * one type of cores gets events without a type.
	 */
	uint32_t types[INSN_COUNTER_EVENT_MAX];
	int type_count = insn_counter_find_core_pmus(pmu_dir, types,
						     lengthof(types));
	fail_if(type_count > INSN_COUNTER_EVENT_MAX);
	if (type_count <= 1) {
		type_count = 1;
		types[0] = 0;
	}
	/* More than the hardware counters of any CPU. */
	enum { EVENT_COUNT = 64 };
	int fds[EVENT_COUNT * INSN_COUNTER_EVENT_MAX];
	int fd_count = 0;
	for (int t = 0; t < type_count; t++) {
		for (int i = 0; i < EVENT_COUNT; i++) {
			fds[fd_count] = pinned_insn_event_open(types[t]);
			fail_if(fds[fd_count] < 0);
			fd_count++;
		}
	}
	struct insn_counter counter;
	insn_counter_create(&counter);
	is(insn_counter_open(&counter), -1, "busy counters: open fails");
	ok(!insn_counter_is_open(&counter), "busy counters: not open");
	for (int i = 0; i < fd_count; i++)
		close(fds[i]);
	is(insn_counter_open(&counter), 0, "free counters: open succeeds");
	insn_counter_close(&counter);

	footer();
	check_plan();
}

/** Write a file of a fake PMU. */
static void
pmu_file_write(const char *dir, const char *pmu, const char *name,
	       const char *text)
{
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%s/%s", dir, pmu);
	mkdir(path, 0700);
	snprintf(path, sizeof(path), "%s/%s/%s", dir, pmu, name);
	FILE *f = fopen(path, "w");
	fail_if(f == NULL);
	fputs(text, f);
	fclose(f);
}

/** Only the PMUs with the file "cpus" are the PMUs of CPU cores. */
static void
test_find_core_pmus(void)
{
	plan(5);
	header();

	char dir[] = "/tmp/fiber_pmu.XXXXXX";
	fail_if(mkdtemp(dir) == NULL);
	pmu_file_write(dir, "cpu_core", "cpus", "0-7\n");
	pmu_file_write(dir, "cpu_core", "type", "4\n");
	pmu_file_write(dir, "cpu_atom", "cpus", "8-15\n");
	pmu_file_write(dir, "cpu_atom", "type", "10\n");
	pmu_file_write(dir, "uncore", "cpumask", "0\n");
	pmu_file_write(dir, "uncore", "type", "12\n");

	uint32_t types[INSN_COUNTER_EVENT_MAX];
	is(insn_counter_find_core_pmus(dir, types, lengthof(types)), 2,
	   "two PMUs of cores");
	ok((types[0] == 4 && types[1] == 10) ||
	   (types[0] == 10 && types[1] == 4), "types of the PMUs of cores");
	is(insn_counter_find_core_pmus(dir, types, 1), 2,
	   "more PMUs than the array");
	is(insn_counter_find_core_pmus("/nonexistent", types,
				       lengthof(types)), -1,
	   "no directory, error");

	char cmd[PATH_MAX + 16];
	snprintf(cmd, sizeof(cmd), "rm -rf %s", dir);
	fail_if(system(cmd) != 0);
	ok(true, "cleanup");

	footer();
	check_plan();
}

/**
 * A counter with several events adds their values. An event that is not
 * on a hardware counter keeps its value and is read from the cache.
 * Here the second event is stopped like the event of the cores of
 * another type when the thread does not run on them.
 */
static void
test_insn_two_events(void)
{
	header();
	/*
	 * Two events of the same PMU, both count. On a hybrid CPU the
	 * test cannot know the PMU of the core that runs it.
	 */
	uint32_t types[INSN_COUNTER_EVENT_MAX];
	int type_count = insn_counter_find_core_pmus(pmu_dir, types,
						     lengthof(types));
	if (type_count == 0) {
		char path[PATH_MAX];
		snprintf(path, sizeof(path), "%s/cpu/type", pmu_dir);
		FILE *f = fopen(path, "r");
		fail_if(f == NULL);
		fail_if(fscanf(f, "%u", &types[0]) != 1);
		fclose(f);
	}
	struct insn_counter counter;
	insn_counter_create(&counter);
	const char *skip = NULL;
	if (type_count < 0) {
		skip = "the PMUs cannot be listed";
	} else if (type_count > 1) {
		skip = "hybrid CPU";
	} else if (insn_counter_open_pmus(&counter, types, 1) != 0) {
		/* For example, Linux takes the PMU type since 5.13. */
		skip = diag_last_error(diag_get())->errmsg;
	} else {
		insn_counter_close(&counter);
	}
	if (skip != NULL) {
		plan(1);
		ok(true, "# skip; %s", skip);
		footer();
		check_plan();
		return;
	}
	plan(4);
	types[1] = types[0];
	is(insn_counter_open_pmus(&counter, types, 2), 0, "open two events");

	uint64_t start = insn_counter_read(&counter);
	work(WORK_BIG);
	uint64_t both = insn_counter_read(&counter) - start;
	ok(both >= 2 * WORK_BIG, "both events count the work");

	ioctl(counter.events[1].fd, PERF_EVENT_IOC_DISABLE, 0);
	insn_counter_read(&counter);
	start = insn_counter_read(&counter);
	work(WORK_BIG);
	uint64_t one = insn_counter_read(&counter) - start;
	/* Each event counts about half of `both`. */
	ok(one >= WORK_BIG && one < both * 3 / 4,
	   "stopped event does not count");
	ok(counter.events[1].is_lock_valid ||
	   counter.events[1].page == NULL,
	   "stopped event is read from the cache");
	insn_counter_close(&counter);

	footer();
	check_plan();
}

/**
 * If the PMUs cannot be listed, the counter opens one event on a CPU that
 * is known to have one type of cores. Only x86 tells it.
 */
static void
test_insn_no_pmu_dir(void)
{
	plan(2);
	header();

	uint32_t types[INSN_COUNTER_EVENT_MAX];
	int count = insn_counter_find_core_pmus(insn_counter_pmu_dir, types,
						lengthof(types));
#if defined(__x86_64__) || defined(__i386__)
	bool is_uniform = count <= 1;
#else
	bool is_uniform = false;
#endif
	const char *dir = insn_counter_pmu_dir;
	insn_counter_pmu_dir = "/nonexistent";
	struct insn_counter counter;
	insn_counter_create(&counter);
	int rc = insn_counter_open(&counter);
	insn_counter_pmu_dir = dir;
	is(rc == 0, is_uniform, "open without the PMU directory");
	if (rc == 0) {
		uint64_t start = insn_counter_read(&counter);
		work(WORK_SMALL);
		ok(insn_counter_read(&counter) - start >= WORK_SMALL,
		   "one event counts the work");
		insn_counter_close(&counter);
	} else {
		ok(true, "# skip; the CPU can have several types of cores");
	}

	footer();
	check_plan();
}

/**
 * The fast read with rdpmc gives the value of the kernel. If the page
 * is mapped after the first read(), the fast read is wrong by 2^48
 * until the thread is rescheduled. Compare the sums of all PMU events
 * to account for the different core types of a hybrid CPU.
 */
static void
test_insn_fast_read(void)
{
	plan(1);
	header();

	struct insn_counter counter;
	insn_counter_create(&counter);
	fail_if(insn_counter_open(&counter) != 0);
	uint64_t fast = insn_counter_read(&counter);
	uint64_t kernel = 0;
	for (int i = 0; i < counter.event_count; i++) {
		uint64_t value;
		fail_if(read(counter.events[i].fd, &value,
			     sizeof(value)) != sizeof(value));
		kernel += value;
	}
	ok(kernel >= fast && kernel - fast < WORK_SMALL,
	   "fast read agrees with the kernel");
	insn_counter_close(&counter);

	footer();
	check_plan();
}

#endif /* defined(__linux__) */

/**
 * The child of fork() counts its own instructions. The counter of the
 * parent does not count it: on Linux the child would crash on the page
 * of the event, on macOS its count would wrap.
 */
static void
test_insn_fork(void)
{
	plan(1);
	header();

	uint64_t before = insn_count(NULL);
	pid_t pid = fork();
	fail_if(pid < 0);
	if (pid == 0) {
		uint64_t start = insn_count(NULL);
		work(WORK_SMALL);
		uint64_t end = insn_count(NULL);
		/* The count goes on from the one of the parent. */
		bool is_ok = start - before < 10 * WORK_SMALL &&
			     end - start >= WORK_SMALL &&
			     end - start < 100 * WORK_SMALL;
		_exit(is_ok ? 0 : 1);
	}
	int status;
	fail_if(waitpid(pid, &status, 0) != pid);
	ok(WIFEXITED(status) && WEXITSTATUS(status) == 0,
	   "the child counts its instructions");

	footer();
	check_plan();
}

static int
main_f(va_list ap)
{
	(void)ap;
	header();
	/*
	 * Check if the hardware counter of instructions is available. Open
	 * it here and not with cord_pmu_start(), which keeps the
	 * error only in the log.
	 */
	struct insn_counter probe;
	insn_counter_create(&probe);
	bool has_insn = insn_counter_open(&probe) == 0;
	insn_counter_close(&probe);
#if defined(__linux__)
	plan(has_insn ? 16 : 6);
#else
	plan(has_insn ? 11 : 5);
#endif
	if (!has_insn)
		ok(true, "# skip; %s", diag_last_error(diag_get())->errmsg);
#if defined(__linux__)
	test_find_core_pmus();
#endif
	test_api();
	test_api_for_one_fiber();
	test_dead_fiber();
	test_total();
	if (has_insn) {
		cord_pmu_start();
		test_basic();
		test_yield();
		test_disable();
		test_insn_dead_fiber();
		test_insn_total_dead_fiber();
		test_insn_fork();
		cord_pmu_stop();
		test_insn_for_one_fiber();
#if defined(__linux__)
		test_insn_busy();
		test_insn_fast_read();
		test_insn_two_events();
		test_insn_no_pmu_dir();
#endif
	}
	footer();
	check_plan();
	ev_break(loop(), EVBREAK_ALL);
	return 0;
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);
	struct fiber *main_fiber = fiber_new("main", main_f);
	fail_if(main_fiber == NULL);
	fiber_wakeup(main_fiber);
	ev_run(loop(), 0);
	fiber_free();
	memory_free();
	return 0;
}
