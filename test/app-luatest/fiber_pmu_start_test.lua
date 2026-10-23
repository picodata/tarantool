local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'fiber-pmu-start'})
    g.server:start()
    g.server:exec(function()
        local fiber = require('fiber')
        box.schema.space.create('test')
        box.space.test:create_index('pk')
        for i = 1, 3 do
            box.space.test:insert({i})
        end
        -- Makes a fiber that reads all the rows, sleeps and repeats it
        -- after each wakeup.
        rawset(_G, 'reader', function()
            return fiber.new(function()
                while true do
                    box.space.test:select()
                    fiber.sleep(10)
                end
            end)
        end)
        -- Returns the rows read of a fiber. It is 0 if the fiber counted
        -- nothing.
        rawset(_G, 'rows_read', function(f)
            return f.pmu:read().rows_read
        end)
    end)
end)

g.after_all(function()
    g.server:drop()
end)

g.after_each(function()
    g.server:exec(function()
        require('fiber').pmu.stop()
    end)
end)

-- Check that the counters that are on for one fiber count only for it.
g.test_one_fiber = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local a = _G.reader()
        local b = _G.reader()
        a.pmu:start()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        t.assert_equals(_G.rows_read(b), 0)
        t.assert_equals(_G.rows_read(fiber.self()), 0)
        a.pmu:stop()
        -- The fiber reads the rows again, but the counters are off, so
        -- the last values stay.
        a:wakeup()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        a:cancel()
        b:cancel()
    end)
end

-- Check that after start for all and stop for one fiber, the
-- counters count for all the other fibers, also for new ones.
g.test_all_but_one = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local a = _G.reader()
        local b = _G.reader()
        fiber.pmu.start()
        b.pmu:stop()
        local c = _G.reader()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        t.assert_equals(_G.rows_read(b), 0)
        t.assert_equals(_G.rows_read(c), 3)
        a:cancel()
        b:cancel()
        c:cancel()
    end)
end

-- Check that start and stop for all the fibers cancel the settings
-- of single fibers.
g.test_all_cancels_one = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local a = _G.reader()
        local b = _G.reader()
        a.pmu:stop()
        b.pmu:start()
        fiber.pmu.start()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        t.assert_equals(_G.rows_read(b), 3)
        fiber.pmu.stop()
        -- The fibers read the rows again, but the counters are off, so
        -- the last values stay.
        a:wakeup()
        b:wakeup()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        t.assert_equals(_G.rows_read(b), 3)
        a:cancel()
        b:cancel()
    end)
end

-- Check that a fiber that turns the counters on for itself counts the
-- work after it, and that a new fiber does not get the setting of a dead
-- one.
g.test_self = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local f = fiber.new(function()
            box.space.test:select()
            fiber.self().pmu:start()
            box.space.test:get({1})
            return _G.rows_read(fiber.self())
        end)
        f:set_joinable(true)
        local _, count = f:join()
        t.assert_equals(count, 1)
        local new = _G.reader()
        t.assert_equals(_G.rows_read(new), 0)
        new:cancel()
    end)
end

-- Check that reset sets the counters of a fiber or the sums of the cord
-- to zero, and that the counters keep counting after it.
g.test_reset = function()
    g.server:exec(function()
        local fiber = require('fiber')
        fiber.pmu.start()
        local a = _G.reader()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        -- Reset of one fiber does not change the sums of the cord.
        a.pmu:reset()
        t.assert_equals(_G.rows_read(a), 0)
        t.assert_ge(fiber.pmu.read().rows_read, 3)
        -- The fiber counts from zero after the reset.
        a:wakeup()
        fiber.yield()
        t.assert_equals(_G.rows_read(a), 3)
        -- Reset of the sums does not change the counters of a fiber.
        fiber.pmu.reset()
        t.assert_equals(fiber.pmu.read().rows_read, 0)
        t.assert_equals(_G.rows_read(a), 3)
        fiber.pmu.stop()
        a:cancel()
    end)
end

