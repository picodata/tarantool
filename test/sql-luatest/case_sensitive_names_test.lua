local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'case-sensitive-names'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'tr1', 'tr2'}) do
            box.execute(string.format([[DROP TRIGGER IF EXISTS %s;]], name))
        end
        for _, name in ipairs({'"t"', '"T"', 't2', '"C"', 'tt', 'log',
                               'nums'}) do
            box.execute(string.format([[DROP TABLE IF EXISTS %s;]], name))
        end
        for _, name in ipairs({'abs', 'max'}) do
            box.schema.func.drop(name, {if_exists = true})
        end
    end)
end)

-- The tables inside a parenthesized join are told apart by case, like any
-- other names.
g.test_nested_from_table_name = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE "t"(x INTEGER PRIMARY KEY);]])
        box.execute([[CREATE TABLE "T"(z INTEGER PRIMARY KEY);]])
        box.execute([[CREATE TABLE t2(p INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO "t" VALUES (1);]])
        box.execute([[INSERT INTO "T" VALUES (2);]])
        box.execute([[INSERT INTO t2 VALUES (3);]])
        local from = [[ FROM (("t" CROSS JOIN "T") AS s CROSS JOIN t2);]]

        local sql = [[SELECT "t".x, t.z]]..from
        t.assert_equals(box.execute(sql).rows, {{1, 2}})

        sql = [[SELECT "t".*]]..from
        t.assert_equals(box.execute(sql).rows, {{1}})

        sql = [[SELECT "T".*]]..from
        t.assert_equals(box.execute(sql).rows, {{2}})

        local _, err = box.execute([[SELECT "t".z]]..from)
        t.assert_equals(err.message,
                        "Field 'Z' was not found in space 't' format")
    end)
end

-- A table whose name differs from that of a recursive CTE only in case is
-- not a reference to the CTE.
g.test_recursive_cte_name = function()
    g.server:exec(function()
        local sql = [[WITH RECURSIVE "c"(n) AS
                        (SELECT 1 UNION ALL SELECT n + 1 FROM "C" WHERE n < 3)
                      SELECT * FROM "c";]]
        local _, err = box.execute(sql)
        t.assert_equals(err.message, "Space 'C' does not exist")

        box.execute([[CREATE TABLE "C"(n INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO "C" VALUES (1);]])
        t.assert_equals(box.execute(sql).rows, {{1}, {2}})

        sql = [[WITH RECURSIVE c(n) AS
                  (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3)
                SELECT * FROM c;]]
        t.assert_equals(box.execute(sql).rows, {{1}, {2}, {3}})
    end)
end

-- The NEW and OLD rows of a trigger are names like any other, so a quoted
-- name refers to them only if it is spelled in upper case.
g.test_trigger_row_name = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE tt(id INTEGER PRIMARY KEY, a INTEGER);]])
        box.execute([[CREATE TABLE log(id INTEGER PRIMARY KEY AUTOINCREMENT,
                                       v INTEGER);]])
        box.execute([[CREATE TRIGGER tr1 AFTER INSERT ON tt FOR EACH ROW
                      BEGIN INSERT INTO log(v) VALUES (new.a + "NEW".a); END;]])
        box.execute([[CREATE TRIGGER tr2 AFTER UPDATE ON tt FOR EACH ROW
                      BEGIN INSERT INTO log(v) VALUES (old.a + "OLD".a); END;]])
        box.execute([[INSERT INTO tt VALUES (1, 2);]])
        box.execute([[UPDATE tt SET a = 5;]])
        t.assert_equals(box.execute([[SELECT v FROM log;]]).rows, {{4}, {4}})

        box.execute([[DROP TRIGGER tr1;]])
        box.execute([[CREATE TRIGGER tr1 AFTER INSERT ON tt FOR EACH ROW
                      BEGIN INSERT INTO log(v) VALUES ("new".a); END;]])
        local _, err = box.execute([[INSERT INTO tt VALUES (2, 2);]])
        t.assert_equals(err.message,
                        "Field 'A' was not found in space 'new' format")

        box.execute([[DROP TRIGGER tr1;]])
        box.execute([[DROP TRIGGER tr2;]])
        box.execute([[CREATE TRIGGER tr2 AFTER DELETE ON tt FOR EACH ROW
                      BEGIN INSERT INTO log(v) VALUES ("Old".a); END;]])
        _, err = box.execute([[DELETE FROM tt;]])
        t.assert_equals(err.message,
                        "Field 'A' was not found in space 'Old' format")
    end)
end

-- Window names are normalized like any other names and then compared exactly.
g.test_window_name = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE nums(a INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO nums VALUES (1), (2);]])

        local sql = [[SELECT a, SUM(a) OVER "W" FROM nums
                      WINDOW w AS (ORDER BY a);]]
        t.assert_equals(box.execute(sql).rows, {{1, 1}, {2, 3}})

        sql = [[SELECT a, SUM(a) OVER (w) FROM nums
                WINDOW "W" AS (ORDER BY a);]]
        t.assert_equals(box.execute(sql).rows, {{1, 1}, {2, 3}})

        sql = [[SELECT a, SUM(a) OVER "w" FROM nums
                WINDOW "W" AS (ORDER BY a);]]
        local _, err = box.execute(sql)
        t.assert_equals(err.message, "no such window: w")

        sql = [[SELECT a, SUM(a) OVER w1, SUM(a) OVER "w1" FROM nums
                WINDOW w1 AS (ORDER BY a), "w1" AS (ORDER BY a DESC)
                ORDER BY a;]]
        t.assert_equals(box.execute(sql).rows, {{1, 1, 3}, {2, 3, 2}})
    end)
end

-- A user function whose name differs from that of a built-in one only in
-- case is a different function, so calls to them are different expressions.
g.test_function_name = function()
    g.server:exec(function()
        box.schema.func.create('abs', {
            language = 'Lua',
            body = [[function(x) return 100 end]],
            param_list = {'integer'},
            returns = 'integer',
            is_deterministic = true,
            exports = {'LUA', 'SQL'},
        })
        box.execute([[CREATE TABLE nums(a INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO nums VALUES (1), (2);]])

        local sql = [[SELECT "abs"(a), COUNT(*) FROM nums GROUP BY ABS(a);]]
        t.assert_equals(box.execute(sql).rows, {{100, 1}, {100, 1}})

        sql = [[SELECT COUNT(*), ABS(a) FROM nums GROUP BY "abs"(a);]]
        local rows = box.execute(sql).rows
        t.assert_equals(#rows, 1)
        t.assert_equals(rows[1][1], 2)
    end)
end

-- Only the built-in MIN and MAX are computed by reading a single row off an
-- index, not a user aggregate named "min" or "max".
g.test_min_max_name = function()
    g.server:exec(function()
        box.schema.func.create('max', {
            language = 'Lua',
            body = [[function(x, sum) return (sum or 0) + x end]],
            param_list = {'integer', 'integer'},
            returns = 'integer',
            aggregate = 'group',
            exports = {'SQL'},
        })
        box.execute([[CREATE TABLE nums(a INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO nums VALUES (1), (2), (3);]])

        t.assert_equals(box.execute([[SELECT "max"(a) FROM nums;]]).rows,
                        {{6}})
        t.assert_equals(box.execute([[SELECT MAX(a) FROM nums;]]).rows,
                        {{3}})
    end)
end
