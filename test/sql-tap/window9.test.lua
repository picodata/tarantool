#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(5)

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

-- A built-in function over a column of a subquery or a CTE takes the type
-- of the column, so the buffer of the window gets a matching field type.
test:do_execsql_test(
    "window9-9.1",
    [[
        SELECT SUM("y") OVER (), AVG("x") FROM (SELECT 3 AS "x", 5 AS "y");
    ]], {
        5, 3
    })

test:do_execsql_test(
    "window9-9.2",
    [[
        SELECT SUM("y") OVER (), AVG("x") FROM (SELECT 1.5e0 AS "x", 5 AS "y");
    ]], {
        5, 1.5
    })

test:do_execsql_test(
    "window9-9.3",
    [[
        WITH
            "foo" ( "COL_0", "COL_1", "COL_2" ) AS (
                SELECT 1, 2, 3
            ),
            "bar" ( "COL_0", "COL_1", "COL_2" ) AS (
                SELECT 3, 4, 5
            )
        SELECT "COL_0", "COL_1", "COL_2"
            FROM "foo"
        EXCEPT
        SELECT SUM("COL_2") OVER () AS "col_1",
               "COL_1" AS "c1",
               AVG("COL_0") AS "c2"
            FROM "bar";
    ]], {
        1, 2, 3
    })

test:finish_test()
