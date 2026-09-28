local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'aggregate-owner'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t1(a INT PRIMARY KEY);]])
        box.execute([[CREATE TABLE t2(x INT PRIMARY KEY);]])
        box.execute([[INSERT INTO t1 VALUES (1), (2);]])
        box.execute([[INSERT INTO t2 VALUES (10), (20);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- An aggregate belongs to the query of the columns its argument refers to,
-- even when they are referred to from a subquery in the argument. Here "a"
-- is a column of the outer query, so sum() adds up over its rows, as in
-- PostgreSQL.
g.test_outer_column_in_subquery_of_argument = function()
    g.server:exec(function()
        local sql = [[SELECT (SELECT sum((SELECT x FROM t2 WHERE x = 10 * a)))
                      FROM t1;]]
        t.assert_equals(box.execute(sql).rows, {{30}})
    end)
end

-- The columns of the subquery in the argument do not count, so an aggregate
-- whose argument refers to nothing else belongs to its own query.
g.test_own_columns_of_subquery_in_argument = function()
    g.server:exec(function()
        local sql = [[SELECT (SELECT sum((SELECT max(x) FROM t2)) FROM t2 AS u)
                      FROM t1;]]
        t.assert_equals(box.execute(sql).rows, {{40}, {40}})

        sql = [[SELECT sum((SELECT count(*) FROM t2)) FROM t1;]]
        t.assert_equals(box.execute(sql).rows, {{4}})
    end)
end
