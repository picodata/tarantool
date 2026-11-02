local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

-- Result of each predicate on b for rows 1, 2, 3 of t, which have b equal to
-- TRUE, FALSE and NULL.
local PREDICATES = {
    {'IS TRUE', {true, false, false}},
    {'IS NOT TRUE', {false, true, true}},
    {'IS FALSE', {false, true, false}},
    {'IS NOT FALSE', {true, false, true}},
    {'IS UNKNOWN', {false, false, true}},
    {'IS NOT UNKNOWN', {true, true, false}},
}

g.before_all(function()
    g.server = server:new({alias = 'boolean_test_predicates'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, b BOOLEAN);]])
        box.execute([[INSERT INTO t VALUES (1, TRUE), (2, FALSE), (3, NULL);]])
    end)
end)

g.after_all(function()
    g.server:exec(function()
        box.execute([[DROP TABLE t;]])
    end)
    g.server:stop()
end)

-- The predicate never returns NULL, also for a NULL operand.
g.test_projection = function()
    g.server:exec(function(predicates)
        for _, p in pairs(predicates) do
            local sql = ('SELECT id, b %s FROM t ORDER BY id;'):format(p[1])
            local res = box.execute(sql)
            t.assert_equals(res.metadata[2].type, 'boolean', p[1])
            local expected = {}
            for id = 1, 3 do
                table.insert(expected, {id, p[2][id]})
            end
            t.assert_equals(res.rows, expected, p[1])
        end
    end, {PREDICATES})
end

-- WHERE checks the jump code; NOT (...) checks the other jump direction.
g.test_where = function()
    g.server:exec(function(predicates)
        for _, p in pairs(predicates) do
            local sql = ('SELECT id FROM t WHERE b %s ORDER BY id;')
                        :format(p[1])
            local expected = {}
            for id = 1, 3 do
                if p[2][id] then
                    table.insert(expected, {id})
                end
            end
            t.assert_equals(box.execute(sql).rows, expected, p[1])

            sql = ('SELECT id FROM t WHERE NOT (b %s) ORDER BY id;')
                  :format(p[1])
            expected = {}
            for id = 1, 3 do
                if not p[2][id] then
                    table.insert(expected, {id})
                end
            end
            t.assert_equals(box.execute(sql).rows, expected, 'NOT ' .. p[1])
        end
    end, {PREDICATES})
end

-- NULL literal in a projection and in WHERE of a subquery.
g.test_null_literal = function()
    g.server:exec(function()
        local sql = [[SELECT NULL IS TRUE, NULL IS NOT TRUE,
                             NULL IS FALSE, NULL IS NOT FALSE;]]
        t.assert_equals(box.execute(sql).rows, {{false, true, false, true}})

        sql = [[SELECT (SELECT COUNT(*) FROM t WHERE NULL IS TRUE),
                       (SELECT COUNT(*) FROM t WHERE NULL IS NOT TRUE),
                       (SELECT COUNT(*) FROM t WHERE NULL IS FALSE),
                       (SELECT COUNT(*) FROM t WHERE NULL IS NOT FALSE);]]
        t.assert_equals(box.execute(sql).rows, {{0, 3, 0, 3}})
    end)
end

-- The operand is an expression that can be NULL.
g.test_compound_operand = function()
    g.server:exec(function()
        local sql = [[SELECT a.id, b.id FROM t AS a, t AS b
                      WHERE (a.b = b.b) IS NOT TRUE ORDER BY 1, 2;]]
        t.assert_equals(box.execute(sql).rows, {
            {1, 2}, {1, 3}, {2, 1}, {2, 3}, {3, 1}, {3, 2}, {3, 3},
        })

        sql = [[SELECT id FROM t WHERE (b AND TRUE) IS NOT FALSE
                ORDER BY id;]]
        t.assert_equals(box.execute(sql).rows, {{1}, {3}})

        sql = [[SELECT id FROM t WHERE (b OR FALSE) IS FALSE ORDER BY id;]]
        t.assert_equals(box.execute(sql).rows, {{2}})

        sql = [[SELECT id, (b OR b) IS NOT TRUE FROM t ORDER BY id;]]
        t.assert_equals(box.execute(sql).rows,
                        {{1, false}, {2, true}, {3, true}})
    end)
end

