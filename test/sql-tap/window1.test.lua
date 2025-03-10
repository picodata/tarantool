#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(84)

test:execsql( [[
    DROP TABLE IF EXISTS t1;
    CREATE TABLE t1(a INT PRIMARY KEY, b INT, c INT, d INT);
    INSERT INTO t1 VALUES(1, 2, 3, 4);
    INSERT INTO t1 VALUES(5, 6, 7, 8);
    INSERT INTO t1 VALUES(9, 10, 11, 12);
]])

test:do_execsql_test(
    "window1-1.1",
    [[
        SELECT sum(b) OVER () FROM t1;
    ]],
    { 18, 18, 18 })

test:do_execsql_test(
    "window1-1.2",
    [[
        SELECT a, sum(b) OVER () FROM t1;
    ]],
    { 1, 18, 5, 18, 9, 18 })

test:do_execsql_test(
    "window1-1.3",
    [[
        SELECT a, 4 + sum(b) OVER () FROM t1;
    ]],
    { 1, 22, 5, 22, 9, 22 })

test:do_execsql_test(
    "window1-1.4",
    [[
        SELECT a + 4 + sum(b) OVER () FROM t1;
    ]],
    { 23, 27, 31 })

test:do_execsql_test(
    "window1-1.5",
    [[
        SELECT a, sum(b) OVER (PARTITION BY c) FROM t1
    ]],
    { 1, 2, 5, 6, 9, 10 })

test:do_execsql_test(
    "window1-1.6",
    [[
        SELECT sum(b) OVER () FROM (SELECT * FROM t1);
    ]],
    { 18, 18, 18 })

test:do_execsql_test(
    "window1-TK_LINEFEED-compatibility",
    [[
        SELECT
        sum
        (b)
        OVER
        ()
        FROM
        t1;
    ]],
    { 18, 18, 18 })

test:do_execsql_test(
    "window1-2.1",
    [[
        SELECT sum(b) OVER (PARTITION BY c) FROM t1;
    ]],
    { 2, 6, 10 })

test:do_execsql_test(
    "window1-2.2",
    [[
        SELECT sum(b) OVER (ORDER BY c) FROM t1;
    ]],
    { 2, 8, 18 })

test:do_execsql_test(
    "window1-2.3",
    [[
        SELECT sum(b) OVER (PARTITION BY d ORDER BY c) FROM t1;
    ]],
    { 2, 6, 10 })

test:do_execsql_test(
    "window1-2.4",
    [[
        SELECT sum(b) FILTER (WHERE a>0) OVER (PARTITION BY d ORDER BY c)
        FROM t1;
    ]],
    { 2, 6, 10 })

test:do_execsql_test(
    "window1-2.5",
    [[
        SELECT sum(b) OVER (ORDER BY c RANGE UNBOUNDED PRECEDING) FROM t1;
    ]],
    { 2, 8, 18 })

test:do_execsql_test(
    "window1-2.6",
    [[
        SELECT sum(b) OVER (ORDER BY c ROWS 45 PRECEDING) FROM t1;
    ]],
    { 2, 8, 18 })

test:do_execsql_test(
    "window1-2.7",
    [[
        SELECT sum(b) OVER (ORDER BY c RANGE CURRENT ROW) FROM t1;
    ]],
    { 2, 6, 10 })

test:do_execsql_test(
    "window1-2.8",
    [[
        SELECT sum(b) OVER (ORDER BY c RANGE BETWEEN UNBOUNDED PRECEDING
        AND CURRENT ROW) FROM t1;
    ]],
    { 2, 8, 18 })

test:do_execsql_test(
    "window1-2.9",
    [[
        SELECT sum(b) OVER (ORDER BY c ROWS BETWEEN UNBOUNDED PRECEDING
        AND UNBOUNDED FOLLOWING) FROM t1;
    ]],
    { 18, 18, 18 })

test:do_catchsql_test(
    "window1-3.1",
    [[
        SELECT * FROM t1 WHERE sum(b) OVER ();
    ]],
    {1, "misuse of window function SUM()"})

test:do_catchsql_test(
    "window1-3.2",
    [[
        SELECT * FROM t1 GROUP BY sum(b) OVER ();
    ]],
    {1, "misuse of window function SUM()"})

