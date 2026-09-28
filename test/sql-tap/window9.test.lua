#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(2)

-- Tests 8.2 to 8.4 of the upstream file use a scalar subquery that returns
-- two rows, which is an error here, rather than its first row.
test:execsql([[
    CREATE TABLE t1(id INT PRIMARY KEY AUTOINCREMENT, a INT, b INT);
    INSERT INTO t1(a, b) VALUES(1, 2), (3, 4);
]])

-- An aggregate as the argument of a window function in a query without
-- GROUP BY is computed over the whole table.
test:do_execsql_test(
    "window9-8.1.1",
    [[
        SELECT min( sum(a) ) OVER () FROM t1;
    ]], {
        4
    })

test:do_execsql_test(
    "window9-8.1.2",
    [[
        SELECT min( sum(a) ) OVER () FROM t1 GROUP BY a;
    ]], {
        1, 1
    })

test:finish_test()