-- Check the FFI functions. NULL is the current fiber.
g.test_ffi = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local fiber = require('fiber')
        ffi.cdef([[
            void cord_pmu_start(void);
            void cord_pmu_stop(void);
            bool cord_pmu_is_enabled(void);
            void fiber_pmu_start(struct fiber *fiber);
            void fiber_pmu_stop(struct fiber *fiber);
            bool fiber_pmu_is_enabled(struct fiber *fiber);
        ]])
        ffi.C.fiber_pmu_start(nil)
        t.assert_equals(ffi.C.cord_pmu_is_enabled(), false)
        t.assert_equals(ffi.C.fiber_pmu_is_enabled(nil), true)
        -- The fiber of the request can have the counts of the requests
        -- before.
        local before = _G.rows_read(fiber.self())
        box.space.test:select()
        t.assert_equals(_G.rows_read(fiber.self()) - before, 3)
        local other = _G.reader()
        fiber.yield()
        t.assert_equals(_G.rows_read(other), 0)
        other:cancel()
        ffi.C.fiber_pmu_stop(nil)
        t.assert_equals(ffi.C.fiber_pmu_is_enabled(nil), false)
        -- The last values stay after the stop.
        t.assert_equals(_G.rows_read(fiber.self()), before + 3)
        ffi.C.cord_pmu_start()
        t.assert_equals(ffi.C.cord_pmu_is_enabled(), true)
        other = _G.reader()
        fiber.yield()
        t.assert_equals(_G.rows_read(other), 3)
        t.assert_equals(_G.rows_read(fiber.self()), before + 3)
        ffi.C.cord_pmu_stop()
        t.assert_equals(ffi.C.cord_pmu_is_enabled(), false)
        t.assert_equals(_G.rows_read(other), 3)
        other:cancel()
    end)
end

-- Check that fiber.pmu and fiber_object.pmu have the methods and the
-- counter object, and no counters of their own.
g.test_fields = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local keys = {}
        for k, v in pairs(fiber.pmu) do
            t.assert_type(v, k == 'counter' and 'userdata' or 'function')
            table.insert(keys, k)
        end
        table.sort(keys)
        t.assert_equals(keys, {'counter', 'is_enabled', 'read', 'reset',
                               'start', 'stop'})
        fiber.pmu.start()
        t.assert_equals(fiber.pmu.rows_read, nil)
        local pmu = fiber.self().pmu
        t.assert_type(pmu.start, 'function')
        t.assert_type(pmu.stop, 'function')
        t.assert_type(pmu.is_enabled, 'function')
        t.assert_type(pmu.read, 'function')
        t.assert_type(pmu.counter, 'userdata')
        t.assert_equals(pmu.rows_read, nil)
    end)
end

-- Check that is_enabled tells if the counters run for all the fibers or
-- for one fiber.
g.test_is_enabled = function()
    g.server:exec(function()
        local fiber = require('fiber')
        t.assert_equals(fiber.pmu.is_enabled(), false)
        t.assert_equals(fiber.self().pmu:is_enabled(), false)
        fiber.self().pmu:start()
        t.assert_equals(fiber.pmu.is_enabled(), false)
        t.assert_equals(fiber.self().pmu:is_enabled(), true)
        local f = _G.reader()
        t.assert_equals(f.pmu:is_enabled(), false)
        fiber.pmu.start()
        t.assert_equals(fiber.pmu.is_enabled(), true)
        t.assert_equals(f.pmu:is_enabled(), true)
        fiber.pmu.stop()
        f:cancel()
    end)
end

-- Check the errors of the Lua functions.
g.test_errors = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local f = _G.reader()
        t.assert_error_msg_equals('fiber.pmu.start(): bad arguments',
                                  fiber.pmu.start, f)
        t.assert_error_msg_equals('fiber.pmu.stop(): bad arguments',
                                  fiber.pmu.stop, f)
        t.assert_error_msg_equals('fiber.pmu.is_enabled(): bad arguments',
                                  fiber.pmu.is_enabled, f)
        t.assert_error_msg_equals('fiber.pmu.reset(): bad arguments',
                                  fiber.pmu.reset, f)
        t.assert_error_msg_equals('fiber.pmu.read(): bad arguments',
                                  fiber.pmu.read, f)
        local pmu = f.pmu
        t.assert_error_msg_equals(
            'fiber_object.pmu:start(): bad arguments', pmu.start, pmu, 1)
        t.assert_error_msg_equals(
            'fiber_object.pmu:stop(): bad arguments', pmu.stop, 1)
        t.assert_error_msg_equals(
            'fiber_object.pmu:is_enabled(): bad arguments', pmu.is_enabled, 1)
        t.assert_error_msg_equals(
            'fiber_object.pmu:reset(): bad arguments', pmu.reset, 1)
        t.assert_error_msg_equals(
            'fiber_object.pmu:read(): bad arguments', pmu.read)
        -- A call with a dot must not turn the counters on.
        t.assert_error_msg_equals(
            'fiber_object.pmu:start(): bad arguments', pmu.start)
        t.assert_error_msg_equals(
            'fiber_object.pmu:start(): bad arguments', pmu.start, f)
        t.assert_equals(_G.rows_read(f), 0)
        f:cancel()
    end)
