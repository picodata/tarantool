local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze-timeout'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TABLE l (id INT PRIMARY KEY AUTOINCREMENT,
                                      a INT);]])
        -- A query that runs much longer than the timeouts of the tests.
        rawset(_G, 'long_query', [[WITH RECURSIVE r(x) AS (
            SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 1000000000)
            SELECT x FROM r]])
        -- Returns the error message of EXPLAIN with an option of ANALYZE.
        rawset(_G, 'option_error', function(option)
            local sql = ([[EXPLAIN (ANALYZE {%s}) SELECT 1;]]):format(option)
            local _, err = box.execute(sql)
            return err ~= nil and err.message or nil
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
        box.space.T:truncate()
        box.space.L:truncate()
    end)
end)

-- The timeout is a non-negative number of seconds: an integer or a number
-- with a fraction. 0 is no limit.
g.test_timeout_value = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'timeout' must be a non-negative " ..
                    "number of seconds"
        for _, value in ipairs({'-1', '-0.5', '-1e0', "'1'", '1e999'}) do
            local err = _G.option_error("'timeout': " .. value)
            t.assert_str_contains(err, msg, false, value)
        end
        for _, value in ipairs({'0', '-0', '1', '0.5', '5e-1'}) do
            t.assert_equals(_G.option_error("'timeout': " .. value), nil,
                            value)
        end
    end)
end

-- The run stops at the timeout, and EXPLAIN ANALYZE lists the program
-- with the counts of the part that ran.
g.test_timeout_stops_run = function()
    g.server:exec(function()
        local clock = require('clock')
        local sql = [[EXPLAIN (ANALYZE {'timeout': 0.1, 'mode': 'hits'}) ]] ..
                    _G.long_query
        local start = clock.monotonic()
        local res, err = box.execute(sql)
        local time = clock.monotonic() - start
        t.assert_equals(err, nil)
        t.assert_ge(time, 0.1)
        t.assert_lt(time, 10)
        t.assert_equals(#res.rows, #box.execute('EXPLAIN ' ..
                                                _G.long_query).rows)
        -- The count is a text like '    1' or '16.7k'.
        local max_count = 0
        for _, row in ipairs(res.rows) do
            local count = tonumber(row[1]:match('[%d.]+')) or 0
            max_count = math.max(max_count, count)
        end
        t.assert_gt(max_count, 1)
    end)
end

-- A run that stops at the timeout keeps the changes that it made before
-- the stop. Here the statement inserts its row, and then its trigger runs
-- until the timeout. In a transaction of the user the row stays in the
-- transaction.
g.test_timeout_keeps_changes = function()
    g.server:exec(function()
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW BEGIN
                      INSERT INTO l(a) ]] .. _G.long_query .. [[; END;]])
        local sql = [[EXPLAIN (ANALYZE {'timeout': 0.1})
                      INSERT INTO t VALUES (%d, 1);]]
        local _, err = box.execute(sql:format(1))
        local count = box.space.T:count()
        box.begin()
        local _, err_in_txn = box.execute(sql:format(2))
        local is_in_txn = box.is_in_txn()
        local count_in_txn = box.space.T:count()
        box.rollback()
        box.execute([[DROP TRIGGER tr;]])
        t.assert_equals(err, nil)
        t.assert_equals(count, 1)
        t.assert_equals(err_in_txn, nil)
        t.assert(is_in_txn)
        t.assert_equals(count_in_txn, 2)
        t.assert_equals(box.space.T:count(), 1)
        t.assert_equals(box.space.L:count(), 0)
    end)
end

-- A run that stops at the timeout commits its transaction. If the commit
-- fails, the statement fails. Here the trigger waits after the row is
-- inserted, which aborts the transaction of memtx, and then it runs until
-- the timeout.
g.test_timeout_commit_error = function()
    g.server:exec(function()
        box.schema.func.create('NAP', {
            language = 'LUA',
            body = [[function()
                require('fiber').sleep(0.01)
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW BEGIN
                      SELECT nap(); SELECT count(*) FROM (]] ..
                    _G.long_query .. [[); END;]])
        local res, err = box.execute([[EXPLAIN (ANALYZE {'timeout': 0.1})
                                       INSERT INTO t VALUES (1, 1);]])
        box.execute([[DROP TRIGGER tr;]])
        box.schema.func.drop('NAP')
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'aborted by a fiber yield')
        t.assert_equals(box.space.T:count(), 0)
    end)
end

-- A run that ends before the timeout keeps its changes, as a run without
-- a timeout does.
g.test_timeout_not_reached = function()
    g.server:exec(function()
        box.execute([[EXPLAIN ANALYZE INSERT INTO t VALUES (1, 1);]])
        box.execute([[EXPLAIN (ANALYZE {'timeout': 0})
                      INSERT INTO t VALUES (2, 2);]])
        box.execute([[EXPLAIN (ANALYZE {'timeout': 100})
                      INSERT INTO t VALUES (3, 3);]])
        t.assert_equals(box.space.T:count(), 3)
    end)
end

-- A prepared statement with a timeout can run again after a run that
-- stopped at the timeout.
g.test_timeout_run_again = function()
    g.server:exec(function()
        local stmt = box.prepare([[EXPLAIN (ANALYZE {'timeout': 0.1})
                                   INSERT INTO l(a) ]] .. _G.long_query)
        for _ = 1, 2 do
            local res, err = stmt:execute()
            t.assert_equals(err, nil)
            t.assert_gt(#res.rows, 0)
        end
        stmt:unprepare()
    end)
end
