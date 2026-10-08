local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze-rollback-stmt'})
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

-- The option is TRUE or FALSE.
g.test_rollback_value = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'rollback_stmt' must be TRUE or FALSE"
        for _, value in ipairs({'1', '0', "'true'", '1.5'}) do
            local sql = [[EXPLAIN (ANALYZE {'rollback_stmt': %s}) SELECT 1;]]
            local _, err = box.execute(sql:format(value))
            t.assert_str_contains(err.message, msg, false, value)
        end
        for _, value in ipairs({'true', 'FALSE'}) do
            local sql = [[EXPLAIN (ANALYZE {'rollback_stmt': %s}) SELECT 1;]]
            local _, err = box.execute(sql:format(value))
            t.assert_equals(err, nil, value)
        end
        -- The error about an unknown option lists this option too.
        local _, err = box.execute([[EXPLAIN (ANALYZE {'kek': 1})
                                     SELECT 1;]])
        t.assert_str_contains(err.message, "the options are 'freq', " ..
                              "'mode', 'rollback_stmt'")
    end)
end

-- With the option, a statement in its own transaction rolls it back.
-- Without the option, and with FALSE, the statement keeps its changes.
g.test_rollback_of_transaction = function()
    g.server:exec(function()
        local _, err = box.execute([[EXPLAIN (ANALYZE {'rollback_stmt': true})
                                     INSERT INTO t VALUES (1, 1);]])
        t.assert_equals(err, nil)
        t.assert_equals(box.space.T:count(), 0)
        t.assert_not(box.is_in_txn())

        box.execute([[EXPLAIN ANALYZE INSERT INTO t VALUES (1, 1);]])
        box.execute([[EXPLAIN (ANALYZE {'rollback_stmt': false})
                      INSERT INTO t VALUES (2, 2);]])
        t.assert_equals(box.space.T:count(), 2)
    end)
end

-- With the option, a run that stops at the timeout rolls back the changes
-- that it made. Here the statement inserts its row, and then its trigger
-- runs until the timeout.
g.test_rollback_at_timeout = function()
    g.server:exec(function()
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW BEGIN
                      INSERT INTO l(a) ]] .. _G.long_query .. [[; END;]])
        local sql = [[EXPLAIN (ANALYZE {'timeout': 0.1, 'rollback_stmt': true})
                      INSERT INTO t VALUES (%d, 1);]]
        local _, err = box.execute(sql:format(1))
        local count = box.space.T:count()
        box.begin()
        box.space.T:insert({10, 10})
        local _, err_in_txn = box.execute(sql:format(2))
        local is_in_txn = box.is_in_txn()
        local count_in_txn = box.space.T:count()
        box.rollback()
        box.execute([[DROP TRIGGER tr;]])
        t.assert_equals(err, nil)
        t.assert_equals(count, 0)
        t.assert_equals(err_in_txn, nil)
        t.assert(is_in_txn)
        t.assert_equals(count_in_txn, 1)
    end)
end

-- If the rollback to the savepoint of the statement fails, the statement
-- fails and the transaction of the user is rolled back, also for a run
-- that stops at the timeout. Here a function of the statement rolls back
-- the row that the savepoint is at.
g.test_rollback_error = function()
    g.server:exec(function()
        box.schema.func.create('RB', {
            language = 'LUA',
            body = [[function()
                box.rollback_to_savepoint(rawget(_G, 'user_savepoint'))
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW BEGIN
                      INSERT INTO l(a) ]] .. _G.long_query .. [[; END;]])
        local msg = 'Can not rollback to savepoint'
        local function run(options)
            box.begin()
            rawset(_G, 'user_savepoint', box.savepoint())
            box.space.L:insert({1, 1})
            local res, err = box.execute(([[EXPLAIN (ANALYZE {%s})
                INSERT INTO t VALUES (1, rb());]]):format(options))
            local is_in_txn = box.is_in_txn()
            box.rollback()
            t.assert_equals(res, nil, options)
            t.assert_str_contains(err.message, msg, false, options)
            t.assert_not(is_in_txn, options)
        end
        run([['rollback_stmt': true, 'timeout': 0.1]])
        box.execute([[DROP TRIGGER tr;]])
        run([['rollback_stmt': true]])
        box.schema.func.drop('RB')
        rawset(_G, 'user_savepoint', nil)
        t.assert_equals(box.space.T:count(), 0)
        t.assert_equals(box.space.L:count(), 0)
    end)
end

-- With the option, a statement in a transaction of the user rolls back
-- only its own changes. The transaction continues.
g.test_rollback_of_savepoint = function()
    g.server:exec(function()
        box.begin()
        box.execute([[INSERT INTO t VALUES (1, 1);]])
        local _, err = box.execute([[EXPLAIN (ANALYZE {'rollback_stmt': true})
                                     INSERT INTO t VALUES (2, 2);]])
        t.assert_equals(err, nil)
        t.assert(box.is_in_txn())
        box.execute([[INSERT INTO t VALUES (3, 3);]])
        box.commit()
        t.assert_equals(box.execute([[SELECT id FROM t;]]).rows, {{1}, {3}})
    end)
end

-- With the option, a statement that fails in a transaction of the user
-- also rolls back only its own changes, for each conflict action: OR FAIL
-- does not keep the rows that are before the error, and OR ROLLBACK does
-- not roll back the transaction.
g.test_rollback_of_savepoint_after_error = function()
    g.server:exec(function()
        box.execute([[INSERT INTO t VALUES (1, 1);]])
        for _, action in ipairs({'FAIL', 'ABORT', 'ROLLBACK'}) do
            box.begin()
            box.execute([[INSERT INTO t VALUES (2, 2);]])
            local sql = ([[EXPLAIN (ANALYZE {'rollback_stmt': true})
                           INSERT OR %s INTO t VALUES (3, 3), (1, 1);]])
            local _, err = box.execute(sql:format(action))
            local is_in_txn = box.is_in_txn()
            box.commit()
            local rows = box.execute([[SELECT id FROM t;]]).rows
            box.space.T:delete({2})
            t.assert_str_contains(err.message, 'Duplicate key exists', false,
                                  action)
            t.assert(is_in_txn, action)
            t.assert_equals(rows, {{1}, {2}}, action)
        end
    end)
end

-- With the option, DELETE without WHERE also rolls back its changes, in
-- its own transaction and in a transaction of the user. Such a DELETE
-- starts no transaction when it does not have the option.
g.test_rollback_of_delete_all = function()
    g.server:exec(function()
        local sql = [[EXPLAIN (ANALYZE {'rollback_stmt': true}) DELETE FROM t;]]
        box.execute([[INSERT INTO t VALUES (1, 1), (2, 2);]])
        local _, err = box.execute(sql)
        t.assert_equals(err, nil)
        t.assert_equals(box.space.T:count(), 2)
        box.begin()
        box.execute([[INSERT INTO t VALUES (3, 3);]])
        _, err = box.execute(sql)
        local is_in_txn = box.is_in_txn()
        box.commit()
        t.assert_equals(err, nil)
        t.assert(is_in_txn)
        t.assert_equals(box.space.T:count(), 3)
        -- Without the option the rows are deleted.
        _, err = box.execute([[EXPLAIN ANALYZE DELETE FROM t;]])
        t.assert_equals(err, nil)
        t.assert_equals(box.space.T:count(), 0)
    end)
end
