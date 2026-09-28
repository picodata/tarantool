#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(2)

-- Test 6.1 of the upstream file uses FILTER on an aggregate without OVER,
-- which is not supported.
test:execsql([[
    CREATE TABLE t1(id INT PRIMARY KEY, a INT, b INT);
    INSERT INTO t1 VALUES(1, 1, 1);
    INSERT INTO t1 VALUES(2, 2, 2);
    CREATE TABLE t2(id INT PRIMARY KEY, x INT, y INT);
    INSERT INTO t2 VALUES(1, 1, 1);
]])

-- An aggregate that refers to both queries belongs to the inner one.
test:do_execsql_test(
    "filter1-6.2",
    [[
        SELECT (SELECT COUNT(a+x) FROM t2) FROM t1;
    ]], {
        1, 1
    })

-- An aggregate that refers only to the outer query belongs to it.
test:do_execsql_test(
    "filter1-6.3",
    [[
        SELECT (SELECT COUNT(a) FROM t2) FROM t1;
    ]], {
        2
    })

test:finish_test()
