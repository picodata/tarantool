local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'window-correlated-subquery'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t1(id INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TABLE t2(id INT PRIMARY KEY, a INT, b INT);]])
        box.execute([[INSERT INTO t1 VALUES (1, 1), (2, 2), (3, 3);]])
        box.execute([[INSERT INTO t2 VALUES (1, 1, 10), (2, 2, 20),
                                            (3, 2, 30);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- A correlated subquery with a window function is computed again for each
-- row of the outer query, also when SELECT ALL makes it materialized
-- rather than run as a co-routine.
g.test_materialized_window_subquery_is_correlated = function()
    g.server:exec(function()
        local sql = [[SELECT id, (SELECT ALL sum(b) OVER () FROM t2
                                  WHERE t2.a = t1.a LIMIT 1)
                      FROM t1 ORDER BY id;]]
        t.assert_equals(box.execute(sql).rows,
                        {{1, 10}, {2, 50}, {3, box.NULL}})
    end)
end

-- The same query run as a co-routine, for comparison.
g.test_window_subquery_is_correlated = function()
    g.server:exec(function()
        local sql = [[SELECT id, (SELECT sum(b) OVER () FROM t2
                                  WHERE t2.a = t1.a LIMIT 1)
                      FROM t1 ORDER BY id;]]
        t.assert_equals(box.execute(sql).rows,
                        {{1, 10}, {2, 50}, {3, box.NULL}})
    end)
end
