local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'fiber-pmu-lj'})
    g.server:start()
    g.server:exec(function()
        local ffi = require('ffi')
        -- Runs a loop until the trace compiler of LuaJIT records it: one
        -- recording episode, also an aborted one, opens an episode of the
        -- counter cpu_insn_lj.
        rawset(_G, 'run_hot_loop', function()
            local function hot(x)
                local s = 0
                for i = 1, x do
                    s = s + i
                end
                return s
            end
            for _ = 1, 10 do
                hot(10000)
            end
        end)
        -- A finalizer of an FFI object reads the counters of its fiber:
        -- it runs inside an episode of the counter cpu_insn_lj.
        ffi.cdef[[
            typedef struct {
                uint64_t value;
            } fiber_pmu_gc_probe_t;
        ]]
        rawset(_G, 'gc_probe_seen', false)
        rawset(_G, 'gc_probe_lj', nil)
        ffi.metatype('fiber_pmu_gc_probe_t', {
            __gc = function()
                rawset(_G, 'gc_probe_seen', true)
                local pmu = require('fiber').self().pmu:read()
                rawset(_G, 'gc_probe_lj', pmu.cpu_insn_lj)
            end,
        })
        rawset(_G, 'new_gc_probe', function()
            return ffi.new('fiber_pmu_gc_probe_t')
        end)
    end)
end)

g.after_all(function()
    g.server:drop()
end)

g.before_each(function()
    g.server:exec(function()
        require('fiber').pmu.start()
    end)
end)

g.after_each(function()
    g.server:exec(function()
        require('fiber').pmu.stop()
    end)
end)

-- Returns the instruction counters of the current fiber, or nil when the
-- hardware counter is unavailable: then the instruction counters are not
-- shown at all.
local function insn_counters()
    return g.server:exec(function()
        local pmu = require('fiber').self().pmu:read()
        if pmu.cpu_insn == nil then
            return nil
        end
        return {pmu.cpu_insn, pmu.cpu_insn_lj}
    end)
end

-- Check that the counter grows when a loop compiles into a trace, and
-- stays inside the total of the CPU instructions. The traces are flushed
-- first: a compiled trace runs without a new recording episode.
g.test_jit = function()
    g.server:exec(function()
        if not require('jit').status() then
            t.skip('the JIT compiler is off')
        end
        require('jit').flush()
    end)
    local before = insn_counters()
    if before == nil then
        t.skip('the hardware does not count the instructions')
    end
    g.server:exec(function()
        _G.run_hot_loop()
    end)
    local after = insn_counters()
    local lj = after[2] - before[2]
    t.assert_ge(lj, 1, 'the trace compiler counted its work')
    t.assert_ge(after[1] - before[1], lj,
                'the trace compiler stayed inside the total')
end

-- Check that the counter grows after a full collection, and stays inside
-- the total of the CPU instructions.
g.test_gc = function()
    local before = insn_counters()
    if before == nil then
        t.skip('the hardware does not count the instructions')
    end
    g.server:exec(function()
        collectgarbage('collect')
        collectgarbage('collect')
    end)
    local after = insn_counters()
    local lj = after[2] - before[2]
    t.assert_ge(lj, 1, 'the garbage collector counted its work')
    t.assert_ge(after[1] - before[1], lj,
                'the garbage collector stayed inside the total')
end

-- Check that the counter stays inside the total of the CPU instructions
-- when the trace compiler and the garbage collector run one after another
-- and inside one another: no instruction is counted twice.
g.test_jit_and_gc_inside_total = function()
    g.server:exec(function()
        if not require('jit').status() then
            t.skip('the JIT compiler is off')
        end
        require('jit').flush()
    end)
    local before = insn_counters()
    if before == nil then
        t.skip('the hardware does not count the instructions')
    end
    g.server:exec(function()
        _G.run_hot_loop()
        collectgarbage('collect')
        collectgarbage('collect')
    end)
    local after = insn_counters()
    local lj = after[2] - before[2]
    t.assert_ge(lj, 1, 'LuaJIT counted its own work')
    t.assert_ge(after[1] - before[1], lj,
                'the own work stayed inside the total')
end

-- Check that a read inside a running episode of the garbage collector
-- gives the work of the collector up to the read: a finalizer runs inside
-- the episode of the full collection that calls it. The read right before
-- the collection ends the work counted so far, so the finalizer reads
-- only the work of the running episode.
g.test_read_inside_gc_episode = function()
    local before = insn_counters()
    if before == nil then
        t.skip('the hardware does not count the instructions')
    end
    g.server:exec(function(lj_before)
        _G.new_gc_probe()
        require('fiber').self().pmu:read()
        collectgarbage('collect')
        collectgarbage('collect')
        t.assert_equals(_G.gc_probe_seen, true, 'the finalizer ran')
        t.assert_gt(_G.gc_probe_lj, lj_before,
                    'the read inside the episode gave the work so far')
        local after = require('fiber').self().pmu:read()
        t.assert_gt(after.cpu_insn_lj, lj_before,
                    'the episode ended and its work was counted')
    end, {before[2]})
end
