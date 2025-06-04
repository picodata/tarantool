#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(5)

test:execsql( [[
DROP TABLE IF EXISTS "TMP_3781021201_1136";
CREATE TABLE "TMP_3781021201_1136"(
    "COL_0" int, "COL_1" int, "COL_2" int,
    "COL_3" int, "COL_4" int, "COL_5" int,
    "COL_6" int, "COL_7" int, "COL_8" int,
    "COL_9" int, "COL_10" int, "COL_11" int,
    "COL_12" int, "COL_13" int, "COL_14" int,
    "COL_15" int, "COL_16" int, "COL_17" int,
    "COL_18" int, "COL_19" int, "COL_20" int,
    "COL_21" int, "COL_22" int, "COL_23" int,
    "COL_24" int, "COL_25" int, "COL_26" int,
    "COL_27" int, "COL_28" int, "COL_29" int primary key
);
]])

test:do_execsql_test(
    "heap after free",
    [[
SELECT
  "COL_28" as "client_mdm_id_first",
  "COL_23" as "key_join",
  "COL_24" as "flag",
  "COL_25" as "begindate",
  "COL_26" as "enddate",
  "COL_1" as "customer_account_no",
  "COL_0" as "customer_account_sk",
  CASE
    WHEN ("COL_11") = (?) and ("COL_15") <> (?)
    THEN "COL_15" ELSE CAST (? as double)
  END as "flag_sk",
  row_number () OVER (
    PARTITION BY "COL_23",
    "COL_1" ORDER BY "COL_11" DESC,
    "COL_18" DESC,
    "COL_15",
    "COL_0" DESC,
    "COL_20" DESC
  ) as "flag_a"
FROM (
  SELECT
    "COL_0",
    "COL_1",
    "COL_2",
    "COL_3",
    "COL_4",
    "COL_5",
    "COL_6",
    "COL_7",
    "COL_8",
    "COL_9",
    "COL_10",
    "COL_11",
    "COL_12",
    "COL_13",
    "COL_14",
    "COL_15",
    "COL_16",
    "COL_17",
    "COL_18",
    "COL_19",
    "COL_20",
    "COL_21",
    "COL_22",
    "COL_23",
    "COL_24",
    "COL_25",
    "COL_26",
    "COL_27",
    "COL_28"
  FROM "TMP_3781021201_1136"
)
    ]], {})

test:execsql( [[
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(x INT PRIMARY KEY, y INT);
INSERT INTO t1 VALUES (1, 1), (2, 2);
]])

test:do_execsql_test(
    "window walker",
    [[
SELECT
    row_number() OVER win1,
    sum(y) OVER win2,
    max(x) OVER win3
FROM t1
WINDOW
    win1 AS (ORDER BY x + (SELECT 1)),
    win2 AS (PARTITION BY x + (SELECT 2)),
    win3 AS (ORDER BY x + (
        SELECT count(*) OVER win_nested
        FROM (SELECT 3)
        WINDOW win_nested AS (
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        )
    ))
    ]], {1,1,1,2,2,2})

test:execsql( [[
DROP TABLE IF EXISTS t;
CREATE TABLE t(a INT PRIMARY KEY, b TEXT);
INSERT INTO t VALUES (1, 'kek');
]])

test:do_execsql_test(
    "row_number is not deterministic",
    [[
SELECT row_number () OVER () + (CAST(1 AS unsigned)) as "col_1"
FROM (SELECT a, b FROM t);
    ]], {2})

test:execsql( [[
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a TEXT PRIMARY KEY, b DATETIME, c UUID, d VARBINARY);
INSERT INTO t3 VALUES
('hello', CAST('2000-01-30' AS DATETIME), CAST('4268f6ad-5f15-4e15-9118-f81c6e227417' AS UUID), x'FF'),
('world', CAST('2000-12-01' AS DATETIME), CAST('4268f6ad-5f15-4e15-9118-f81c6e227418' AS UUID), x'AA');
]])

test:do_execsql_test(
    "last_value with tarantool types",
    [[
SELECT
last_value(a) OVER w = 'world',
last_value(b) OVER w = CAST('2000-12-01' AS DATETIME),
last_value(c) OVER w = CAST('4268f6ad-5f15-4e15-9118-f81c6e227418' AS UUID),
last_value(d) OVER w = x'AA'
FROM t3 WINDOW w AS ();
    ]], { true, true, true, true, true, true, true, true })

test:execsql( [[
DROP TABLE IF EXISTS t0;
CREATE TABLE t0(x INTEGER PRIMARY KEY, y TEXT);
INSERT INTO t0 VALUES (1, 'aaa'), (2, 'aaa'), (3, 'bbb');
]])

test:do_execsql_test(
    "last_value with allocation",
    [[
SELECT x, y, last_value(y) OVER (ORDER BY y) FROM t0 ORDER BY x;
    ]], { 1, 'aaa', 'aaa', 2, 'aaa', 'aaa', 3, 'bbb', 'bbb' })

test:finish_test()
