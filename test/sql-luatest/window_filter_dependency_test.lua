local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'window-filter-dependency'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t1(t1_id INTEGER PRIMARY KEY);]])
        box.execute([[CREATE TABLE t2(t2_id INTEGER PRIMARY KEY);]])
        box.execute([[CREATE TABLE t3(t3_id INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO t1 VALUES (1), (3), (5);]])
        box.execute([[INSERT INTO t2 VALUES (3), (5);]])
        box.execute([[INSERT INTO t3 VALUES (10), (11), (12);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- An IN subquery that refers to the outer query only from the FILTER of a
-- window function depends on the outer table. So it is not evaluated in the
-- loop over t2, where t1_id = t2_id would allow it, before t1 is open.
g.test_outer_column_in_window_filter = function()
    g.server:exec(function()
        local sql = [[SELECT t1.* FROM t1, t2 WHERE t1_id = t2_id AND
                      t1_id IN (SELECT count(*) FILTER (WHERE t1_id = 3)
                                OVER () FROM t3);]]
        t.assert_equals(box.execute(sql).rows, {{3}})
    end)
end