test:do_catchsql_test(
    "window1-3.3",
    [[
        SELECT * FROM t1 GROUP BY a HAVING sum(b) OVER ();
    ]],
    {1, "misuse of window function SUM()"})

test:execsql( [[
    DROP TABLE IF EXISTS t2;
    CREATE TABLE t2(a INT PRIMARY KEY, b INT, c INT);
    INSERT INTO t2 VALUES(0, 0, 0);
    INSERT INTO t2 VALUES(1, 1, 1);
    INSERT INTO t2 VALUES(2, 0, 2);
    INSERT INTO t2 VALUES(3, 1, 0);
    INSERT INTO t2 VALUES(4, 0, 1);
    INSERT INTO t2 VALUES(5, 1, 2);
    INSERT INTO t2 VALUES(6, 0, 0);
]])

test:do_execsql_test(
    "window1-4.1",
    [[
        SELECT a, sum(a) OVER (PARTITION BY b) FROM t2;
    ]],
    { 0, 12, 2, 12, 4, 12, 6, 12, 1, 9, 3, 9, 5, 9 })

test:do_execsql_test(
    "window1-4.2",
    [[
        SELECT a, sum(a) OVER (PARTITION BY b) FROM t2 ORDER BY a;
    ]],
    { 0, 12, 1, 9, 2, 12, 3, 9, 4, 12, 5, 9, 6, 12 })

test:do_execsql_test(
    "window1-4.3",
    [[
        SELECT a, sum(a) OVER () FROM t2 ORDER BY a;
    ]],
    { 0, 21, 1, 21, 2, 21, 3, 21, 4, 21, 5, 21, 6, 21 })

test:do_execsql_test(
    "window1-4.4",
    [[
        SELECT a, sum(a) OVER (ORDER BY a) FROM t2;
    ]],
    { 0, 0, 1, 1, 2, 3, 3, 6, 4, 10, 5, 15, 6, 21 })

test:do_execsql_test(
    "window1-4.5",
    [[
        SELECT a, sum(a) OVER (PARTITION BY b ORDER BY a) FROM t2 ORDER BY a;
    ]],
    { 0, 0, 1, 1, 2, 2, 3, 4, 4, 6, 5, 9, 6, 12 })

test:do_execsql_test(
    "window1-4.6",
    [[
        SELECT a, sum(a) OVER (PARTITION BY c ORDER BY a) FROM t2 ORDER BY a;
    ]],
    { 0, 0, 1, 1, 2, 2, 3, 3, 4, 5, 5, 7, 6, 9 })

test:do_execsql_test(
    "window1-4.7",
    [[
        SELECT a, sum(a) OVER (PARTITION BY b ORDER BY a DESC) FROM t2
        ORDER BY a;
    ]],
    { 0, 12, 1, 9, 2, 12, 3, 8, 4, 10, 5, 5, 6, 6 })

-- FIXME: This test returns wrong result in tarantool,
--        and crashes in sqlite3 (commit 9592320).
test:do_execsql_test(
    "window1-4.8",
    [[
        SELECT a,
            sum(a) OVER (PARTITION BY b ORDER BY a DESC),
            sum(a) OVER (PARTITION BY c ORDER BY a)
        FROM t2 ORDER BY a
    ]], {
        0, 12, 0,
        1, 9, 1,
        2, 12, 2,
        3, 8, 3,
        4, 10, 5,
        5, 5, 7,
        6, 6, 9
    })

test:do_execsql_test(
    "window1-4.9",
    [[
        SELECT a,
            sum(a) OVER (ORDER BY a),
            avg(cast(a as double)) OVER (ORDER BY a)
        FROM t2 ORDER BY a;
    ]], {
        0, 0, 0.0,
        1, 1, 0.5,
        2, 3, 1.0,
        3, 6, 1.5,
        4, 10, 2.0,
        5, 15, 2.5,
        6, 21, 3.0
    })

