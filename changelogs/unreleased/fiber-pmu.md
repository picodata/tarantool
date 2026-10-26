## feature/fiber

* Added per-fiber counters of the CPU instructions, the VDBE opcodes and the
  rows read, written and returned. The rows returned count every SQL
  statement of the fiber, even the internal ones, for example, the
  statements of expression constraints. On Linux the instructions are
  counted in user space, on macOS in user space and in the kernel. On Linux,
  if other pinned perf events take all the hardware counters, the
  instructions are not counted.
* `fiber.pmu.start()` and `fiber.pmu.stop()` turn the counters on and off
  for all the fibers, `fiber_object.pmu:start()` and
  `fiber_object.pmu:stop()` for one fiber. `fiber.pmu.is_enabled()` and
  `fiber_object.pmu:is_enabled()` tell if the counters run. Stop does not
  reset the counters: `fiber_object.pmu:reset()` and `fiber.pmu.reset()`
  zero the counters of a fiber or their sums over the cord.
* `fiber_object.pmu:read()` gives the counters of one fiber, and
  `fiber.pmu.read()` gives their sums over all the fibers, also the dead
  ones. A read always gives values: zeroes if nothing was counted. The CPU
  instructions are an exception: they are not shown if the hardware cannot
  count them.
* `fiber_object.pmu.counter` and `fiber.pmu.counter` are the counters of
  one fiber and of the whole cord. Reading a field of a counter object
  gives the value of that counter, and the object keeps the last values
  after the fiber dies.
* `fiber.info()` shows the counters of a fiber in the `pmu` field: all of
  them if at least one is not zero, for example, `pmu.cpu_instructions`.
  The field does not disappear after a stop.
* The C API:
  * `cord_pmu_start`, `cord_pmu_stop`, `cord_pmu_is_enabled`,
    `cord_pmu_reset` and `cord_pmu_read` for all the fibers of
    the current thread.
  * `fiber_pmu_start`, `fiber_pmu_stop`, `fiber_pmu_is_enabled`,
    `fiber_pmu_reset` and `fiber_pmu_read` for one fiber.
