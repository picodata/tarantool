local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'fiber-pmu-info'})
    g.server:start()
    g.server:exec(function()
        local ffi = require('ffi')
        ffi.cdef([[
            void cord_pmu_start(void);
            void cord_pmu_stop(void);
            size_t cord_pmu_read(uint64_t *values, size_t count);
        ]])
        box.schema.space.create('test')
        box.space.test:create_index('pk')
        for i = 1, 3 do
            box.space.test:insert({i})
        end
    end)
end)

g.after_all(function()
    g.server:drop()
end)

g.after_each(function()
    g.server:exec(function()
        require('ffi').C.cord_pmu_stop()
    end)
end)

-- Check that fiber info has no pmu field when all the counters of the
-- fiber are zero.
g.test_off = function()
    g.server:exec(function()
        local fiber = require('fiber')
        t.assert_equals(fiber.self():info().pmu, nil)
        t.assert_equals(fiber.info()[fiber.self():id()].pmu, nil)
    end)
end

-- Check that fiber info shows all the counters, also the zero ones, if
-- at least one of them is not zero, also when the counters are stopped,
-- with the work that the current fiber did since it last yielded. The
-- CPU instructions are not shown if the hardware counter is unavailable.
g.test_on = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        -- The fiber of the request can have the counts of the requests
        -- before.
        local before = fiber.self().pmu:read()
        box.space.test:select()
        box.space.test:replace({4})
        local after = fiber.self().pmu:read()
        if after.cpu_insn ~= nil then
            t.assert_gt(after.cpu_insn, before.cpu_insn)
        end
        -- fiber info shows all the counters. Its own work grows the
        -- instructions, so they are checked apart.
        local pmu = fiber.info()[fiber.self():id()].pmu
        if after.cpu_insn ~= nil then
            t.assert_ge(pmu.cpu_insn, after.cpu_insn)
            pmu.cpu_insn = nil
        end
        after.cpu_insn = nil
        t.assert_equals(pmu, after)
        before.cpu_insn = nil
        t.assert_equals(after, {
            vdbe_opcodes = before.vdbe_opcodes,
            rows_read = before.rows_read + 3,
            rows_written = before.rows_written + 1,
            rows_returned = before.rows_returned,
        })
        box.space.test:delete({4})
    end)
end

-- Check that fiber info shows the counters of a fiber that is suspended.
g.test_other_fiber = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        local f = fiber.new(function()
            box.space.test:get({1})
            fiber.sleep(10)
        end)
        fiber.yield()
        t.assert_equals(f:info().pmu.rows_read, 1)
        t.assert_equals(fiber.info()[f:id()].pmu.rows_read, 1)
        f:cancel()
    end)
end

-- Check that the last counters, also the instructions, stay visible after
-- the counters are stopped, although the hardware counter closes. The
-- instructions are absent if the hardware counter is unavailable.
g.test_after_stop = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        local f = fiber.new(function()
            box.space.test:get({1})
            fiber.sleep(10)
        end)
        fiber.yield()
        -- The instructions are shown only if the hardware counter opened.
        local has_insn = f.pmu:read().cpu_insn ~= nil
        ffi.C.cord_pmu_stop()
        local counters = f.pmu:read()
        t.assert_equals(counters.rows_read, 1)
        if has_insn then
            t.assert_not_equals(counters.cpu_insn, nil)
            t.assert_not_equals(f:info().pmu.cpu_insn, nil)
        end
        f:cancel()
    end)
end

-- Check that fiber_object.pmu:read() gives the same counters as fiber
-- info, zeroes when they are off, and that the pmu object has no
-- counters, only the methods.
g.test_read = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        local f = fiber.new(function()
            box.space.test:get({1})
            fiber.sleep(10)
        end)
        -- The instructions are 0 or absent: they are shown only after
        -- the hardware counted them at least once.
        local zeros = f.pmu:read()
        if zeros.cpu_insn ~= nil then
            t.assert_equals(zeros.cpu_insn, 0)
            zeros.cpu_insn = nil
        end
        t.assert_equals(zeros, {vdbe_opcodes = 0, rows_read = 0,
                                rows_written = 0, rows_returned = 0})
        ffi.C.cord_pmu_start()
        fiber.yield()
        local counters = f.pmu:read()
        t.assert_equals(f:info().pmu, counters)
        t.assert_equals(counters.vdbe_opcodes, 0)
        t.assert_equals(counters.rows_read, 1)
        t.assert_equals(f.pmu.rows_read, nil)
        t.assert_equals(f.pmu.cpu_insn, nil)
        -- The values are taken at the call: a new table each time.
        local before = fiber.self().pmu:read()
        box.space.test:get({1})
        t.assert_equals(fiber.self().pmu:read().rows_read,
                        before.rows_read + 1)
        f:cancel()
    end)
end