test:do_execsql_test(
    "window1-4.10.1",
    [[
        SELECT a,
            count() OVER (ORDER BY a DESC),
            group_concat(cast(a as text), '.') OVER (ORDER BY a DESC)
        FROM t2 ORDER BY a DESC;
    ]], {
        6, 1, '6',
        5, 2, '6.5',
        4, 3, '6.5.4',
        3, 4, '6.5.4.3',
        2, 5, '6.5.4.3.2',
        1, 6, '6.5.4.3.2.1',
        0, 7, '6.5.4.3.2.1.0'
    })

test:do_execsql_test(
    "window1-4.10.2",
    [[
        SELECT a,
            count(*) OVER (ORDER BY a DESC),
            group_concat(cast(a as text), '.') OVER (ORDER BY a DESC)
        FROM t2 ORDER BY a DESC;
    ]], {
        6, 1, '6',
        5, 2, '6.5',
        4, 3, '6.5.4',
        3, 4, '6.5.4.3',
        2, 5, '6.5.4.3.2',
        1, 6, '6.5.4.3.2.1',
        0, 7, '6.5.4.3.2.1.0'
    })

test:do_execsql_test(
    "window1-4.10.3-crash-with-subqueries",
    [[
        SELECT
            AVG(a)
            FILTER
                (WHERE a > (SELECT MIN(a) OVER () FROM t1 LIMIT 1))
            OVER ()
        FROM t2;
    ]], {
        4, 4, 4, 4, 4, 4, 4
    }
)

test:execsql( [[
    DROP TABLE IF EXISTS t1;
    CREATE TABLE t1(x INT PRIMARY KEY);
    INSERT INTO t1 VALUES(7), (6), (5), (4), (3), (2), (1);

    DROP TABLE IF EXISTS t2;
    CREATE TABLE t2(x TEXT PRIMARY KEY);
    INSERT INTO t2 VALUES('b'), ('a');
]])

test:do_execsql_test(
    "window1-6.1",
    [[
        SELECT x, count(*) OVER (ORDER BY x) FROM t1;
    ]],
    { 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 })

test:do_execsql_test(
    "window1-6.2",
    [[
        SELECT * FROM t2, (SELECT x, count(*) OVER (ORDER BY x) FROM t1);
    ]], {
        'a', 1, 1,
        'b', 1, 1,
        'a', 2, 2,
        'b', 2, 2,
        'a', 3, 3,
        'b', 3, 3,
        'a', 4, 4,
        'b', 4, 4,
        'a', 5, 5,
        'b', 5, 5,
        'a', 6, 6,
        'b', 6, 6,
        'a', 7, 7,
        'b', 7, 7
    })

test:do_catchsql_test(
    "window1-6.3",
    [[
        SELECT x, row_number() FILTER (WHERE (x%2)=0) OVER w FROM t1
        WINDOW w AS (ORDER BY x)
    ]],
    {1, "FILTER clause may only be used with aggregate window functions"})

test:execsql( [[
    DROP TABLE IF EXISTS t1;
    CREATE TABLE t1(x INT PRIMARY KEY, y INT);
    INSERT INTO t1 VALUES(1, 2);
    INSERT INTO t1 VALUES(3, 4);
    INSERT INTO t1 VALUES(5, 6);
    INSERT INTO t1 VALUES(7, 8);
    INSERT INTO t1 VALUES(9, 10);
]])

-- NOTE(gmoshkin) these tests are changed, because NTH_VALUE function is not
-- supported, instead ROW_NUMBER is used
test:do_catchsql_test(
    "window1-7.1.2",
    [[
        SELECT * FROM t1 WHERE row_number() OVER (ORDER BY y);
    ]],
    {1, "misuse of window function ROW_NUMBER()"})

test:do_catchsql_test(
    "window1-7.1.3",
    [[
        SELECT count(*) FROM t1 GROUP BY y HAVING row_number()
        OVER (ORDER BY y);
    ]],
    {1, "misuse of window function ROW_NUMBER()"})

test:do_catchsql_test(
    "window1-7.1.4",
    [[
        SELECT count(*) FROM t1 GROUP BY row_number() OVER (ORDER BY y);
    ]],
    {1, "misuse of window function ROW_NUMBER()"})

test:do_catchsql_test(
    "window1-7.1.5",
    [[
        SELECT count(*) FROM t1 LIMIT row_number() OVER ();
    ]],
    {1, "misuse of window function ROW_NUMBER()"})

