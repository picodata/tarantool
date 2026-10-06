local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze-wait-samples'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        for i = 1, 3 do
            box.space.T:insert({i, i})
        end
        -- A function that waits and does not use the CPU.
        box.schema.func.create('NAP', {
            language = 'LUA',
            body = [[function(time)
                require('fiber').sleep(time)
                return 1
            end]],
            param_list = {'double'},
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        -- Returns the wait samples of the instructions that call NAP and
        -- the sum of the wait samples of the other instructions.
        rawset(_G, 'wait_samples', function(options, sql)
            local res, err = box.execute(([[EXPLAIN (ANALYZE {%s}, opcode)
                                            %s]]):format(options, sql))
            t.assert_equals(err, nil)
            local nap, other = 0, 0
            for _, row in ipairs(res.rows) do
                local count = tonumber(row[1])
                if row[3]:find('FunctionByName') ~= nil or
                   row[3]:find('BuiltinFunction') ~= nil then
                    nap = nap + count
                else
                    other = other + count
                end
            end
            return nap, other
        end)
    end)
    -- A build that cannot sample the instructions gives an error for the
    -- default mode of EXPLAIN ANALYZE, so these tests are not for it.
    local can_sample = g.server:exec(function()
        local _, err = box.execute([[EXPLAIN ANALYZE SELECT 1;]])
        return err == nil or err.message:find('cannot sample', 1, true) == nil
    end)
    t.skip_if(not can_sample, 'the build cannot sample the instructions')
end)

g.after_all(function()
    g.server:stop()
end)

-- The column of the mode is "wait_samples", after the other measurements.
g.test_column = function()
    g.server:exec(function()
        local function names(options)
            local result = {}
            local sql = ([[EXPLAIN (ANALYZE {%s}) SELECT 1;]]):format(options)
            for _, meta in ipairs(box.execute(sql).metadata) do
                table.insert(result, meta.name)
            end
            return result
        end
        t.assert_equals(names([['mode': 'wait_samples']]),
                        {'wait_samples', 'addr', 'pseudocode'})
        local modes = [=['mode': ['wait_samples', 'samples', 'hits']]=]
        t.assert_equals(names(modes),
                        {'hits', 'samples', 'wait_samples', 'addr',
                         'pseudocode'})
        -- The frequency of the samples is also for the wait samples.
        t.assert_equals(names([['mode': 'wait_samples', 'freq': 10]]),
                        {'wait_samples', 'addr', 'pseudocode'})
    end)
end

-- A wait sample count is a text that is aligned to the right in the width
-- of the name of its column.
g.test_count_alignment = function()
    g.server:exec(function()
        local res = box.execute([[EXPLAIN (ANALYZE {'mode': 'wait_samples'})
                                  SELECT a FROM t;]])
        for _, row in ipairs(res.rows) do
            t.assert_str_matches(row[1], ' *[%d.]+%a?')
            t.assert_equals(#row[1], #'wait_samples')
        end
    end)
end

-- An instruction that waits gets the wait samples: about 99 in a second of
-- the wait. The other instructions get none.
g.test_wait = function()
    g.server:exec(function()
        local nap, other = _G.wait_samples([['mode': 'wait_samples']],
                                        [[SELECT nap(0.5e0);]])
        t.assert_ge(nap, 20)
        t.assert_le(nap, 80)
        t.assert_equals(other, 0)
    end)
end

-- The wait samples of the runs are added, and an instruction in a loop gets
-- the wait samples of all its runs.
g.test_wait_sum = function()
    g.server:exec(function()
        local nap = _G.wait_samples([['mode': 'wait_samples', 'runs': 3]],
                                 [[SELECT nap(0.2e0);]])
        t.assert_ge(nap, 30)
        nap = _G.wait_samples([['mode': 'wait_samples']],
                           [[SELECT nap(0.2e0) FROM t;]])
        t.assert_ge(nap, 30)
    end)
end

-- The time that the other fibers run between the runs gives no wait
-- samples: the statement is in no instruction then.
g.test_no_wait_between_runs = function()
    g.server:exec(function()
        local clock = require('clock')
        local fiber = require('fiber')
        local is_done = false
        local f = fiber.new(function()
            while not is_done do
                local deadline = clock.monotonic() + 0.02
                while clock.monotonic() < deadline do end
                fiber.yield()
            end
        end)
        f:set_joinable(true)
        local options = [['mode': 'wait_samples', 'runs': 10, 'freq': 1000]]
        local nap, other = _G.wait_samples(options, [[SELECT 1;]])
        is_done = true
        f:join()
        t.assert_equals({nap, other}, {0, 0})
    end)
end

-- A statement that does not wait gets no wait samples.
g.test_no_wait = function()
    g.server:exec(function()
        local sql = [[WITH RECURSIVE r(x) AS (
            SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 200000)
            SELECT count(*) FROM r;]]
        local options = [['mode': 'wait_samples', 'freq': 1000]]
        local nap, other = _G.wait_samples(options, sql)
        t.assert_equals({nap, other}, {0, 0})
    end)
end
