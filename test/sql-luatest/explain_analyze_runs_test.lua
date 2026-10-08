local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze-runs'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TABLE l (id INT PRIMARY KEY AUTOINCREMENT,
                                      a INT);]])
        for i = 1, 10 do
            box.space.T:insert({i, i})
        end
        -- Returns how many times the instruction at address 0 ran.
        rawset(_G, 'run_count', function(options, sql)
            local res, err = box.execute(([[EXPLAIN (ANALYZE {%s})
                                            %s]]):format(options, sql))
            if res == nil then
                return nil, err
            end
            return tonumber(res.rows[1][1])
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

g.before_each(function()
    g.server:exec(function()
        box.space.L:truncate()
    end)
end)

-- The number of runs is a positive integer.
g.test_runs_value = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'runs' must be a positive integer"
        for _, value in ipairs({'0', '-1', '1.5', "'2'"}) do
            local _, err = box.execute(([[EXPLAIN (ANALYZE {'runs': %s})
                                          SELECT 1;]]):format(value))
            t.assert_str_contains(err.message, msg, false, value)
        end
        -- The error about an unknown option lists this option too.
        local _, err = box.execute([[EXPLAIN (ANALYZE {'kek': 1})
                                     SELECT 1;]])
        t.assert_str_contains(err.message, "the options are 'freq', " ..
                              "'mode', 'rollback_stmt', 'runs', 'timeout'")
    end)
end

-- The counts are the sums of all runs. A new execution of a prepared
-- statement starts them from zero.
g.test_runs_add_counts = function()
    g.server:exec(function()
        local sql = [[SELECT sum(a) FROM t;]]
        t.assert_equals(_G.run_count([['mode': 'hits']], sql), 1)
        t.assert_equals(_G.run_count([['mode': 'hits', 'runs': 3]], sql), 3)
        local stmt = box.prepare([[EXPLAIN (ANALYZE {'mode': 'hits',
                                                     'runs': 2}) ]] .. sql)
        for _ = 1, 2 do
            t.assert_equals(tonumber(stmt:execute().rows[1][1]), 2)
        end
        stmt:unprepare()
    end)
end

-- An error in a run ends the runs. Here the second run inserts the row
-- of the first run again.
g.test_error_ends_runs = function()
    g.server:exec(function()
        local count, err = _G.run_count([['mode': 'hits', 'runs': 3]],
                                        [[INSERT INTO l VALUES (1, 1);]])
        t.assert_equals(count, nil)
        t.assert_str_contains(err.message, 'Duplicate key exists')
        t.assert_equals(box.space.L:count(), 1)
    end)
end

-- A run that stops at its timeout does not end the runs: the timeout is
-- for each run.
g.test_timeout_does_not_end_runs = function()
    g.server:exec(function()
        local clock = require('clock')
        local sql = [[INSERT INTO l(a) WITH RECURSIVE r(x) AS (
            SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 1000000000)
            SELECT x FROM r;]]
        local start = clock.monotonic()
        local count, err = _G.run_count(
            [['mode': 'hits', 'runs': 3, 'timeout': 0.1]], sql)
        t.assert_equals(err, nil)
        t.assert_equals(count, 3)
        t.assert_ge(clock.monotonic() - start, 0.3)
        t.assert_equals(box.space.L:count(), 0)
    end)
end

-- With the option 'rollback_stmt', each run rolls back its changes, thus the
-- next run can insert the same row. In a transaction of the user each run
-- rolls back to its savepoint, and the transaction continues.
g.test_runs_with_rollback = function()
    g.server:exec(function()
        local options = [['mode': 'hits', 'runs': 3, 'rollback_stmt': true]]
        local sql = [[INSERT INTO l VALUES (1, 1);]]
        local count, err = _G.run_count(options, sql)
        t.assert_equals(err, nil)
        t.assert_equals(count, 3)
        t.assert_equals(box.space.L:count(), 0)

        box.begin()
        box.space.L:insert({2, 2})
        count, err = _G.run_count(options, sql)
        local is_in_txn = box.is_in_txn()
        box.commit()
        t.assert_equals(err, nil)
        t.assert_equals(count, 3)
        t.assert(is_in_txn)
        t.assert_equals(box.space.L:select(), {{2, 2}})
    end)
end