test:do_catchsql_test(
    "window1-7.1.6",
    [[
        SELECT f(x) OVER (ORDER BY y) FROM t1;
    ]],
    {1, "F() may not be used as a window function"})

test:do_catchsql_test(
    "window1-7.1.7",
    [[
        SELECT max(x) OVER abc FROM t1 WINDOW def AS (ORDER BY y);
    ]],
    {1, "no such window: abc"})

-- FIXME: This test returns wrong result in tarantool,
--        sum and max columns are swapped.
test:do_execsql_test(
    "window1-7.2",
    [[
        SELECT
            row_number() OVER win,
            sum(y) OVER win,
            max(x) OVER win
        FROM t1
        WINDOW win AS (ORDER BY x)
    ]], {
        1, 2, 1,
        2, 6, 3,
        3, 12, 5,
        4, 20, 7,
        5, 30, 9
    })

test:do_execsql_test(
    "window1-7.3",
    [[
        SELECT row_number() OVER (ORDER BY x) FROM t1;
    ]],
    {1, 2, 3, 4, 5})

test:do_execsql_test(
    "window1-7.4",
    [[
        SELECT
            row_number() OVER win,
            sum(x) OVER win
        FROM t1
        WINDOW win AS (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ]], {
        1, 1,
        2, 4,
        3, 9,
        4, 16,
        5, 25
    })

test:execsql( [[
    DROP TABLE IF EXISTS t3;
    CREATE TABLE t3(a INT PRIMARY KEY, b INT, c INT);

    WITH s(i) AS (VALUES(1) UNION ALL SELECT i + 1 FROM s WHERE i < 6)
    INSERT INTO t3 SELECT i, i, i FROM s;

    DROP VIEW IF EXISTS v1;
    CREATE VIEW v1 AS SELECT
        sum(b) OVER (ORDER BY c),
        min(b) OVER (ORDER BY c),
        max(b) OVER (ORDER BY c)
    FROM t3;

    DROP VIEW IF EXISTS v2;
    CREATE VIEW v2 AS SELECT
        sum(b) OVER win,
        min(b) OVER win,
        max(b) OVER win
    FROM t3
    WINDOW win AS (ORDER BY c);
]])

test:do_execsql_test(
    "window1-8.1.1",
    [[
        SELECT * FROM v1;
    ]], {
        1, 1, 1,
        3, 1, 2,
        6, 1, 3,
        10, 1, 4,
        15, 1, 5,
        21, 1, 6
    })

test:do_execsql_test(
    "window1-8.1.2",
    [[
        SELECT * FROM v2;
    ]], {
        1, 1, 1,
        3, 1, 2,
        6, 1, 3,
        10, 1, 4,
        15, 1, 5,
        21, 1, 6
    })

test:execsql( [[
    DROP TABLE IF EXISTS t4;
    CREATE TABLE t4(x INT PRIMARY KEY, y TEXT);
    INSERT INTO t4 VALUES(1, 'g');
    INSERT INTO t4 VALUES(2, 'i');
    INSERT INTO t4 VALUES(3, 'l');
    INSERT INTO t4 VALUES(4, 'g');
    INSERT INTO t4 VALUES(5, 'a');

    DROP TABLE IF EXISTS t5;
    CREATE TABLE t5(x INT PRIMARY KEY, y TEXT, m TEXT);
    CREATE TRIGGER t4i AFTER INSERT ON t4 FOR EACH ROW BEGIN
        DELETE FROM t5;
        INSERT INTO t5
            SELECT x, y, max(y) OVER xyz FROM t4
            WINDOW xyz AS (PARTITION BY (x%2) ORDER BY x);
    END;
]])

test:do_execsql_test(
    "window1-9.1.1",
    [[
        SELECT x, y, max(y) OVER xyz FROM t4
        WINDOW xyz AS (PARTITION BY (x%2) ORDER BY x) ORDER BY 1;
    ]], {
        1, 'g', 'g',
        2, 'i', 'i',
        3, 'l', 'l',
        4, 'g', 'i',
        5, 'a', 'l'
    })

test:execsql( [[
    INSERT INTO t4 VALUES(6, 'm');
]])

test:do_execsql_test(
    "window1-9.1.2",
    [[
        SELECT x, y, max(y) OVER xyz FROM t4
            WINDOW xyz AS (PARTITION BY (x%2) ORDER BY x) ORDER BY 1;
    ]], {
        1, 'g', 'g',
        2, 'i', 'i',
        3, 'l', 'l',
        4, 'g', 'i',
        5, 'a', 'l',
        6, 'm', 'm'
    })

test:do_execsql_test(
    "window1-9.1.3",
    [[
        SELECT * FROM t5 ORDER BY 1;
    ]], {
        1, 'g', 'g',
        2, 'i', 'i',
        3, 'l', 'l',
        4, 'g', 'i',
        5, 'a', 'l',
        6, 'm', 'm'
    })

test:do_execsql_test(
    "window1-9.2",
    [[
        WITH aaa(x, y, z) AS (
            SELECT x, y, max(y) OVER xyz FROM t4
            WINDOW xyz AS (PARTITION BY (x%2) ORDER BY x)
        )
        SELECT * FROM aaa ORDER BY 1;
    ]], {
        1, 'g', 'g',
        2, 'i', 'i',
        3, 'l', 'l',
        4, 'g', 'i',
        5, 'a', 'l',
        6, 'm', 'm'
    })

test:do_execsql_test(
    "window1-9.3",
    [[
        WITH aaa(x, y, z) AS (
            SELECT x, y, max(y) OVER xyz FROM t4
            WINDOW xyz AS (ORDER BY x)
        )
        SELECT *, min(z) OVER (ORDER BY x) FROM aaa ORDER BY 1;
    ]], {
        1, 'g', 'g', 'g',
        2, 'i', 'i', 'g',
        3, 'l', 'l', 'g',
        4, 'g', 'l', 'g',
        5, 'a', 'l', 'g',
        6, 'm', 'm', 'g'
    })

test:execsql( [[
    DROP TABLE IF EXISTS sales;
    CREATE TABLE sales(emp TEXT PRIMARY KEY, region TEXT, total INT);
    INSERT INTO sales VALUES
        ('Alice',     'North', 34),
        ('Frank',     'South', 22),
        ('Charles',   'North', 45),
        ('Darrell',   'South', 8),
        ('Grant',     'South', 23),
        ('Brad' ,     'North', 22),
        ('Elizabeth', 'South', 99),
        ('Horace',    'East',   1);
]])

test:do_execsql_test(
    "window1-10.1",
    [[
        SELECT emp, region, total FROM (
            SELECT
                emp, region, total,
                row_number() OVER (
                    PARTITION BY region ORDER BY total DESC
                ) AS "rank"
            FROM sales
        ) WHERE "rank" <= 2 ORDER BY region, total DESC
    ]], {
        'Horace', 'East', 1,
        'Charles', 'North', 45,
        'Alice', 'North', 34,
        'Elizabeth', 'South', 99,
        'Grant', 'South', 23
    })

test:do_execsql_test(
    "window1-10.2",
    [[
        SELECT emp, region, sum(total) OVER win FROM sales
        WINDOW win AS (PARTITION BY region ORDER BY total);
    ]], {
        'Horace', 'East', 1,
        'Brad', 'North', 22,
        'Alice', 'North', 56,
        'Charles', 'North', 101,
        'Darrell', 'South', 8,
        'Frank', 'South', 30,
        'Grant', 'South', 53,
        'Elizabeth', 'South', 152
    })

test:do_execsql_test(
    "window1-10.3",
    [[
        SELECT emp, region, sum(total) OVER win FROM sales
        WINDOW win AS (PARTITION BY region ORDER BY total)
        LIMIT 5;
    ]], {
        'Horace', 'East', 1,
        'Brad', 'North', 22,
        'Alice', 'North', 56,
        'Charles', 'North', 101,
        'Darrell', 'South', 8
    })

test:do_execsql_test(
    "window1-10.4",
    [[
        SELECT emp, region, sum(total) OVER win FROM sales
        WINDOW win AS (PARTITION BY region ORDER BY total)
        LIMIT 5 OFFSET 2
    ]], {
        'Alice', 'North', 56,
        'Charles', 'North', 101,
        'Darrell', 'South', 8,
        'Frank', 'South', 30,
        'Grant', 'South', 53
    })

test:do_execsql_test(
    "window1-10.5",
    [[
        SELECT emp, region, sum(total) OVER win FROM sales
        WINDOW win AS (
            PARTITION BY region ORDER BY total
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        )
    ]], {
        'Horace', 'East', 1,
        'Brad', 'North', 101,
        'Alice', 'North', 79,
        'Charles', 'North', 45,
        'Darrell', 'South', 152,
        'Frank', 'South', 144,
        'Grant', 'South', 122,
        'Elizabeth', 'South', 99
    })

test:do_execsql_test(
    "window1-10.6",
    [[
        SELECT emp, region, sum(total) OVER win FROM sales
        WINDOW win AS (
            PARTITION BY region ORDER BY total
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        ) LIMIT 5 OFFSET 2
    ]], {
        'Alice', 'North', 79,
        'Charles', 'North', 45,
        'Darrell', 'South', 152,
        'Frank', 'South', 144,
        'Grant', 'South', 122
    })

test:do_execsql_test(
    "window1-10.7",
    [[
        SELECT emp, region, CAST((
            SELECT sum(total) OVER (
                ORDER BY total RANGE BETWEEN UNBOUNDED PRECEDING
                AND UNBOUNDED FOLLOWING
            ) FROM sales LIMIT 1
        ) AS TEXT) || emp FROM sales AS "outer";
    ]], {
        "Alice","North","254Alice",
        "Brad","North","254Brad",
        "Charles","North","254Charles",
        "Darrell","South","254Darrell",
        "Elizabeth","South","254Elizabeth",
        "Frank","South","254Frank",
        "Grant","South","254Grant",
        "Horace","East","254Horace"
    })

test:do_execsql_test(
    "window1-10.8",
    [[
        SELECT emp, region, (
            SELECT sum(total) FILTER (WHERE sales.emp != "outer".emp) OVER (
                ORDER BY total RANGE BETWEEN UNBOUNDED PRECEDING
                AND UNBOUNDED FOLLOWING
            ) FROM sales LIMIT 1
        ) FROM sales AS "outer";
    ]], {
        'Alice', 'North', 220,
        'Brad', 'North', 232,
        'Charles', 'North', 209,
        'Darrell', 'South', 246,
        'Elizabeth', 'South', 155,
        'Frank', 'South', 232,
        'Grant', 'South', 231,
        'Horace', 'East', 253
    })

test:execsql( [[
    DROP TABLE IF EXISTS t6;
    CREATE TABLE t6(a INT PRIMARY KEY, b INT, c INT);
]])

-- FIXME: This test returns a non-descriptive error message in tarantool.
test:do_catchsql_test(
    "window1-11.1",
    [[
        CREATE INDEX t6i ON t6(a) WHERE sum(b) OVER ();
    ]],
    -- {1, "misuse of window function SUM()"})
    {1, "At line 1 at or near position 35: keyword 'WHERE' is reserved. Please use double quotes if 'WHERE' is an identifier."})