end

-- Check that the pmu object of a dead fiber keeps its last counters,
-- also if nobody used it before the fiber died, and that it cannot turn
-- the counters on or off.
g.test_dead_fiber = function()
    g.server:exec(function()
        local fiber = require('fiber')
        fiber.pmu.start()
        local f = _G.reader()
        f:set_joinable(true)
        fiber.yield()
        local pmu = f.pmu
        local counter = pmu.counter
        f:cancel()
        f:join()
        t.assert_equals(pmu:read().rows_read, 3)
        t.assert_equals(counter.rows_read, 3)
        t.assert(rawequal(f.pmu, pmu))
        t.assert_error_msg_equals('the fiber is dead', pmu.start, pmu)
        t.assert_error_msg_equals('the fiber is dead', pmu.stop, pmu)
        t.assert_error_msg_equals('the fiber is dead', pmu.is_enabled, pmu)
        t.assert_error_msg_equals('the fiber is dead', pmu.reset, pmu)
        -- The counters do not change after the death, also the
        -- instructions, although the hardware counter closed. The
        -- instructions are absent if the hardware counter is unavailable.
        local has_insn = pmu:read().cpu_instructions ~= nil
        fiber.pmu.stop()
        t.assert_equals(pmu:read().rows_read, 3)
        if has_insn then
            t.assert_not_equals(pmu:read().cpu_instructions, nil)
        end

        fiber.pmu.start()
        f = _G.reader()
        f:set_joinable(true)
        fiber.yield()
        f:cancel()
        f:join()
        t.assert_equals(f.pmu:read().rows_read, 3)
    end)
end

-- Check that a fiber that dies with the counters off keeps its last
-- counters, which are zeroes if it counted nothing. The instructions are
-- shown if the hardware counted them for the other fibers.
g.test_dead_fiber_off = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local f = _G.reader()
        f:set_joinable(true)
        local pmu = f.pmu
        -- A fiber cancelled before it runs sleeps all the time.
        fiber.yield()
        f:cancel()
        f:join()
        local zeros = pmu:read()
        if zeros.cpu_instructions ~= nil then
            t.assert_equals(zeros.cpu_instructions, 0)
            zeros.cpu_instructions = nil
        end
        t.assert_equals(zeros, {vdbe_opcodes = 0, rows_read = 0,
                                rows_written = 0, rows_returned = 0})
        t.assert_equals(pmu.counter.rows_read, 0)
        -- Nobody used the pmu object of this one before it died.
        f = _G.reader()
        f:set_joinable(true)
        fiber.yield()
        f:cancel()
        f:join()
        t.assert_error_msg_contains('the fiber is dead', function()
            return f.pmu
        end)
        t.assert_type(fiber.pmu.read(), 'table')
        -- This one counted before the counters were stopped, nobody used
        -- its pmu object, and it dies at the join after the stop.
        fiber.pmu.start()
        f = _G.reader()
        f:set_joinable(true)
        fiber.yield()
        fiber.pmu.stop()
        f:cancel()
        f:join()
        t.assert_equals(f.pmu:read().rows_read, 3)
    end)
end

-- Check that f.pmu is one object for a fiber, that the fiber object keeps
-- it after the fiber dies, and that it is freed with the fiber object.
g.test_pmu_object_cached = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local refs = setmetatable({}, {__mode = 'v'})
        -- The fiber object is only in the locals of this function.
        local function run()
            local f = fiber.new(function() fiber.sleep(10) end)
            f:set_joinable(true)
            t.assert(rawequal(f.pmu, f.pmu))
            t.assert(rawequal(f.pmu, fiber.find(f:id()).pmu))
            t.assert(rawequal(f.pmu.counter, f.pmu.counter))
            refs[1] = f.pmu
            refs[2] = f.pmu.counter
            fiber.yield()
            f:cancel()
            f:join()
            collectgarbage('collect')
            t.assert(rawequal(refs[1], f.pmu))
        end
        run()
        -- The first cycle frees the fiber object and removes it from the
        -- table of the dead fibers, the second one frees the pmu object.
        collectgarbage('collect')
        collectgarbage('collect')
        t.assert_equals(refs[1], nil)
        t.assert_equals(refs[2], nil)
    end)
end
