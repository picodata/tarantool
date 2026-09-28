#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(6)

test:do_execsql_test(
    "view2-1.0",
    [[
        CREATE TABLE t1(x INT PRIMARY KEY, y INT);
        INSERT INTO t1 VALUES(1, 2);
        CREATE VIEW v1 AS SELECT * FROM (
          WITH x1 AS (SELECT y, x FROM t1)
          SELECT * FROM x1
        );
    ]], {
        -- <view2-1.0>
        -- </view2-1.0>
    })

test:do_execsql_test(
    "view2-1.1",
    [[
        SELECT * FROM v1
    ]], {
        -- <view2-1.1>
        2, 1
        -- </view2-1.1>
    })

-- The names in a view do not refer to the CTEs of the statement using it.
-- Upstream view2-1.2 uses the schema name "main", which Tarantool does
-- not have.
test:do_execsql_test(
    "view2-1.3",
    [[
        CREATE VIEW v2 AS SELECT * FROM t1;
        WITH t1(a, b) AS ( SELECT 3, 4 ) SELECT * FROM v2;
    ]], {
        -- <view2-1.3>
        1, 2
        -- </view2-1.3>
    })

-- The same for a compound view.
test:do_execsql_test(
    "view2-1.4",
    [[
        CREATE VIEW v4 AS SELECT x FROM t1 UNION ALL SELECT y FROM t1;
        WITH t1(a, b) AS ( SELECT 3, 4 ) SELECT * FROM v4;
    ]], {
        -- <view2-1.4>
        1, 2
        -- </view2-1.4>
    })

-- A view with a WITH clause of its own still sees its CTEs.
test:do_execsql_test(
    "view2-1.5",
    [[
        CREATE VIEW v3 AS WITH c AS (SELECT x FROM t1) SELECT * FROM c;
        WITH t1(a, b) AS ( SELECT 3, 4 ) SELECT * FROM v3;
    ]], {
        -- <view2-1.5>
        1
        -- </view2-1.5>
    })

-- The CTEs of the statement are still visible outside of the view.
test:do_execsql_test(
    "view2-1.6",
    [[
        WITH t1(a, b) AS ( SELECT 3, 4 ) SELECT * FROM v2, t1;
    ]], {
        -- <view2-1.6>
        1, 2, 3, 4
        -- </view2-1.6>
    })

test:finish_test()
