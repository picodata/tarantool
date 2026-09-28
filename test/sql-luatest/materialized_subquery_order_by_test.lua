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
