#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(22)

test:execsql([[
    DROP TABLE IF EXISTS over;
    CREATE TABLE over(x INT PRIMARY KEY, over INT);
    DROP TABLE IF EXISTS "window";
    CREATE TABLE window(x INT PRIMARY KEY, window INT);
    INSERT INTO over VALUES(1, 2), (3, 4), (5, 6);
    INSERT INTO window VALUES(1, 2), (3, 4), (5, 6);
]])

test:do_execsql_test("5.0", [[ SELECT sum(x) over FROM over ]], { 9 })

test:do_execsql_test("5.1", [[ SELECT sum(x) over  over FROM over WINDOW over AS () ]], { 9, 9, 9 })

test:do_execsql_test(
    "5.2",
    [[
SELECT sum(over) over  over  over FROM over  over WINDOW over AS (ORDER BY over)
    ]],
    {
        2,
        6,
        12,
    }
)

test:do_execsql_test(
    "5.3",
    [[
SELECT sum(over) over  over  over FROM over  over WINDOW over AS (ORDER BY over);
    ]],
    {
        2,
        6,
        12,
    }
)

test:do_execsql_test(
    "5.4",
    [[
SELECT sum(window) OVER window  window FROM window  window  window  window AS (ORDER BY window);
    ]],
    {
        2,
        6,
        12,
    }
)

test:do_execsql_test(
    "5.5",
    [[
SELECT count(*) OVER win FROM over
WINDOW win AS (ORDER BY x ROWS BETWEEN +2 FOLLOWING AND +3 FOLLOWING)
    ]],
    {
        1,
        0,
        0,
    }
)

test:do_execsql_test(
    "8.0",
    [[
CREATE TABLE IF NOT EXISTS "sample" (
      "id" INTEGER NOT NULL PRIMARY KEY,
      "counter" INTEGER NOT NULL,
      "value" DOUBLE NOT NULL
);
INSERT INTO "sample" ("id", "counter", "value")
VALUES (1, 1, 10.), (2, 1, 20.), (3, 2, 1.), (4, 2, 3.), (5, 3, 100.);
    ]],
    {}
)

test:do_execsql_test(
    "8.1",
    [[
SELECT "counter", "value", row_number() OVER w AS row_number
FROM "sample"
WINDOW w AS (PARTITION BY "counter" ORDER BY "value" DESC)
ORDER BY "counter", row_number() OVER w
    ]],
    {
        1, 20.0, 1,
        1, 10.0, 2,
        2, 3.0, 1,
        2, 1.0, 2,
        3, 100.0, 1,
    }
)

test:do_catchsql_test(
    "9.0",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT x, group_concat(cast (x as text)) OVER (ORDER BY x ROWS 2 PRECEDING)
FROM c;
    ]],
    { 0, {
        1, "1",
        2, "1,2",
        3, "1,2,3",
        4, "2,3,4",
        5, "3,4,5",
    }}
)

test:do_catchsql_test(
    "9.0.1",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT x, group_concat(cast (x as text), NULL) OVER (ORDER BY x ROWS 2 PRECEDING)
FROM c;
    ]],
    { 0, {
        1, "1",
        2, "12",
        3, "123",
        4, "234",
        5, "345",
    }}
)

test:do_catchsql_test(
    "9.1",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT x, group_concat(x) OVER (ORDER BY x RANGE 2 PRECEDING)
FROM c;
    ]],
    { 1, "RANGE must use only UNBOUNDED or CURRENT ROW" }
)

test:do_catchsql_test(
    "9.2",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT x, group_concat(x) OVER (ORDER BY x RANGE BETWEEN UNBOUNDED PRECEDING AND 2 FOLLOWING)
FROM c;
    ]],
    { 1, "RANGE must use only UNBOUNDED or CURRENT ROW" }
)

test:do_catchsql_test(
    "9.3",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count(DISTINCT x) OVER (ORDER BY x) FROM c;
    ]],
    { 1, "DISTINCT is not supported for window functions" }
)

test:do_catchsql_test(
    "9.4",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (ORDER BY x RANGE UNBOUNDED FOLLOWING) FROM c;
    ]],
    { 1, "Syntax error at line 2 near 'FOLLOWING'" }
)

test:do_catchsql_test(
    "9.5",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (ORDER BY x RANGE BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING) FROM c;
    ]],
    { 1, "Syntax error at line 2 near 'FOLLOWING'" }
)

test:do_catchsql_test(
    "9.6",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (ORDER BY x RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED PRECEDING) FROM c;
    ]],
    { 1, "Syntax error at line 2 near 'PRECEDING'" }
)

for i, frame_bound in ipairs({
    "BETWEEN CURRENT ROW AND 4 PRECEDING",
    "4 FOLLOWING",
    "BETWEEN 4 FOLLOWING AND CURRENT ROW",
    "BETWEEN 4 FOLLOWING AND 2 PRECEDING",
}) do
    test:do_catchsql_test(
        "9.6." .. i,
        string.format([[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (
    ORDER BY x ROWS %s
) FROM c;
        ]], frame_bound),
        { 1, "unsupported window-frame type" }
    )
end

test:do_catchsql_test(
    "9.8.1",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (
  ORDER BY x ROWS BETWEEN a PRECEDING AND 2 FOLLOWING
) FROM c;
    ]],
    { 1, "frame starting offset must be a non-negative integer" }
)

test:do_catchsql_test(
    "9.8.2",
    [[
WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<5)
SELECT count() OVER (
  ORDER BY x ROWS BETWEEN 2 PRECEDING AND a FOLLOWING
) FROM c;
    ]],
    { 1, "frame ending offset must be a non-negative integer" }
)

test:finish_test()