-- Endless loop on a query with window functions and a limit
test:do_execsql_test(
    "window1-12.100",
    [[
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INT PRIMARY KEY, b TEXT, c TEXT);
INSERT INTO t1 VALUES(1, 'A', 'one');
INSERT INTO t1 VALUES(2, 'B', 'two');
INSERT INTO t1 VALUES(3, 'C', 'three');
INSERT INTO t1 VALUES(4, 'D', 'one');
INSERT INTO t1 VALUES(5, 'E', 'two');
SELECT id, b, row_number() OVER(ORDER BY c) AS x
FROM t1 WHERE id>1
ORDER BY b LIMIT 1;
    ]], { 2, "B", 3 })

test:do_execsql_test(
    "window1-12.110",
    [[
INSERT INTO t1 VALUES(6, 'F', 'three');
INSERT INTO t1 VALUES(7, 'G', 'one');
SELECT id, b, row_number() OVER(ORDER BY c) AS x
FROM t1 WHERE id>1
ORDER BY b LIMIT 2;
    ]], { 2, "B", 5, 3, "C", 3,})

test:do_execsql_test(
    "window1-AVG-inverse",
    [[
        WITH q(x) AS (VALUES (1), (2), (3), (4))
        SELECT cast(a AS TEXT) FROM (
            SELECT avg(cast(x AS DECIMAL)) OVER (
                ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
            ) AS a FROM q
        );
    ]], {
        '1', '1.5', '2.5', '3.5'
    })

