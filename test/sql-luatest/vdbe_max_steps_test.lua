local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_each(function()
    g.server = server:new({alias = 'vdbe_max_steps'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[CREATE TABLE t (i INT PRIMARY KEY, a INT);]])
        box.execute([[INSERT INTO t VALUES (1, 1), (2, 2), (3, 3);]])
    end)
end)

g.after_each(function()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[DROP TABLE t;]])
    end)
    g.server:stop()
end)

g.test_above_limit = function()
    g.server:exec(function()
        local _, err = box.execute([[SET SESSION "sql_vdbe_max_steps" = 5;]])
        t.assert_equals(err, nil)

        _, err = box.execute([[SELECT * FROM t;]])
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 5")

        _, err = box.execute([[SELECT * FROM t WHERE i + 1 > 2;]])
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 5")

        _, err = box.execute([[SELECT * FROM t WHERE a > 2;]], {},
                {{sql_vdbe_max_steps = 4}})
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 4")

        _, err = box.execute([[SELECT a, sum(i) FROM t
        WHERE a > ? GROUP BY a;]],
                {2}, {{sql_vdbe_max_steps = 20}})
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 20")
    end)
end

g.test_signature = function()
    g.server:exec(function()
        local _, err = box.execute([[select * from t;]],
                {{sql_vdbe_max_steps = 1}})
        t.assert_equals(err.message, "Parameter 'sql_vdbe_max_steps' " ..
        "was not found in the statement")

        _, err = box.execute([[select i + ? from t;]], {2}, {2, 3, 4})
        t.assert_equals(err.message, "Each option in third argument must " ..
        "be a table containing only one key value pair")

        _, err = box.execute([[select i + ? from t;]], {2},
                {{sql_vdbe_max_steps = -1}})
        t.assert_equals(err.message, "Illegal options: value of the " ..
        "sql_vdbe_max_steps option should be a non-negative integer.")

        _, err = box.execute([[select i + ? from t;]], {2},
                {{vdbe_max_steps = -1}})
        t.assert_equals(err.message, "Illegal options: vdbe_max_steps")

        _, err = box.execute([[select i + ? from t;]], {2}, {})
        t.assert_equals(err, nil)

        -- test prepared statement
        local r
        r, err = box.prepare([[SELECT * FROM t ORDER BY a;]])
        t.assert(r ~= nil and err == nil)
        _, err = r:execute({}, {{sql_vdbe_max_steps = 10}})
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 10")
        end)
end

g.test_sql_trigger = function()
    g.server:exec(function()
        local _, err = box.execute([[SET SESSION "sql_vdbe_max_steps" = 12;]])
        t.assert_equals(err, nil)
        -- such insert without triggers must take 12 opcodes
        _, err = box.execute([[insert into t values (4, 4)]])
        t.assert_equals(err, nil)

        -- create trigger
        _, err = box.execute([[create trigger before insert on t
        for each row begin select * from t; end]], {},
                {{sql_vdbe_max_steps = 0}})
        t.assert_equals(err, nil)

        -- check that now insert will fail for 12 opcodes limit
        _, err = box.execute([[SET SESSION "sql_vdbe_max_steps" = 12;]])
        t.assert_equals(err, nil)
        _, err = box.execute([[insert into t values (5, 5)]])
        t.assert_equals(err.message,
                "Reached a limit on max executed vdbe opcodes. Limit: 12")
    end)
end

g.test_below_limit = function()
    g.server:exec(function()
        local _, err = box.execute([[SET SESSION "sql_vdbe_max_steps" = 20;]])
        t.assert(err == nil)

        local res
        res, err = box.execute([[SELECT max(i) FROM t;]])
        t.assert(res ~= nil and err == nil)

        res, err = box.execute([[SELECT min(i) FROM t;]])
        t.assert(res ~= nil and err == nil)

        res, err = box.execute([[SELECT * FROM t WHERE i = 2;]])
        t.assert(res ~= nil and err == nil)

        res, err = box.execute([[SELECT * FROM t WHERE i > 2;]])
        t.assert(res ~= nil and err == nil)

        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        res, err = box.execute([[SELECT * FROM t INNER JOIN
        (select i as c, a as b from t) on true;]])
        t.assert(res ~= nil and err == nil)
    end)
end
