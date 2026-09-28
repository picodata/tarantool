local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'window-in-ignored-order-by'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t1(a INT PRIMARY KEY, b INT);]])
        box.execute([[INSERT INTO t1 VALUES (1, 2), (3, 4);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The ORDER BY of an EXISTS subquery makes no difference and is dropped. A
-- window function in it must be dropped with it, not left for the code
-- generator to find.
g.test_window_in_dropped_order_by = function()
    g.server:exec(function()
        local sql = [[SELECT EXISTS
                      (SELECT a FROM t1 ORDER BY sum(a) OVER ());]]
        t.assert_equals(box.execute(sql).rows, {{true}})

        sql = [[SELECT a FROM t1 WHERE EXISTS
                (SELECT a FROM t1 ORDER BY sum(a) OVER (ORDER BY b));]]
        t.assert_equals(box.execute(sql).rows, {{1}, {3}})
    end)
end

-- A window function in the result list of such a subquery is still coded.
g.test_window_in_result_list = function()
    g.server:exec(function()
        local sql = [[SELECT EXISTS (SELECT sum(a) OVER () FROM t1
                                     ORDER BY sum(a) OVER ());]]
        t.assert_equals(box.execute(sql).rows, {{true}})
    end)
end
