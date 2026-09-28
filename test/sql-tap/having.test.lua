#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(1)

test:execsql([[
    CREATE TABLE t1(id INT PRIMARY KEY, a TEXT, b TEXT);
    CREATE TABLE t2(id INT PRIMARY KEY, x INT, y INT);
    INSERT INTO t1 VALUES(1, 'a', 'b');
]])

-- The WHERE clause (a = '2') uses an aggregate column from the outer
-- query, and the HAVING clause is always false. The outer aggregate must
-- not be disturbed by it.
test:do_execsql_test(
    "having-5.1",
    [[
        SELECT min(b), (
            SELECT x FROM t2 WHERE a = '2' GROUP BY y HAVING false
        ) FROM t1;
    ]], {
        "b", ""
    })

test:finish_test()
