#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(21)

-- Regression test for whereRangeVectorLen() in src/box/sql/where.c.
--
-- A row-value range comparison
--
--     WHERE (c1, c2, ..., cN) op (v1, v2, ..., vN)        -- op in >, <, >=, <=
--
-- whose left-hand side matches the leading columns of an index should
-- compile down to a single multi-column Seek of length N, not to a
-- single-column Seek followed by a per-row residual filter.
--
-- Two distinct gates inside whereRangeVectorLen() were preventing this:
--
--   1. An over-strict "if (id == COLL_NONE) break;" check terminated
--      the vector-length probe on the first non-collated column
--      (INTEGER, DATETIME, DECIMAL, ...), collapsing the seek to one
--      column.
--
--   2. The type-compatibility gate used sql_type_result(), which is the
--      *arithmetic* result-type table (e.g. DATETIME - DATETIME =
--      INTERVAL, STRING - STRING = SCALAR), not a comparison-compat
--      table. It rejected DATETIME-vs-DATETIME and STRING-vs-STRING
--      pairs, again collapsing the seek to one column.
--
-- The tests below pin down both correctness and the resulting multi-
-- column seek for the patterns most commonly produced by paginated
-- keyset queries on real-world schemas.

-- Helper: test:execsql() flattens the result of EXPLAIN into a single
-- sequence of 8 elements per opcode (addr, opcode, p1, p2, p3, p4, p5,
-- comment). Walk the sequence, find every multi-column seek, and
-- report the maximum P4 (key column count) seen across them. Without
-- the fix this is 1 for the queries below; with the fix it equals the
-- number of leading index columns the predicate can pin down.
local function max_seek_key_len(explain_rows)
    local best = 0
    for i = 1, #explain_rows, 8 do
        local opcode = explain_rows[i + 1]
        local p4 = explain_rows[i + 5]
        if (opcode == 'SeekGE' or opcode == 'SeekGT' or
            opcode == 'SeekLE' or opcode == 'SeekLT') and
            tonumber(p4) ~= nil then
            local n = tonumber(p4)
            if n > best then best = n end
        end
    end
    return best
end

-- ====================================================================
-- Section 1: minimal three-column case (all-INT and mixed-type PK).
-- ====================================================================

test:do_execsql_test(
    "rowvalue-1.0",
    [[
        CREATE TABLE t1 (
            a INTEGER,
            b INTEGER,
            c INTEGER,
            PRIMARY KEY (a, b, c)
        );
        INSERT INTO t1 VALUES (1, 1, 1);
        INSERT INTO t1 VALUES (1, 1, 2);
        INSERT INTO t1 VALUES (1, 2, 0);
        INSERT INTO t1 VALUES (2, 0, 0);

        CREATE TABLE t2 (
            a INTEGER,
            b DATETIME,
            c STRING,
            PRIMARY KEY (a, b, c)
        );
        INSERT INTO t2 VALUES
            (1, CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME), 'x');
        INSERT INTO t2 VALUES
            (1, CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME), 'y');
        INSERT INTO t2 VALUES
            (1, CAST('2024-08-29 00:00:00.0 +00:00:00' AS DATETIME), 'x');
        INSERT INTO t2 VALUES
            (2, CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME), 'x');
    ]], {
    })

test:do_execsql_test(
    "rowvalue-1.1",
    [[
        SELECT a, b, c FROM t1
        WHERE (a, b, c) > (1, 1, 1)
        ORDER BY a, b, c
    ]], {
        1, 1, 2,
        1, 2, 0,
        2, 0, 0,
    })

test:do_execsql_test(
    "rowvalue-1.2",
    [[
        SELECT a, c FROM t2
        WHERE (a, b, c) > (
            CAST(1 AS INTEGER),
            CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
            CAST('x' AS STRING))
        ORDER BY a, b, c
    ]], {
        1, 'y',
        1, 'x',
        2, 'x',
    })

test:do_test(
    "rowvalue-1.3",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT a, b, c FROM t1 WHERE (a, b, c) > (1, 1, 1)
        ]]))
    end,
    3)

