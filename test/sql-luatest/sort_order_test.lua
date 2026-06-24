local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'sql_sort_order'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.after_each(function()
    g.server:exec(function()
        box.execute([[DROP TABLE IF EXISTS t]])
    end)
end)

-- CREATE INDEX honors a per-column ASC/DESC: the parsed order reaches the
-- stored index parts (ascending stays implicit), and it orders rows.
g.test_create_index = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT, b INT)]])
        box.execute([[CREATE INDEX i ON t (a DESC, b ASC)]])
        local parts = box.space.T.index.I.parts
        t.assert_equals(parts[1].sort_order, 'desc')
        t.assert_equals(parts[2].sort_order, nil, 'ascending stays implicit')
        box.execute([[INSERT INTO t VALUES (1, 10, 0), (2, 30, 0),
                                           (3, 20, 0)]])
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{30}, {20}, {10}})
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a ASC]]).rows,
                        {{10}, {20}, {30}})
    end)
end

-- A descending column constraint (PRIMARY KEY ... DESC) reaches the pk parts.
-- (A multi-column PRIMARY KEY(a DESC, b ASC) is not expressible: the parser
-- rejects a sort order inside the primary key column list, so mixed orders
-- are reachable only through secondary and unique indexes.)
g.test_primary_key_desc = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (a INT PRIMARY KEY DESC, b INT)]])
        t.assert_equals(box.space.T.index[0].parts[1].sort_order, 'desc')
        box.execute([[INSERT INTO t VALUES (1, 0), (3, 0), (2, 0)]])
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{3}, {2}, {1}})
    end)
end

-- A unique descending index is honored end to end.
g.test_unique_desc = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[CREATE UNIQUE INDEX i ON t (a DESC)]])
        t.assert_equals(box.space.T.index.I.parts[1].sort_order, 'desc')
        box.execute([[INSERT INTO t VALUES (1, 10), (2, 30), (3, 20)]])
        local _, err = box.execute([[INSERT INTO t VALUES (4, 30)]])
        t.assert_str_contains(tostring(err), 'Duplicate key')
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{30}, {20}, {10}})
    end)
end

-- ALTER TABLE ADD CONSTRAINT UNIQUE carries a descending part to the new
-- index: the part is stored descending, uniqueness is enforced, and the
-- index orders rows.
g.test_alter_add_unique_desc = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[ALTER TABLE t ADD CONSTRAINT u UNIQUE (a DESC)]])
        t.assert_equals(box.space.T.index.U.parts[1].sort_order, 'desc')
        box.execute([[INSERT INTO t VALUES (1, 10), (2, 30), (3, 20)]])
        local _, err = box.execute([[INSERT INTO t VALUES (4, 30)]])
        t.assert_str_contains(tostring(err), 'Duplicate key')
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{30}, {20}, {10}})
    end)
end

-- A descending index satisfies ORDER BY ... DESC directly: the rows are read
-- in index order, with no sorter or ephemeral sort table in the plan. The
-- opposite direction (ORDER BY ... ASC) reads the same index backward.
g.test_desc_index_satisfies_order = function()
    g.server:exec(function()
        -- True if the plan materializes a sort instead of reading in
        -- index order.
        local function uses_sort(sql)
            local exp = box.execute('EXPLAIN ' .. sql)
            for _, row in ipairs(exp.rows) do
                if row[2] == 'SorterOpen' or row[2] == 'OpenTEphemeral' then
                    return true
                end
            end
            return false
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[CREATE INDEX i ON t (a DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 10), (2, 30), (3, 20)]])
        t.assert_equals(uses_sort([[SELECT a FROM t ORDER BY a DESC]]), false,
                        'desc index satisfies ORDER BY DESC without a sort')
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{30}, {20}, {10}})
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a ASC]]).rows,
                        {{10}, {20}, {30}})
    end)
end

-- A descending index serves range scans (>, <, BETWEEN) and returns rows in
-- the requested direction.
g.test_range_scan_desc = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[CREATE INDEX i ON t (a DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 10), (2, 20), (3, 30),
                                           (4, 40)]])
        t.assert_equals(box.execute(
            [[SELECT a FROM t WHERE a > 15 ORDER BY a DESC]]).rows,
            {{40}, {30}, {20}})
        t.assert_equals(box.execute(
            [[SELECT a FROM t WHERE a < 35 ORDER BY a ASC]]).rows,
            {{10}, {20}, {30}})
        t.assert_equals(box.execute(
            [[SELECT a FROM t WHERE a BETWEEN 15 AND 35 ORDER BY a DESC]]).rows,
            {{30}, {20}})
    end)
