local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'nested-join-columns'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t(x INT PRIMARY KEY, y INT);]])
        box.execute([[INSERT INTO t VALUES (1, 10);]])
        box.execute([[CREATE TABLE t0(x INT PRIMARY KEY, y INT);]])
        box.execute([[CREATE TABLE t1(x INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TABLE t2(x INT PRIMARY KEY, b INT);]])
        box.execute([[INSERT INTO t0 VALUES (1, 100);]])
        box.execute([[INSERT INTO t1 VALUES (1, 11), (2, 12);]])
        box.execute([[INSERT INTO t2 VALUES (1, 21);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The column of the right-hand table of a USING join in parentheses is
-- still there, visible by its table's name.
g.test_right_join_column = function()
    g.server:exec(function()
        local sql = [[SELECT t2.* FROM t AS t3
                      CROSS JOIN (t AS t1 JOIN t AS t2 USING (x));]]
        local res = box.execute(sql)
        t.assert_equals(#res.metadata, 2)
        t.assert_equals(res.rows, {{1, 10}})

        sql = [[SELECT t2.x FROM t AS t3
                CROSS JOIN (t AS t1 JOIN t AS t2 USING (x));]]
        t.assert_equals(box.execute(sql).rows, {{1}})

        -- A NATURAL join, where all of the columns are join columns.
        sql = [[SELECT t2.* FROM t AS t3
                CROSS JOIN (t AS t1 NATURAL JOIN t AS t2);]]
        t.assert_equals(box.execute(sql).rows, {{1, 10}})
    end)
end

-- The join column is taken once by "*" and by its name alone, and the
-- tables' own copies of it are hidden, keeping the order of the columns.
g.test_join_column_taken_once = function()
    g.server:exec(function()
        local sql = [[SELECT * FROM t0, (t1 JOIN t2 USING (x));]]
        local res = box.execute(sql)
        t.assert_equals(#res.metadata, 5)
        t.assert_equals(res.rows, {{1, 100, 1, 11, 21}})

        sql = [[SELECT x, t0.x, t1.x, t2.x
                FROM t0 JOIN (t1 JOIN t2 USING (x)) USING (x);]]
        t.assert_equals(box.execute(sql).rows, {{1, 1, 1, 1}})
    end)
end

-- In a LEFT JOIN, the right-hand copy of the join column is NULL where
-- there is no match, while the join column is not.
g.test_left_join_column = function()
    g.server:exec(function()
        local sql = [[SELECT x, t1.x, t2.x, b
                      FROM (SELECT 0 AS z), (t1 LEFT JOIN t2 USING (x))
                      ORDER BY a;]]
        t.assert_equals(box.execute(sql).rows,
                        {{1, 1, 1, 21}, {2, 2, nil, nil}})

        -- The join column is ambiguous with a column of another table.
        sql = [[SELECT x FROM t0, (t1 LEFT JOIN t2 USING (x));]]
        local _, err = box.execute(sql)
        t.assert_equals(err.message, 'ambiguous column name: X')
    end)
end

-- With sql_full_column_names, the columns of a join in parentheses are
-- still found by their table's name.
g.test_full_column_names = function()
    g.server:exec(function()
        box.session.settings.sql_full_column_names = true
        local sql = [[SELECT t1.a, t2.b FROM t0,
                      (t1 JOIN t2 ON t1.x = t2.x);]]
        local res1, err1 = box.execute(sql)
        sql = [[SELECT x, t1.x, t2.x
                FROM t0 JOIN (t1 JOIN t2 USING (x)) USING (x);]]
        local res2, err2 = box.execute(sql)
        box.session.settings.sql_full_column_names = false
        t.assert_equals(err1, nil)
        t.assert_equals(res1.rows, {{11, 21}})
        t.assert_equals(err2, nil)
        t.assert_equals(res2.rows, {{1, 1, 1}})
    end)
end
