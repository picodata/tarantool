#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(3)

test:execsql([[
    DROP TABLE IF EXISTS t1;
    CREATE TABLE t1(a INT PRIMARY KEY, b INT);
    INSERT INTO t1 VALUES(1, 2);
    INSERT INTO t1 VALUES(3, 4);
]])

-- PG says ERROR:  aggregate function calls cannot contain window function calls
test:do_catchsql_test(
    "windowerr-2.1",
    [[
        SELECT sum( sum(a) OVER () ) FROM t1;
    ]], {
        1, "misuse of window function SUM()"
    })

-- PG says ERROR:  column "xyz" does not exist
test:do_catchsql_test(
    "windowerr-2.2",
    [[
        SELECT sum(a) OVER () AS xyz FROM t1 ORDER BY sum(xyz);
    ]], {
        1, "misuse of aliased window function XYZ"
    })

-- An alias of a window function may still be used as a whole.
test:do_execsql_test(
    "windowerr-2.3",
    [[
        SELECT sum(a) OVER () AS xyz FROM t1 ORDER BY xyz;
    ]], {
        4, 4
    })

test:finish_test()
