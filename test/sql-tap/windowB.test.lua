#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(3)

test:execsql([[
    CREATE TABLE x(a INT PRIMARY KEY);
    INSERT INTO x VALUES(1);
    INSERT INTO x VALUES(2);
]])

-- A window of a CTE based on a named window keeps its PARTITION BY.
test:do_execsql_test(
    "windowB-4.1",
    [[
        WITH y AS (
            SELECT row_number() OVER (win) FROM x
            WINDOW win AS (PARTITION BY a)
        )
        SELECT * FROM y;
    ]], {
        1, 1
    })

-- The names of the named window are resolved too.
test:do_catchsql_test(
    "windowB-4.2",
    [[
        WITH y AS (
            SELECT row_number() OVER (win) FROM x
            WINDOW win AS (PARTITION BY fake_column)
        )
        SELECT * FROM y;
    ]], {
        1, "Can’t resolve field 'FAKE_COLUMN'"
    })

-- A named window that is never used is not resolved.
test:do_catchsql_test(
    "windowB-4.3",
    [[
        SELECT 1 WINDOW win AS (PARTITION BY fake_column);
    ]], {
        0, {1}
    })

test:finish_test()