end

-- min()/max() over a descending index keep using the index and return the
-- correct extreme. A descending index inverts which end holds the min and
-- the max, so the optimization must reach the right one: min sits at the far
-- (LT) end and is reached by a seek, max sits at the front. Neither sorts.
g.test_min_max_desc_index = function()
    g.server:exec(function()
        local function plan(sql)
            local ops = ''
            for _, row in ipairs(box.execute('EXPLAIN ' .. sql).rows) do
                ops = ops .. row[2] .. ' '
            end
            return ops
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[CREATE INDEX i ON t (a DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 10), (2, 30), (3, 20)]])
        t.assert_equals(box.execute([[SELECT min(a) FROM t]]).rows, {{10}})
        t.assert_equals(box.execute([[SELECT max(a) FROM t]]).rows, {{30}})
        local min_plan = plan([[SELECT min(a) FROM t]])
        local max_plan = plan([[SELECT max(a) FROM t]])
        for _, p in ipairs({min_plan, max_plan}) do
            t.assert_not_str_contains(p, 'SorterOpen')
            t.assert_not_str_contains(p, 'OpenTEphemeral')
        end
        t.assert_str_contains(min_plan, 'Seek', 'min seeks the index end')
    end)
end

-- A mixed-order secondary index (a ASC, b DESC) satisfies the matching
-- ORDER BY directly, without a sort.
g.test_mixed_index_satisfies_order = function()
    g.server:exec(function()
        -- True if the plan materializes a sort instead of reading in
        -- index order.
        local function uses_sort(sql)
            local exp = box.execute('EXPLAIN ' .. sql)
            for _, row in ipairs(exp.rows) do
                if row[2] == 'SorterOpen' or row[2] == 'OpenTEphemeral' then
                    return true
                end
            end
            return false
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT, b INT)]])
        box.execute([[CREATE INDEX i ON t (a ASC, b DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 1, 10), (2, 1, 20),
                                           (3, 2, 10), (4, 2, 20)]])
        local q = [[SELECT a, b FROM t ORDER BY a ASC, b DESC]]
        t.assert_equals(uses_sort(q), false,
                        'mixed index satisfies the matching ORDER BY')
        t.assert_equals(box.execute(q).rows,
                        {{1, 20}, {1, 10}, {2, 20}, {2, 10}})
    end)
end

-- NULLs in a descending index sort last (and first when ascending), and a
-- NULL lookup finds them.
g.test_desc_nulls = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT)]])
        box.execute([[CREATE INDEX i ON t (a DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 10), (2, NULL), (3, 20),
                                           (4, NULL)]])
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a DESC]]).rows,
                        {{20}, {10}, {box.NULL}, {box.NULL}})
        t.assert_equals(box.execute([[SELECT a FROM t ORDER BY a ASC]]).rows,
                        {{box.NULL}, {box.NULL}, {10}, {20}})
        t.assert_equals(box.execute(
            [[SELECT id FROM t WHERE a IS NULL ORDER BY id]]).rows,
            {{2}, {4}})
    end)
end

-- A unique mixed-order index (a ASC, b DESC): a duplicate pair is rejected,
-- distinct pairs are kept, and rows with a NULL part are not considered
-- duplicates of each other.
g.test_unique_mixed = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT, b INT)]])
        box.execute([[CREATE UNIQUE INDEX i ON t (a ASC, b DESC)]])
        box.execute([[INSERT INTO t VALUES (1, 1, 10), (2, 1, 20),
                                           (3, 2, 10)]])
        local _, err = box.execute([[INSERT INTO t VALUES (4, 1, 10)]])
        t.assert_str_contains(tostring(err), 'Duplicate key')
        box.execute([[INSERT INTO t VALUES (5, 3, NULL), (6, 3, NULL)]])
        t.assert_equals(box.execute(
            [[SELECT id FROM t WHERE a = 3 ORDER BY id]]).rows,
            {{5}, {6}})
        t.assert_equals(box.execute(
            [[SELECT a, b FROM t WHERE a < 3 ORDER BY a ASC, b DESC]]).rows,
            {{1, 20}, {1, 10}, {2, 10}})
    end)
end
