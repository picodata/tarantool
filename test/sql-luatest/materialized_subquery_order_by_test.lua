local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'materialized-subquery-order-by'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t(id INT PRIMARY KEY, a INT, b INT);]])
        box.execute([[INSERT INTO t VALUES (1, 1, 10), (2, 2, 20),
                                           (3, 2, 30), (4, 3, 20);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- A CTE with ORDER BY that is used twice is materialized in the order of
-- its ORDER BY. Each of its rows is stored with its own columns.
g.test_cte_with_order_by_used_twice = function()
    g.server:exec(function()
        local sql = [[WITH c(x) AS (SELECT y FROM (SELECT 1 AS y) ORDER BY 1)
                      SELECT * FROM c AS p, c AS q;]]
        t.assert_equals(box.execute(sql).rows, {{1, 1}})

        sql = [[WITH c AS (SELECT b, a FROM t ORDER BY b DESC, a LIMIT 3)
                SELECT p.a, p.b, q.a FROM c AS p, c AS q
                WHERE p.a = q.a ORDER BY 1, 2, 3;]]
        t.assert_equals(box.execute(sql).rows,
                        {{2, 20, 2}, {2, 20, 2}, {2, 30, 2}, {2, 30, 2},
                         {3, 20, 3}})
    end)
end

-- A query with a window function that is materialized rather than run as
-- a co-routine, as SELECT ALL makes it, is sorted by the window ORDER BY.
g.test_materialized_window_query = function()
    g.server:exec(function()
        local sql = [[SELECT ALL max(b) OVER (ORDER BY b) FROM t;]]
        local rows = box.execute(sql).rows
        table.sort(rows, function(x, y) return x[1] < y[1] end)
        t.assert_equals(rows, {{10}, {20}, {20}, {30}})
    end)
end

-- A materialized subquery keeps its rows in the order in which they are
-- inserted, as the ID of the row is the key of its ephemeral space. So a
-- window function sees them in the order of its ORDER BY, not sorted by
-- the values of the columns.
g.test_materialized_window_query_order = function()
    g.server:exec(function()
        local sql = [[SELECT ALL a, b, sum(b) OVER (ORDER BY b, a) FROM t;]]
        t.assert_equals(box.execute(sql).rows,
                        {{1, 10, 10}, {2, 20, 30}, {3, 20, 50}, {2, 30, 80}})

        sql = [[SELECT ALL a, b, sum(b) OVER (ORDER BY b DESC, a DESC)
                FROM t;]]
        t.assert_equals(box.execute(sql).rows,
                        {{2, 30, 30}, {3, 20, 50}, {2, 20, 70}, {1, 10, 80}})
    end)
end

-- The rows of a materialized subquery with LIMIT come in the order of the
-- query it is made of.
g.test_materialized_subquery_order = function()
    g.server:exec(function()
        local sql = [[SELECT * FROM (SELECT b FROM t ORDER BY b DESC, a
                                     LIMIT 3),
                                    (SELECT 1 LIMIT 1);]]
        t.assert_equals(box.execute(sql).rows, {{30, 1}, {20, 1}, {20, 1}})
    end)
end