-- NOTE(gmoshkin): had to change query in test, because tarantool requires a
-- primary key to be specified for all tables
test:do_execsql_test(
    "window1-13.1",
    [[
  DROP TABLE IF EXISTS t1;
  CREATE TABLE t1(a int primary key, b int);
  INSERT INTO t1 VALUES(1,11);
  INSERT INTO t1 VALUES(2,12);
    ]]
)

-- NOTE(gmoshkin): had to split this test into 2, because tarantool doesn't
-- support multiple queries in one call to box.execute
test:do_execsql_test(
    "window1-13.2.1.1",
    [[
  SELECT a, row_number() OVER(ORDER BY b) FROM t1;
    ]],
    { 1, 1,   2, 2, }
)
test:do_execsql_test(
    "window1-13.2.1.2",
    [[
  SELECT a, row_number() OVER(ORDER BY b DESC) FROM t1;
    ]],
    { 2, 1,   1, 2, }
)

test:do_execsql_test(
    "window1-13.2.2",
    [[
  SELECT a, row_number() OVER(ORDER BY b) FROM t1
    UNION ALL
  SELECT a, row_number() OVER(ORDER BY b DESC) FROM t1;
    ]],
    { 1, 1,   2, 2,   2, 1,   1, 2, }
)
test:do_execsql_test(
    "window1-13.3",
    [[
  SELECT a, row_number() OVER(ORDER BY b) FROM t1
    UNION
  SELECT a, row_number() OVER(ORDER BY b DESC) FROM t1;
    ]],
    { 1, 1,   1, 2,   2, 1,   2, 2, }
)