test:do_test(
    "rowvalue-1.4",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT a FROM t2 WHERE (a, b, c) > (
                CAST(1 AS INTEGER),
                CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
                CAST('x' AS STRING))
        ]]))
    end,
    3)

-- ====================================================================
-- Section 2: all four range operators on a 4-column INTEGER PK.
--
-- Correctness is checked for >, <, >= and <=. Plan length is asserted
-- only for > and >= because those operators reliably emit a SeekGT /
-- SeekGE; < and <= are codegen'd as Rewind + IdxLT-style top-bound,
-- which doesn't surface as a Seek* opcode.
-- ====================================================================

test:do_execsql_test(
    "rowvalue-2.0",
    [[
        CREATE TABLE t3 (
            a INT,
            b INT,
            c INT,
            d INT,
            PRIMARY KEY (a, b, c, d)
        );
        INSERT INTO t3 VALUES (1, 1, 1, 1);
        INSERT INTO t3 VALUES (1, 1, 1, 2);
        INSERT INTO t3 VALUES (1, 1, 2, 1);
        INSERT INTO t3 VALUES (1, 2, 1, 1);
        INSERT INTO t3 VALUES (2, 1, 1, 1);
        INSERT INTO t3 VALUES (2, 2, 2, 2);
    ]], {
    })

test:do_execsql_test(
    "rowvalue-2.1",
    [[
        SELECT a, b, c, d FROM t3
        WHERE (a, b, c, d) > (1, 1, 1, 2)
        ORDER BY a, b, c, d
    ]], {
        1, 1, 2, 1,
        1, 2, 1, 1,
        2, 1, 1, 1,
        2, 2, 2, 2,
    })

test:do_execsql_test(
    "rowvalue-2.2",
    [[
        SELECT a, b, c, d FROM t3
        WHERE (a, b, c, d) < (1, 2, 1, 1)
        ORDER BY a, b, c, d
    ]], {
        1, 1, 1, 1,
        1, 1, 1, 2,
        1, 1, 2, 1,
    })

test:do_execsql_test(
    "rowvalue-2.3",
    [[
        SELECT a, b, c, d FROM t3
        WHERE (a, b, c, d) >= (2, 1, 1, 1)
        ORDER BY a, b, c, d
    ]], {
        2, 1, 1, 1,
        2, 2, 2, 2,
    })

test:do_execsql_test(
    "rowvalue-2.4",
    [[
        SELECT a, b, c, d FROM t3
        WHERE (a, b, c, d) <= (1, 1, 2, 1)
        ORDER BY a, b, c, d
    ]], {
        1, 1, 1, 1,
        1, 1, 1, 2,
        1, 1, 2, 1,
    })

test:do_test(
    "rowvalue-2.5",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT a FROM t3 WHERE (a, b, c, d) > (1, 1, 1, 2)
        ]]))
    end,
    4)

test:do_test(
    "rowvalue-2.6",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT a FROM t3 WHERE (a, b, c, d) >= (2, 1, 1, 1)
        ]]))
    end,
    4)

-- ====================================================================
-- Section 3: 11-column PK whose shape (column count, type mix and
--            order) mirrors the user's production reproducer. Column
--            names are anonymised to c1..c11; the underlying types
--            (six INTEGER, then DATETIME, then INTEGER, then three
--            STRING) match the original.
-- ====================================================================

test:do_execsql_test(
    "rowvalue-3.0",
    [[
        CREATE TABLE t4 (
            c1  INTEGER,
            c2  INTEGER,
            c3  INTEGER,
            c4  INTEGER,
            c5  INTEGER,
            c6  INTEGER,
            c7  DATETIME,
            c8  INTEGER,
            c9  STRING,
            c10 STRING,
            c11 STRING,
            PRIMARY KEY (c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11)
        );
        INSERT INTO t4 VALUES (
            11, 0, 4, 8, 3, 2024,
            CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
            23, '024132003', '80648455', '9979');
        INSERT INTO t4 VALUES (
            11, 0, 4, 8, 3, 2024,
            CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
            23, '024132003', '80648455', '9980');
        INSERT INTO t4 VALUES (
            12, 0, 0, 0, 0, 0,
            CAST('1970-01-01 00:00:00.0 +00:00:00' AS DATETIME),
            0, 'a', 'b', 'c');
    ]], {
    })

