#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(3)

test:do_execsql_test(
    "1.0",
    [[
CREATE TABLE t1(a int primary key, b text);
INSERT INTO t1 VALUES(4, 'a');
INSERT INTO t1 VALUES(6, 'b');
INSERT INTO t1 VALUES(1, 'c');
INSERT INTO t1 VALUES(5, 'd');
INSERT INTO t1 VALUES(2, 'e');
INSERT INTO t1 VALUES(3, 'f');
    ]],
    {}
)

test:do_execsql_test(
    "3.0",
    [[
SELECT sum(a) OVER (ORDER BY b ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
FROM t1;
    ]],
    { 4, 10, 7, 6, 7, 5 }
)

test:do_execsql_test(
    "3.1",
    [[
SELECT sum(a) FROM t1;
    ]],
    { 21 }
)

test:finish_test()