test:do_execsql_test(
    "window1-13.4",
    [[
  SELECT a, row_number() OVER(ORDER BY b) FROM t1
    EXCEPT
  SELECT a, row_number() OVER(ORDER BY b DESC) FROM t1;
    ]],
    { 1, 1,   2, 2, }
)

test:do_execsql_test(
    "window1-13.5",
    [[
  SELECT a, row_number() OVER(ORDER BY b) FROM t1
    INTERSECT
  SELECT a, row_number() OVER(ORDER BY b DESC) FROM t1;
    ]],
    {}
)

-- Assertion fault when window functions are used.
--
-- Root cause is the query flattener invoking sqlExprDup() on
-- expressions that contain subqueries with window functions.
-- The sqlExprDup() routine is not making correctly initializing
-- Select.pWin field of the subqueries.
--
test:do_execsql_test(
    "window1-14.1",
    [[
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(x INT PRIMARY KEY);
INSERT INTO t1(x) VALUES(12345);
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(c INT PRIMARY KEY);
INSERT INTO t2(c) VALUES(1);

SELECT y FROM (
  SELECT c IN (
    SELECT (row_number() OVER()) FROM t1
  ) AS y FROM t2
);
    ]],
    {true,}
)

test:execsql( [[
DROP TABLE IF EXISTS t7;
CREATE TABLE t7(rowid INT PRIMARY KEY, a INT, b INT);
INSERT INTO t7(rowid, a, b) VALUES
    (1, 1, 3),
    (2, 10, 4),
    (3, 100, 2);
]])

test:do_execsql_test(
    "window1-16.1",
    [[
SELECT rowid, sum(a) OVER (
  PARTITION BY b IN (SELECT rowid FROM t7)
) FROM t7;
    ]],
    {2,10,1,101,3,101,}
)

test:do_execsql_test(
    "window1-16.2",
    [[
SELECT rowid, sum(a) OVER w1 FROM t7
WINDOW w1 AS (PARTITION BY b IN (SELECT rowid FROM t7));
    ]],
    {2,10,1,101,3,101,}
)

