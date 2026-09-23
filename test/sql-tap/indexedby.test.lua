#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(9)

-- Ported from indexedby.test of SQLite, the cases 13.x only (check-in
-- 1eca07ed73, bug 2026-09-10T20:38:13Z): INDEXED BY and NOT INDEXED of a
-- FROM clause item stay in force when the item is in parentheses. The
-- tables have a primary key of their own.
test:do_execsql_test(
    "13.1",
    [[
        CREATE TABLE t1(id INT PRIMARY KEY, a INT, b INT, c INT);
        CREATE INDEX t1a ON t1(a);
        CREATE INDEX t1b ON t1(b);
        INSERT INTO t1 VALUES(1,1,2,3),(2,4,1,6),(3,7,8,9);
        CREATE TABLE t0(x INT PRIMARY KEY);
        INSERT INTO t0 VALUES(0);
        CREATE TABLE t2(y INT PRIMARY KEY);
        INSERT INTO t2 VALUES(99);
    ]], {
        -- <13.1>
        -- </13.1>
    })

test:do_eqp_test(
    "13.2",
    [[
        SELECT c FROM t0 JOIN (t1 INDEXED BY t1a) ON true;
    ]], {
        -- <13.2>
        {0, 0, 1, "SCAN TABLE T1 USING COVERING INDEX T1A (~1048576 rows)"},
        {0, 1, 0, "SCAN TABLE T0 (~1048576 rows)"},
        -- </13.2>
    })

test:do_eqp_test(
    "13.3",
    [[
        SELECT c FROM t0 JOIN (t1 INDEXED BY t1b) ON true;
    ]], {
        -- <13.3>
        {0, 0, 1, "SCAN TABLE T1 USING COVERING INDEX T1B (~1048576 rows)"},
        {0, 1, 0, "SCAN TABLE T0 (~1048576 rows)"},
        -- </13.3>
    })

-- NOT INDEXED only rules out an automatic index: the indexes of a space are
-- used all the same, just as those of a WITHOUT ROWID table in SQLite, which
-- leaves only the rowid to a table that has one. So t1a is used, unlike in
-- the SQLite test, whose t1 has a rowid.
test:do_eqp_test(
    "13.4",
    [[
        SELECT c FROM t0 CROSS JOIN (t1 NOT INDEXED) ON a=x;
    ]], {
        -- <13.4>
        {0, 0, 0, "SCAN TABLE T0 (~1048576 rows)"},
        {0, 1, 1, "SEARCH TABLE T1 USING COVERING INDEX T1A (A=?) (~10 rows)"},
        -- </13.4>
    })

test:do_catchsql_test(
    "13.5",
    [[
        SELECT c FROM t0 JOIN (t1 INDEXED BY t1x) ON true;
    ]], {
        -- <13.5>
        1, "No index 'T1X' is defined in space 'T1'"
        -- </13.5>
    })

test:do_eqp_test(
    "13.12",
    [[
        SELECT t1.c FROM t0 JOIN (t1 INDEXED BY t1a JOIN t2 ON true) ON true;
    ]], {
        -- <13.12>
        {0, 0, 1, "SCAN TABLE T1 USING COVERING INDEX T1A (~1048576 rows)"},
        {0, 1, 0, "SCAN TABLE T0 (~1048576 rows)"},
        {0, 2, 2, "SCAN TABLE T2 (~1048576 rows)"},
        -- </13.12>
    })

test:do_eqp_test(
    "13.13",
    [[
        SELECT t1.c FROM t0 JOIN (t1 INDEXED BY t1b JOIN t2 ON true) ON true;
    ]], {
        -- <13.13>
        {0, 0, 1, "SCAN TABLE T1 USING COVERING INDEX T1B (~1048576 rows)"},
        {0, 1, 0, "SCAN TABLE T0 (~1048576 rows)"},
        {0, 2, 2, "SCAN TABLE T2 (~1048576 rows)"},
        -- </13.13>
    })

-- As in 13.4, t1a is used all the same.
test:do_eqp_test(
    "13.14",
    [[
        SELECT t1.c FROM t0 CROSS JOIN (t1 NOT INDEXED JOIN t2 ON true) ON a=x;
    ]], {
        -- <13.14>
        {0, 0, 0, "SCAN TABLE T0 (~1048576 rows)"},
        {0, 1, 1, "SEARCH TABLE T1 USING COVERING INDEX T1A (A=?) (~10 rows)"},
        {0, 2, 2, "SCAN TABLE T2 (~1048576 rows)"},
        -- </13.14>
    })

test:do_catchsql_test(
    "13.15",
    [[
        SELECT t1.c FROM t0 JOIN (t1 INDEXED BY t1x JOIN t2 ON true) ON true;
    ]], {
        -- <13.15>
        1, "No index 'T1X' is defined in space 'T1'"
        -- </13.15>
    })

test:finish_test()