-- A savepoint of the user before the statement lets the user roll back
-- the changes of all runs, also after an error in a run.
g.test_runs_with_user_savepoint = function()
    g.server:exec(function()
        box.begin()
        box.execute([[SAVEPOINT s;]])
        local count, err = _G.run_count([['mode': 'hits', 'runs': 3]],
                                        [[INSERT INTO l(a) VALUES (1);]])
        local row_count = box.space.L:count()
        box.execute([[ROLLBACK TO SAVEPOINT s;]])
        t.assert_equals(err, nil)
        t.assert_equals(count, 3)
        t.assert_equals(row_count, 3)
        t.assert_equals(box.space.L:count(), 0)

        count, err = _G.run_count([['mode': 'hits', 'runs': 3]],
                                  [[INSERT INTO l VALUES (1, 1);]])
        row_count = box.space.L:count()
        box.execute([[ROLLBACK TO SAVEPOINT s;]])
        local is_in_txn = box.is_in_txn()
        box.commit()
        t.assert_equals(count, nil)
        t.assert_str_contains(err.message, 'Duplicate key exists')
        t.assert_equals(row_count, 1)
        t.assert(is_in_txn)
        t.assert_equals(box.space.L:count(), 0)
    end)
end

-- The other fibers run between the runs, thus many runs do not block the
-- event loop.
g.test_yield_between_runs = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local wakeups = 0
        local is_done = false
        local f = fiber.new(function()
            while not is_done do
                wakeups = wakeups + 1
                fiber.yield()
            end
        end)
        f:set_joinable(true)
        local count, err = _G.run_count([['mode': 'hits', 'runs': 10]],
                                        [[SELECT sum(a) FROM t;]])
        is_done = true
        f:join()
        t.assert_equals(err, nil)
        t.assert_equals(count, 10)
        t.assert_ge(wakeups, 9)
    end)
end

-- A yield aborts a transaction of memtx, thus in a transaction there is
-- no yield between the runs.
g.test_no_yield_in_transaction = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local wakeups = 0
        local f = fiber.new(function()
            wakeups = wakeups + 1
        end)
        f:set_joinable(true)
        box.begin()
        box.space.L:insert({1, 1})
        local count, err = _G.run_count([['mode': 'hits', 'runs': 10]],
                                        [[SELECT sum(a) FROM t;]])
        local wakeups_in_txn = wakeups
        local ok = pcall(box.commit)
        f:join()
        t.assert_equals(err, nil)
        t.assert_equals(count, 10)
        t.assert_equals(wakeups_in_txn, 0)
        t.assert(ok)
        t.assert_equals(box.space.L:count(), 1)
    end)
end

-- A change of the schema between the runs ends the runs with an error,
-- because the program has pointers to the spaces.
g.test_schema_change_ends_runs = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local f = fiber.new(function()
            box.schema.space.create('tmp')
        end)
        f:set_joinable(true)
        local count, err = _G.run_count([['mode': 'hits', 'runs': 10]],
                                        [[INSERT INTO l(a) VALUES (1);]])
        f:join()
        box.space.tmp:drop()
        t.assert_equals(count, nil)
        t.assert_str_contains(err.message, 'schema version has changed')
    end)
end

-- A run can change the schema too: here a trigger of the statement drops
-- a table after the row is inserted. Then the next run does not start,
-- also in a transaction of the user, where there is no yield between the
-- runs.
g.test_schema_change_in_run_ends_runs = function()
    g.server:exec(function()
        box.schema.func.create('DROP_LOG', {
            language = 'LUA',
            body = [[function()
                if box.space.LOG ~= nil then
                    box.execute('DROP TABLE log;')
                end
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        local function run()
            box.execute([[CREATE TABLE log (id INT PRIMARY KEY AUTOINCREMENT,
                                            a INT);]])
            box.execute([[CREATE TRIGGER tr AFTER INSERT ON l FOR EACH ROW
                          BEGIN INSERT INTO log(a) VALUES (1);
                          SELECT drop_log(); END;]])
            return _G.run_count([['mode': 'hits', 'runs': 3]],
                                [[INSERT INTO l(a) VALUES (1);]])
        end
        local count, err = run()
        box.execute([[DROP TRIGGER tr;]])
        t.assert_equals(count, nil)
        t.assert_str_contains(err.message, 'schema version has changed')

        box.begin()
        count, err = run()
        local is_in_txn = box.is_in_txn()
        box.rollback()
        box.execute([[DROP TRIGGER tr;]])
        box.schema.func.drop('DROP_LOG')
        t.assert_equals(count, nil)
        t.assert_str_contains(err.message, 'schema version has changed')
        t.assert(is_in_txn)
    end)
end

-- A cancel of the fiber ends the runs.
g.test_cancel_ends_runs = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local count, err
        local f = fiber.new(function()
            count, err = _G.run_count([['mode': 'hits', 'runs': 1000000]],
                                      [[SELECT sum(a) FROM t;]])
        end)
        f:set_joinable(true)
        fiber.yield()
        f:cancel()
        f:join()
        t.assert_equals(count, nil)
        t.assert_str_contains(tostring(err), 'fiber is cancelled')
    end)
end