test:do_execsql_test(
    "rowvalue-3.1",
    [[
        SELECT c1, c11 FROM t4
        WHERE (c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11)
            > (CAST(11 AS INT),
               CAST(0 AS INT),
               CAST(4 AS INT),
               CAST(8 AS INT),
               CAST(3 AS INT),
               CAST(2024 AS INT),
               CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
               CAST(23 AS INT),
               CAST('024132003' AS STRING),
               CAST('80648455' AS STRING),
               CAST('9979' AS STRING))
        ORDER BY c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11
    ]], {
        11, '9980',
        12, 'c',
    })

test:do_test(
    "rowvalue-3.2",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT c1 FROM t4
            WHERE (c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11)
                > (CAST(11 AS INT),
                   CAST(0 AS INT),
                   CAST(4 AS INT),
                   CAST(8 AS INT),
                   CAST(3 AS INT),
                   CAST(2024 AS INT),
                   CAST('2024-08-28 00:00:00.0 +00:00:00' AS DATETIME),
                   CAST(23 AS INT),
                   CAST('024132003' AS STRING),
                   CAST('80648455' AS STRING),
                   CAST('9979' AS STRING))
        ]]))
    end,
    11)

-- -- ====================================================================
-- -- Section 4: leading equality terms followed by a vector range.
-- -- The function comment in where.c specifically describes:
-- --
-- --     WHERE a = ? AND (b, c, d) > (?, ?, ?)
-- --
-- -- with index ON (a, b, c, d, e), nEq = 1, vector size = 3. The seek
-- -- key length the planner emits is nEq + vector_len = 1 + 3 = 4.
-- -- ====================================================================

test:do_execsql_test(
    "rowvalue-4.0",
    [[
        CREATE TABLE t5 (
            a INT,
            b INT,
            c INT,
            d INT,
            PRIMARY KEY (a, b, c, d)
        );
        INSERT INTO t5 VALUES (1, 1, 1, 1);
        INSERT INTO t5 VALUES (1, 1, 2, 0);
        INSERT INTO t5 VALUES (1, 2, 1, 0);
        INSERT INTO t5 VALUES (2, 1, 1, 1);
        INSERT INTO t5 VALUES (2, 1, 2, 0);
    ]], {
    })

test:do_execsql_test(
    "rowvalue-4.1",
    [[
        SELECT a, b, c, d FROM t5
        WHERE a = 1 AND (b, c, d) > (1, 1, 1)
        ORDER BY a, b, c, d
    ]], {
        1, 1, 2, 0,
        1, 2, 1, 0,
    })

test:do_test(
    "rowvalue-4.2",
    function()
        return max_seek_key_len(test:execsql([[
            EXPLAIN
            SELECT a FROM t5 WHERE a = 1 AND (b, c, d) > (1, 1, 1)
        ]]))
    end,
    4)

-- -- ====================================================================
-- -- Section 5: equivalent predicates expressed with different RHS shapes.
-- --
-- -- The planner must accept all three shapes and produce the same result
-- -- set on the same data: bare literals, all-CAST, and mixed.
-- -- ====================================================================

test:do_execsql_test(
    "rowvalue-5.1",
    [[
        SELECT a, b, c FROM t1
        WHERE (a, b, c) > (1, 1, 1)
        ORDER BY a, b, c
    ]], {
        1, 1, 2,
        1, 2, 0,
        2, 0, 0,
    })

test:do_execsql_test(
    "rowvalue-5.2",
    [[
        SELECT a, b, c FROM t1
        WHERE (a, b, c) > (
            CAST(1 AS INTEGER),
            CAST(1 AS INTEGER),
            CAST(1 AS INTEGER))
        ORDER BY a, b, c
    ]], {
        1, 1, 2,
        1, 2, 0,
        2, 0, 0,
    })

test:do_execsql_test(
    "rowvalue-5.3",
    [[
        SELECT a, b, c FROM t1
        WHERE (a, b, c) > (1, CAST(1 AS INTEGER), 1)
        ORDER BY a, b, c
    ]], {
        1, 1, 2,
        1, 2, 0,
        2, 0, 0,
    })

test:finish_test()
