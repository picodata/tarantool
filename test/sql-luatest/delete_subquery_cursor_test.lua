local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'delete-subquery-cursor'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_seq_scan" = true;]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

g.before_each(function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t(a INTEGER PRIMARY KEY, b INTEGER);]])
        box.execute([[CREATE TABLE s(a INTEGER PRIMARY KEY, b INTEGER);]])
        box.execute([[INSERT INTO t VALUES (1, 1), (3, 3), (4, 4), (5, 5);]])
        box.execute([[INSERT INTO s VALUES (3, 3), (4, 4);]])
    end)
end)

g.after_each(function()
    g.server:exec(function()
        box.execute([[DROP TABLE t;]])
        box.execute([[DROP TABLE s;]])
    end)
end)

-- A DELETE that finds its rows by the primary key deletes them when a
-- subquery of the WHERE clause reads a materialized FROM subquery.
g.test_delete_in_materialized_subquery = function()
    g.server:exec(function()
        local res = box.execute([[
            DELETE FROM t WHERE a IN (
                SELECT q.x FROM (SELECT b AS x FROM s LIMIT 5) AS q, s);
        ]])
        t.assert_equals(res, {row_count = 2})
        t.assert_equals(box.execute([[SELECT a FROM t;]]).rows, {{1}, {5}})
    end)
end

-- The same with a scalar subquery, which gives a DELETE of one row.
g.test_delete_eq_materialized_subquery = function()
    g.server:exec(function()
        local res = box.execute([[
            DELETE FROM t WHERE a = (
                SELECT q.x FROM (SELECT b AS x FROM s LIMIT 1) AS q, s
                LIMIT 1);
        ]])
        t.assert_equals(res, {row_count = 1})
        t.assert_equals(box.execute([[SELECT a FROM t;]]).rows,
                        {{1}, {4}, {5}})
    end)
end

g.test_update_eq_materialized_subquery = function()
    g.server:exec(function()
        -- Different primary and secondary keys expose a cursor mix-up.
        box.execute([[UPDATE t SET b = b * 10;]])
        box.execute([[UPDATE s SET b = b * 10;]])
        box.execute([[CREATE UNIQUE INDEX t_b ON t(b);]])
        local res = box.execute([[
            UPDATE t SET b = b + 1 WHERE b = (
                SELECT q.x FROM (
                    SELECT b AS x FROM s ORDER BY b LIMIT 1
                ) AS q, s LIMIT 1);
        ]])
        t.assert_equals(res, {row_count = 1})
        t.assert_equals(box.execute([[SELECT a, b FROM t ORDER BY a;]]).rows,
                        {{1, 10}, {3, 31}, {4, 40}, {5, 50}})
    end)
end