-- Test error cases from chaining window definitions.
--
test:execsql( [[
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c TEXT, d INTEGER);
INSERT INTO t1 VALUES(1, 'odd',  'one',   1);
INSERT INTO t1 VALUES(2, 'even', 'two',   2);
INSERT INTO t1 VALUES(3, 'odd',  'three', 3);
INSERT INTO t1 VALUES(4, 'even', 'four',  4);
INSERT INTO t1 VALUES(5, 'odd',  'five',  5);
INSERT INTO t1 VALUES(6, 'even', 'six',   6);
]])

test:do_catchsql_test(
    "window1-17.2.1",
    [[
SELECT c, sum(d) OVER (win1 ORDER BY b) FROM t1
WINDOW win1 AS (ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
    ]],
    {1, "cannot override frame specification of window: win1"}
)

test:do_catchsql_test(
    "window1-17.2.2",
    [[
SELECT c, sum(d) OVER (win4 ORDER BY b) FROM t1
WINDOW win1 AS ()
    ]],
    {1, "no such window: win4"}
)

test:do_catchsql_test(
    "window1-17.2.3",
    [[
SELECT c, sum(d) OVER (win1 PARTITION BY d) FROM t1
WINDOW win1 AS ()
    ]],
    {1, "cannot override PARTITION clause of window: win1"}
)

test:do_catchsql_test(
    "window1-17.2.4",
    [[
SELECT c, sum(d) OVER (win1 ORDER BY d) FROM t1
WINDOW win1 AS (ORDER BY b)
    ]],
    {1, "cannot override ORDER BY clause of window: win1"}
)

test:do_execsql_test(
    "window1-17.3.1",
    [[
SELECT group_concat(c, '.') OVER (PARTITION BY b ORDER BY c)
FROM t1
    ]],
    {
"four", "four.six", "four.six.two",
"five", "five.one", "five.one.three",
    }
)

test:do_execsql_test(
    "window1-17.3.2",
    [[
SELECT group_concat(c, '.') OVER (win1 ORDER BY c)
FROM t1
WINDOW win1 AS (PARTITION BY b)
    ]],
    {
"four", "four.six", "four.six.two",
"five", "five.one", "five.one.three",
    }
)

test:do_execsql_test(
    "window1-17.3.3",
    [[
SELECT group_concat(c, '.') OVER win2
FROM t1
WINDOW win1 AS (PARTITION BY b),
       win2 AS (win1 ORDER BY c)
    ]],
    {
"four", "four.six", "four.six.two",
"five", "five.one", "five.one.three",
    }
)

test:do_execsql_test(
    "window1-17.3.4",
    [[
SELECT group_concat(c, '.') OVER (win2)
FROM t1
WINDOW win1 AS (PARTITION BY b),
       win2 AS (win1 ORDER BY c)
    ]],
    {
"four", "four.six", "four.six.two",
"five", "five.one", "five.one.three",
    }
)

test:do_execsql_test(
    "window1-17.3.5",
    [[
SELECT group_concat(c, '.') OVER win5
FROM t1
WINDOW win1 AS (PARTITION BY b),
       win2 AS (win1),
       win3 AS (win2),
       win4 AS (win3),
       win5 AS (win4 ORDER BY c)
    ]],
    {
"four", "four.six", "four.six.two",
"five", "five.one", "five.one.three",
    }
)

test:execsql( [[
DROP TABLE IF EXISTS t8;
CREATE TABLE t8(a INT PRIMARY KEY);
INSERT INTO t8 VALUES(1), (2), (3);
]])

test:do_execsql_test(
    "window1-17.1",
    [[
SELECT +sum(0) OVER () ORDER BY +sum(0) OVER ();
    ]],
    {0,}
)

test:do_execsql_test(
    "window1-17.2",
    [[
SELECT +sum(a) OVER () FROM t8 ORDER BY +sum(a) OVER () DESC;
    ]],
    {6,6,6,}
)

test:do_execsql_test(
    "window1-17.3",
    [[
SELECT 10+sum(a) OVER (ORDER BY a)
FROM t8
ORDER BY 10+sum(a) OVER (ORDER BY a) DESC;
    ]],
    {16,13,11,}
)

test:finish_test()