-- Check that fiber_object.pmu.counter and fiber.pmu.counter read the
-- counters when a field is read, and that read() is their snapshot.
g.test_counter = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local yaml = require('yaml')
        local counter = fiber.self().pmu.counter
        local total = fiber.pmu.counter
        t.assert_equals(counter.rows_read, fiber.self().pmu:read().rows_read)
        t.assert_equals(total.rows_read, fiber.pmu.read().rows_read)
        t.assert_equals(yaml.decode(yaml.encode(counter)).rows_read,
                        counter.rows_read)
        fiber.pmu.start()
        local before = counter.rows_read
        local total_before = total.rows_read
        box.space.test:get({1})
        t.assert_equals(counter.rows_read - before, 1)
        t.assert_equals(total.rows_read - total_before, 1)
        t.assert_equals(counter.unknown, nil)
        local snapshot = fiber.self().pmu:read()
        t.assert_equals(snapshot.rows_read, counter.rows_read)
        t.assert_equals(snapshot.vdbe_opcodes, counter.vdbe_opcodes)
        t.assert_equals(yaml.decode(yaml.encode(counter)).rows_read,
                        counter.rows_read)
        t.assert_equals(fiber.pmu.read().rows_read, total.rows_read)
    end)
end

-- Check that fiber.pmu.read() gives the sums of the counters of all the
-- fibers, also of the dead ones, also when the counters are off for all
-- of them.
g.test_total = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        local function rows_read()
            return fiber.pmu.read().rows_read
        end
        t.assert_type(fiber.pmu.read(), 'table')
        fiber.pmu.start()
        local before = rows_read()
        local f = fiber.new(function() box.space.test:select() end)
        f:set_joinable(true)
        f:join()
        box.space.test:get({1})
        t.assert_equals(rows_read() - before, 4)
        t.assert_equals(fiber.pmu.rows_read, nil)
        local total = fiber.pmu.read()
        t.assert_equals(total.cpu_insn ~= nil,
                        fiber.self().pmu:read().cpu_insn ~= nil)
        -- A fiber that counts alone keeps the sums growing.
        fiber.pmu.stop()
        t.assert_equals(rows_read() - before, 4)
        fiber.self().pmu:start()
        t.assert_equals(rows_read() - before, 4)
        f = fiber.new(function() box.space.test:select() end)
        f:set_joinable(true)
        f:join()
        box.space.test:get({1})
        t.assert_equals(rows_read() - before, 5)
        -- The FFI function gives the same sums.
        local names = {'cpu_insn', 'vdbe_opcodes', 'rows_read',
                       'rows_written', 'rows_returned'}
        local values = ffi.new('uint64_t[?]', #names)
        t.assert_equals(ffi.C.cord_pmu_read(values, #names), #names)
        t.assert_equals(values[2], rows_read())
    end)
end

-- Check that the rows of a transaction are counted as written when it
-- commits, so a rollback or a failed write does not count them.
g.test_rows_written_commit = function()
    t.tarantool.skip_if_not_debug()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        local function rows_written()
            return fiber.self().pmu.counter.rows_written
        end
        local before = rows_written()
        box.begin()
        box.space.test:replace({10})
        box.space.test:replace({11})
        box.rollback()
        t.assert_equals(rows_written() - before, 0)
        box.begin()
        box.space.test:replace({10})
        local sp = box.savepoint()
        box.space.test:replace({11})
        box.rollback_to_savepoint(sp)
        box.commit()
        t.assert_equals(rows_written() - before, 1)
        box.error.injection.set('ERRINJ_WAL_IO', true)
        t.assert_error(box.space.test.replace, box.space.test, {12})
        box.error.injection.set('ERRINJ_WAL_IO', false)
        t.assert_equals(rows_written() - before, 1)
        box.space.test:delete({10})
        t.assert_equals(rows_written() - before, 2)
    end)
end

-- Check the rows written by deletes. A delete of memtx counts only if
-- the row exists. A delete of vinyl writes a statement blindly when it has
-- no secondary index, on_replace trigger or WAL extension to require a
-- lookup, so it always counts. When vinyl looks up the row and does not
-- find it, it writes nothing and does not count.
g.test_rows_written_delete = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        local function rows_written()
            return fiber.self().pmu.counter.rows_written
        end
        local v = box.schema.space.create('v', {engine = 'vinyl'})
        v:create_index('pk')
        local before = rows_written()
        box.space.test:delete({100})
        t.assert_equals(rows_written() - before, 0)
        v:insert({1})
        t.assert_equals(rows_written() - before, 1)
        v:delete({1})
        t.assert_equals(rows_written() - before, 2)
        v:delete({1})
        t.assert_equals(rows_written() - before, 3)
        v:drop()
    end)
end

-- Check the rows written by a vinyl delete and upsert that find no row.
-- With a secondary index, on_replace trigger or WAL extension vinyl looks
-- up the row before writing, and a missing row writes nothing.
g.test_rows_written_vinyl_noop = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.C.cord_pmu_start()
        local function rows_written()
            return fiber.self().pmu.counter.rows_written
        end
        local v = box.schema.space.create('v', {engine = 'vinyl'})
        v:create_index('pk')
        v:create_index('sk', {parts = {{2, 'unsigned'}}, unique = false})
        local before = rows_written()
        v:delete({100})
        t.assert_equals(rows_written() - before, 0)
        v:upsert({100, 1}, {{'=', 2, 1}})
        t.assert_equals(rows_written() - before, 1)
        -- The upsert above wrote the row, so deleting it writes again.
        v:delete({100})
        t.assert_equals(rows_written() - before, 2)
        v:drop()
    end)
end