-- Result of each predicate on an expression for rows 1, 2, 3 of t.
local EXPRESSIONS = {
    {'COALESCE(b, TRUE) IS TRUE', {true, false, true}},
    {'COALESCE(b, FALSE) IS NOT FALSE', {true, false, false}},
    {'COALESCE(NULL, b) IS NOT TRUE', {false, true, true}},
    {'NULLIF(b, FALSE) IS FALSE', {false, false, false}},
    {'NULLIF(b, FALSE) IS NOT TRUE', {false, true, true}},
    {'CASE WHEN id = 1 THEN NULL ELSE b END IS NOT FALSE',
     {true, false, true}},
    {'CASE b WHEN TRUE THEN FALSE WHEN FALSE THEN TRUE END IS TRUE',
     {false, true, false}},
    {'CASE WHEN b IS TRUE THEN NULL ELSE TRUE END IS NOT TRUE',
     {true, false, false}},
    {'(b IS TRUE) IS FALSE', {false, true, true}},
    {'(b IS NOT FALSE) IS NOT TRUE', {false, true, false}},
    {'(b IN (TRUE)) IS NOT TRUE', {false, true, true}},
    {'(id IN (1, 2) AND b) IS FALSE', {false, true, true}},
    {'(id IN (1, 2) AND b) IS NOT TRUE', {false, true, true}},
    {'(id = 3 OR b) IS NOT FALSE', {true, false, true}},
    {'(SELECT s.b FROM t AS s WHERE s.id = t.id) IS TRUE',
     {true, false, false}},
    {'(SELECT s.b FROM t AS s WHERE s.id = t.id + 1) IS NOT FALSE',
     {false, true, true}},
}

-- Each expression is checked in a projection and in WHERE, also under
-- NOT (...).
g.test_expression_operand = function()
    g.server:exec(function(expressions)
        for _, e in pairs(expressions) do
            local sql = ('SELECT id, %s FROM t ORDER BY id;'):format(e[1])
            local expected = {}
            for id = 1, 3 do
                table.insert(expected, {id, e[2][id]})
            end
            t.assert_equals(box.execute(sql).rows, expected, e[1])

            sql = ('SELECT id FROM t WHERE %s ORDER BY id;'):format(e[1])
            expected = {}
            for id = 1, 3 do
                if e[2][id] then
                    table.insert(expected, {id})
                end
            end
            t.assert_equals(box.execute(sql).rows, expected, e[1])

            sql = ('SELECT id FROM t WHERE NOT (%s) ORDER BY id;'):format(e[1])
            expected = {}
            for id = 1, 3 do
                if not e[2][id] then
                    table.insert(expected, {id})
                end
            end
            t.assert_equals(box.execute(sql).rows, expected, 'NOT ' .. e[1])
        end
    end, {EXPRESSIONS})
end

-- IS TRUE and IS NOT TRUE differ only in op2: they must not be merged.
g.test_group_by = function()
    g.server:exec(function()
        local sql = [[SELECT b IS TRUE, b IS NOT TRUE FROM t
                      GROUP BY 1, 2 ORDER BY 1;]]
        t.assert_equals(box.execute(sql).rows, {{false, true}, {true, false}})

        sql = [[SELECT b IS NOT TRUE, COUNT(*) FROM t
                GROUP BY b IS TRUE ORDER BY 1;]]
        t.assert_equals(box.execute(sql).rows, {{false, 1}, {true, 2}})

        sql = [[SELECT b IS NOT FALSE, COUNT(*) FROM t
                GROUP BY b IS FALSE ORDER BY 1;]]
        t.assert_equals(box.execute(sql).rows, {{false, 1}, {true, 2}})

        -- ORDER BY term must not resolve to the result column.
        sql = [[SELECT b IS TRUE, id FROM t ORDER BY b IS NOT TRUE, id;]]
        t.assert_equals(box.execute(sql).rows,
                        {{true, 1}, {false, 2}, {false, 3}})

        -- The sort must not be skipped as if ORDER BY equals GROUP BY.
        sql = [[SELECT COUNT(*) FROM t GROUP BY b IS TRUE
                ORDER BY b IS NOT TRUE;]]
        t.assert_equals(box.execute(sql).rows, {{1}, {2}})
    end)
end

