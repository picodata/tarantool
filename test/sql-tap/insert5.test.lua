#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(4)

test:execsql([[
    CREATE TABLE main(id INTEGER PRIMARY KEY, id1 INTEGER);
    CREATE TABLE b(id INTEGER PRIMARY KEY, id1 INTEGER);
    CREATE VIEW v2 AS SELECT * FROM main;
    INSERT INTO main(id, id1) VALUES(2, 3);
]])

-- The GROUP BY of a subquery may refer to a column of the outer query.
test:do_catchsql_test(
    "insert5-2.9",
    [[
        INSERT INTO b
        SELECT * FROM main
        WHERE id > 10 AND (SELECT count(*) FROM v2 GROUP BY main.id) > 0;
    ]], {
        0
    })

-- The ORDER BY of a subquery may refer to a column of the outer query.
test:do_execsql_test(
    "insert5-2.10",
    [[
        CREATE TABLE t1(id INT PRIMARY KEY, a INT);
        INSERT INTO t1 VALUES(1, 2);
        CREATE TABLE t2(id INT PRIMARY KEY, c INT, d INT);
        INSERT INTO t2 VALUES(1, 3, 4), (2, 10, NULL);
        SELECT (SELECT c FROM t2 ORDER BY coalesce(d, a) LIMIT 1) FROM t1;
    ]], {
        10
    })

-- The subquery is evaluated again for each row of the outer query.
test:do_execsql_test(
    "insert5-2.11",
    [[
        INSERT INTO t1 VALUES(2, 5);
        SELECT (SELECT c FROM t2 ORDER BY coalesce(d, a) LIMIT 1)
        FROM t1 ORDER BY id;
    ]], {
        10, 3
    })

-- So is a subquery grouped by a column of the outer query.
test:do_execsql_test(
    "insert5-2.12",
    [[
        SELECT (SELECT c FROM t2 GROUP BY c ORDER BY c * a DESC LIMIT 1)
        FROM t1 ORDER BY id;
    ]], {
        10, 10
    })

test:finish_test()