-- The operand type is not known until the parameter is bound.
g.test_bound_parameter = function()
    g.server:exec(function()
        local sql = [[SELECT ? IS TRUE, ? IS NOT TRUE,
                             ? IS FALSE, ? IS NOT FALSE;]]
        local cases = {
            {true, {true, false, false, true}},
            {false, {false, true, true, false}},
            {box.NULL, {false, true, false, true}},
        }
        for _, c in pairs(cases) do
            local v = c[1]
            t.assert_equals(box.execute(sql, {v, v, v, v}).rows, {c[2]})
        end

        local expected = "Type mismatch: can not convert integer(1) to boolean"
        local _, err = box.execute([[SELECT ? IS TRUE;]], {1})
        t.assert_equals(err.message, expected)
        _, err = box.execute([[SELECT COUNT(*) FROM t WHERE ? IS NOT FALSE;]],
                             {1})
        t.assert_equals(err.message, expected)
    end)
end

-- A non-boolean operand is an error in a projection and in WHERE.
g.test_type_mismatch = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT 1 IS TRUE;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert integer(1) to boolean")

        _, err = box.execute([[SELECT 'a' IS NOT FALSE;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert string('a') to boolean")

        _, err = box.execute([[SELECT id FROM t WHERE id IS NOT TRUE;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert integer(1) to boolean")

        _, err = box.execute([[SELECT id FROM t WHERE 'a' IS FALSE;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert string('a') to boolean")

        _, err = box.execute([[SELECT COALESCE(id, 0) IS TRUE FROM t;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert integer(1) to boolean")

        _, err = box.execute([[SELECT id FROM t
                               WHERE CASE WHEN b THEN 1 END IS NOT FALSE;]])
        t.assert_equals(err.message,
                        "Type mismatch: can not convert integer(1) to boolean")
    end)
end

-- IS binds tighter than NOT and AND, and on the same level as comparison
-- operators. PostgreSQL puts IS below comparison operators, but IS TRUE is
-- a postfix operator, so the results are the same.
g.test_precedence = function()
    g.server:exec(function()
        local sql = [[SELECT NOT FALSE IS TRUE, 1 = 2 IS FALSE,
                             TRUE AND NULL IS FALSE,
                             FALSE OR NULL IS NOT TRUE;]]
        t.assert_equals(box.execute(sql).rows, {{true, true, false, true}})
    end)
end

-- An index on the operand drives the search: IS TRUE and IS FALSE select
-- the same rows as = TRUE and = FALSE. IS NOT TRUE selects the same rows as
-- = FALSE OR IS NULL, so it searches the index twice. On a NOT NULL column
-- it selects the same rows as = FALSE.
g.test_index = function()
    g.server:exec(function(predicates)
        box.execute([[CREATE INDEX ib ON t (b);]])
        local function plan(from)
            local sql = 'EXPLAIN QUERY PLAN SELECT 1 FROM ' .. from .. ';'
            local res = {}
            for _, row in pairs(box.execute(sql).rows) do
                table.insert(res, row[4])
            end
            return res
        end
        -- Each step of the plan contains the matching string.
        local function assert_plan(from, expected)
            local steps = plan(from)
            t.assert_equals(#steps, #expected, from)
            for i, e in ipairs(expected) do
                t.assert_str_contains(steps[i], e, false, from)
            end
        end
        local search = 'SEARCH TABLE T USING COVERING INDEX IB (B=?)'
        assert_plan('t WHERE b IS TRUE', {search})
        assert_plan('t WHERE b IS FALSE', {search})
        assert_plan('t WHERE b IS NOT TRUE', {search, search})
        assert_plan('t WHERE b IS NOT FALSE', {search, search})

        for _, p in pairs(predicates) do
            local sql = ('SELECT id FROM t WHERE b %s ORDER BY id;')
                        :format(p[1])
            local expected = {}
            for id = 1, 3 do
                if p[2][id] then
                    table.insert(expected, {id})
                end
            end
            t.assert_equals(box.execute(sql).rows, expected, p[1])
        end
        local sql = 'SELECT id FROM t WHERE b IS TRUE AND b IS NOT FALSE;'
        t.assert_equals(box.execute(sql).rows, {{1}})
        sql = 'SELECT id FROM t WHERE b IS NOT TRUE AND b IS NOT FALSE;'
        t.assert_equals(box.execute(sql).rows, {{3}})

        -- A virtual OR term is not added to an OR clause.
        assert_plan('t WHERE b IS NOT TRUE OR id = 1', {'SCAN TABLE T'})
        sql = 'SELECT id FROM t WHERE b IS NOT TRUE OR id = 1 ORDER BY id;'
        t.assert_equals(box.execute(sql).rows, {{1}, {2}, {3}})
        box.execute([[DROP INDEX ib ON t;]])

        box.execute([[CREATE TABLE n (id INT PRIMARY KEY,
                                      b BOOLEAN NOT NULL);]])
        box.execute([[CREATE INDEX ib ON n (b);]])
        box.execute([[INSERT INTO n VALUES (1, TRUE), (2, FALSE);]])
        assert_plan('n WHERE b IS NOT TRUE',
                    {'SEARCH TABLE N USING COVERING INDEX IB (B=?)'})
        sql = 'SELECT id FROM n WHERE b IS NOT TRUE;'
        t.assert_equals(box.execute(sql).rows, {{2}})
        sql = 'SELECT id FROM n WHERE b IS NOT FALSE;'
        t.assert_equals(box.execute(sql).rows, {{1}})

        -- A NOT NULL column is NULL in a row that LEFT JOIN adds. The
        -- search for b = FALSE must not skip the row that ON selects.
        sql = [[SELECT t.id, n.id FROM t LEFT JOIN n ON n.b
                WHERE n.b IS NOT TRUE;]]
        t.assert_equals(box.execute(sql).rows, {})

        -- The search on the right side of a LEFT JOIN skips the rows of n
        -- that ON selects, and LEFT JOIN adds a row with NULL n.b for them.
        -- The WHERE term must remove that row.
        local from = 't LEFT JOIN n INDEXED BY ib ON n.id = t.id WHERE n.b '
        local search_n = 'SEARCH TABLE N USING COVERING INDEX IB (B=?)'
        for _, c in pairs({{'IS TRUE', {{1, 1}}}, {'IS FALSE', {{2, 2}}}}) do
            assert_plan(from .. c[1], {'SCAN TABLE T', search_n})
            sql = 'SELECT t.id, n.id FROM ' .. from .. c[1] .. ' ORDER BY 1;'
            t.assert_equals(box.execute(sql).rows, c[2], c[1])
        end
        box.execute([[DROP TABLE n;]])
    end, {PREDICATES})
end

-- An index search on a non-boolean column must not skip the values that
-- raise a type mismatch.
g.test_index_non_boolean = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE s (id INT PRIMARY KEY, v SCALAR);]])
        box.execute([[CREATE INDEX iv ON s (v);]])
        box.execute([[INSERT INTO s VALUES (1, TRUE), (2, 1);]])
        local expected = "Type mismatch: can not convert scalar(1) to boolean"
        for _, p in pairs({'IS TRUE', 'IS FALSE',
                           'IS NOT TRUE', 'IS NOT FALSE'}) do
            local sql = 'SELECT id FROM s WHERE v ' .. p .. ';'
            local _, err = box.execute(sql)
            t.assert_equals(err and err.message, expected, p)
        end
        box.execute([[DROP TABLE s;]])
    end)
end

-- Trigger bodies are stored as reduced copies of the expression tree.
g.test_trigger = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE log (id INT, tag STRING,
                                        PRIMARY KEY (id, tag));]])
        box.execute([[CREATE TABLE src (id INT PRIMARY KEY, b BOOLEAN);]])
        box.execute([[CREATE TRIGGER tr1 AFTER INSERT ON src FOR EACH ROW
                      WHEN new.b IS NOT TRUE
                      BEGIN INSERT INTO log VALUES (new.id, 'bare'); END;]])
        -- The predicate is not the root of the WHEN expression: the copy of
        -- the node must not be overwritten by the copy of the next node.
        box.execute([[CREATE TRIGGER tr2 AFTER INSERT ON src FOR EACH ROW
                      WHEN new.b IS TRUE AND new.id > 0
                      BEGIN INSERT INTO log VALUES (new.id, 'and'); END;]])
        box.execute([[CREATE TRIGGER tr3 AFTER INSERT ON src FOR EACH ROW
                      WHEN new.id > 0 AND new.b IS NOT FALSE
                      BEGIN INSERT INTO log VALUES (new.id, 'right'); END;]])
        box.execute([[INSERT INTO src VALUES
                      (1, TRUE), (2, FALSE), (3, NULL);]])
        local sql = [[SELECT id FROM log WHERE tag = ? ORDER BY id;]]
        t.assert_equals(box.execute(sql, {'bare'}).rows, {{2}, {3}})
        t.assert_equals(box.execute(sql, {'and'}).rows, {{1}})
        t.assert_equals(box.execute(sql, {'right'}).rows, {{1}, {3}})
        box.execute([[DROP TABLE src;]])
        box.execute([[DROP TABLE log;]])
    end)
end
