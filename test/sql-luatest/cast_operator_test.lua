local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'cast-operator'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT, s TEXT);]])
        box.execute([[CREATE INDEX i ON t (a);]])
        box.execute([[INSERT INTO t VALUES (1, 10, '3'), (2, 20, '2'),
                                           (3, 30, '1');]])
        -- Returns the rows of the query, or nil and the error message.
        rawset(_G, 'rows', function(sql, params)
            local res, err = box.execute(sql, params or {})
            if res == nil then
                return nil, err.message
            end
            return res.rows
        end)
        -- Returns all that describes the result of the query: the rows
        -- and the metadata, or the error message.
        rawset(_G, 'result', function(sql)
            local res, err = box.execute(sql)
            if res == nil then
                return {err = err.message}
            end
            return {rows = res.rows, metadata = res.metadata}
        end)
        -- Checks that the two queries give the same rows and metadata,
        -- or the same error. Returns this result.
        rawset(_G, 'assert_same', function(sql1, sql2)
            local res1 = _G.result(sql1)
            local res2 = _G.result(sql2)
            t.assert_equals(res1, res2, sql1 .. ' vs ' .. sql2)
            return res1
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The operator gives the value of the given type.
g.test_basic = function()
    g.server:exec(function()
        local res = box.execute([[SELECT '1'::INT, 1::TEXT, a::TEXT FROM t
                                  WHERE id = 1;]])
        t.assert_equals(res.rows, {{1, '1', '10'}})
        t.assert_equals(res.metadata, {
            {name = 'COLUMN_1', type = 'integer'},
            {name = 'COLUMN_2', type = 'string'},
            {name = 'COLUMN_3', type = 'string'},
        })
    end)
end

-- The operator takes each type name that CAST takes, and the result is the
-- same as the result of CAST, an error included.
g.test_same_as_cast_for_all_types = function()
    g.server:exec(function()
        local types = {
            'TEXT', 'STRING', 'VARCHAR(10)', 'SCALAR', 'BOOL', 'BOOLEAN',
            'VARBINARY', 'UUID', 'ANY', 'ARRAY', 'MAP', 'DATETIME',
            'INTERVAL', 'NUMBER', 'DOUBLE', 'INT', 'INTEGER', 'UNSIGNED',
            'DECIMAL',
        }
        local values = {
            '1', '-1', '1.5', '1.5e0', "'1'", "'a'", "x'31'", 'true', 'NULL',
            "'11111111-1111-1111-1111-111111111111'", '[1, 2]', "{'a': 1}",
            "'2001-02-03T04:05:06Z'",
        }
        local ok_count = 0
        for _, type in ipairs(types) do
            for _, value in ipairs(values) do
                local sql_cast = ('SELECT CAST(%s AS %s);'):format(value, type)
                -- The parentheses are for the negative number.
                local sql_op = ('SELECT (%s)::%s;'):format(value, type)
                if _G.assert_same(sql_cast, sql_op).err == nil then
                    ok_count = ok_count + 1
                end
            end
        end
        -- There are both correct and incorrect casts in the set.
        t.assert_gt(ok_count, #types)
        t.assert_lt(ok_count, #types * #values)
    end)
end

-- The type name is not case-sensitive.
g.test_type_name_case = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT '1'::int, '2'::Integer, 3::tExT;]]),
                        {{1, 2, '3'}})
    end)
end

-- The operator binds tighter than the unary operators, as in PostgreSQL.
g.test_precedence_unary = function()
    g.server:exec(function()
        -- -('1'::INT), not (-'1')::INT.
        t.assert_equals(_G.rows([[SELECT -'1'::INT;]]), {{-1}})
        t.assert_equals(_G.rows([[SELECT +'1'::INT;]]), {{1}})
        t.assert_equals(_G.rows([[SELECT - - '1'::INT;]]), {{1}})
        -- (-1)::UNSIGNED is an error, -(1::UNSIGNED) is not.
        t.assert_equals(_G.rows([[SELECT -1::UNSIGNED;]]), {{-1}})
        local _, err = _G.rows([[SELECT (-1)::UNSIGNED;]])
        t.assert_equals(err, 'Type mismatch: can not convert integer(-1) ' ..
                             'to unsigned')
        -- -(1::TEXT) is an error, (-1)::TEXT is not.
        _, err = _G.rows([[SELECT -1::TEXT;]])
        t.assert_equals(err, "Type mismatch: can not convert string('1') " ..
                             "to integer, decimal or double")
        t.assert_equals(_G.rows([[SELECT (-1)::TEXT;]]), {{'-1'}})
        -- ~('1'::INT), not (~'1')::INT.
        t.assert_equals(_G.rows([[SELECT ~'1'::UNSIGNED;]]), {{-2}})
        _, err = _G.rows([[SELECT ~1::TEXT;]])
        t.assert_equals(err, "Type mismatch: can not convert string('1') " ..
                             "to unsigned")
        -- NOT ('true'::BOOL), not (NOT 'true')::BOOL.
        t.assert_equals(_G.rows([[SELECT NOT 'true'::BOOL;]]), {{false}})
    end)
end

-- The operator binds tighter than the binary operators, as in PostgreSQL.
g.test_precedence_binary = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT 1 + '2'::INT * 3;]]), {{7}})
        t.assert_equals(_G.rows([[SELECT '2'::INT * 3 + 1;]]), {{7}})
        t.assert_equals(_G.rows([[SELECT 7 / '2'::INT, 7 % '2'::INT,
                                         7 - '2'::INT;]]), {{3, 1, 5}})
        -- 2 * (3::TEXT), not (2 * 3)::TEXT.
        local _, err = _G.rows([[SELECT 2 * 3::TEXT;]])
        t.assert_equals(err, "Type mismatch: can not convert string('3') " ..
                             "to integer, decimal or double")
        t.assert_equals(_G.rows([[SELECT (2 * 3)::TEXT;]]), {{'6'}})
        -- '1' || (2::TEXT), not ('1' || 2)::TEXT.
        t.assert_equals(_G.rows([[SELECT '1' || 2::TEXT;]]), {{'12'}})
        t.assert_equals(_G.rows([[SELECT 2::TEXT || '1';]]), {{'21'}})
        t.assert_equals(_G.rows([[SELECT 1 | '2'::INT, 3 & '2'::INT,
                                         1 << '2'::INT, 8 >> '2'::INT;]]),
                        {{3, 2, 4, 2}})
        t.assert_equals(_G.rows([[SELECT '2'::INT = 2, 2 = '2'::INT,
                                         '2'::INT != 2, '2'::INT < 3,
                                         1 >= '2'::INT;]]),
                        {{true, true, false, true, false}})
        -- true AND (0::BOOL) would be an error in the other order.
        t.assert_equals(_G.rows([[SELECT true AND 'false'::BOOL,
                                         false OR 'true'::BOOL;]]),
                        {{false, true}})
    end)
end

-- The operator can be an operand of the predicates.
g.test_predicates = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT '1'::INT IN (1, 2),
                                         3 IN ('1'::INT, '3'::INT),
                                         '1'::INT NOT IN (1, 2);]]),
                        {{true, true, false}})
        t.assert_equals(_G.rows([[SELECT '5'::INT BETWEEN '1'::INT AND
                                         '9'::INT;]]), {{true}})
        t.assert_equals(_G.rows([[SELECT 12::TEXT LIKE '1%',
                                         'a' LIKE 'a'::TEXT;]]),
                        {{true, true}})
        t.assert_equals(_G.rows([[SELECT 1::TEXT IS NULL,
                                         NULL::INT IS NULL,
                                         1::TEXT IS NOT NULL;]]),
                        {{false, true, true}})
        t.assert_equals(_G.rows([[SELECT CASE '1'::INT WHEN 1 THEN 2::TEXT
                                         ELSE 3::TEXT END;]]), {{'2'}})
        t.assert_equals(_G.rows([[SELECT CASE WHEN 'true'::BOOL
                                         THEN 1 END::TEXT;]]), {{'1'}})
    end)
end

-- Several operators in a row are applied from left to right.
g.test_chain = function()
    g.server:exec(function()
        local res = box.execute([[SELECT 15e-1::INT::TEXT::NUMBER;]])
        t.assert_equals(res.rows, {{1}})
        t.assert_equals(res.metadata[1].type, 'number')
        _G.assert_same(
            [[SELECT 15e-1::INT::TEXT::NUMBER;]],
            [[SELECT CAST(CAST(CAST(15e-1 AS INT) AS TEXT) AS NUMBER);]])
        t.assert_equals(_G.rows([[SELECT CAST(1 AS TEXT)::INT;]]), {{1}})
        t.assert_equals(_G.rows([[SELECT CAST('1'::INT AS TEXT);]]), {{'1'}})
    end)
end

-- A chain that is too long gives an error about the depth of the
-- expression tree.
g.test_chain_depth_limit = function()
    g.server:exec(function()
        local sql = 'SELECT 1' .. ('::INT'):rep(199) .. ';'
        t.assert_equals(_G.rows(sql), {{1}})
        for _, count in ipairs({200, 1000, 100000}) do
            sql = 'SELECT 1' .. ('::INT'):rep(count) .. ';'
            local _, err = _G.rows(sql)
            t.assert_equals(err, 'Number of nodes in expression tree 201 ' ..
                                 'exceeds the limit (200)')
        end
    end)
end

-- The operator works with the other postfix operators.
g.test_postfix_operators = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT [1, 2][2]::TEXT;]]), {{'2'}})
        t.assert_equals(_G.rows([[SELECT {'a': 5}['a']::TEXT;]]), {{'5'}})
        t.assert_equals(_G.rows([[SELECT [1, 2]::ARRAY[2];]]), {{2}})
        -- The type name does not include the brackets.
        local _, err = _G.rows([[SELECT '1'::INT[1];]])
        t.assert_equals(err, 'Selecting is only possible from map, array ' ..
                             'and json values')
        t.assert_equals(_G.rows([[SELECT 'a'::TEXT COLLATE "unicode_ci" =
                                         'A';]]), {{true}})
        t.assert_equals(_G.rows([[SELECT 'a' COLLATE "unicode_ci"::TEXT =
                                         'A';]]), {{true}})
    end)
end

-- The operand can be each kind of primary expression.
g.test_operands = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT 1::TEXT, 15e-1::TEXT, 1.5::TEXT,
                                         'a'::VARBINARY, x'61'::TEXT,
                                         true::TEXT, NULL::TEXT;]]),
                        {{'1', '1.5', '1.5', 'a', 'a', 'TRUE', nil}})
        t.assert_equals(_G.rows([[SELECT (1 + 2)::TEXT, (SELECT 5)::TEXT,
                                         abs(-5)::TEXT, count(*)::TEXT,
                                         trim(' 7 ')::INT FROM t;]]),
                        {{'3', '5', '5', '3', 7}})
        t.assert_equals(_G.rows([[SELECT a::TEXT, "A"::TEXT, t.a::TEXT,
                                         t."A"::TEXT FROM t WHERE id = 2;]]),
                        {{'20', '20', '20', '20'}})
        t.assert_equals(_G.rows([[SELECT t.a::TEXT, x.a::TEXT, x."A"::TEXT
                                  FROM t JOIN (SELECT 5 AS a) AS x ON true
                                  WHERE t.id = 2;]]), {{'20', '5', '5'}})
        t.assert_equals(_G.rows([[SELECT (1, 2) = (1, '2'::INT);]]),
                        {{true}})
    end)
end

-- Spaces, line breaks and comments can be around the operator, but not
-- in it.
g.test_spaces_and_comments = function()
    g.server:exec(function()
        t.assert_equals(_G.rows("SELECT '1' :: INT, '2'\n::\nINT, " ..
                                "'3'/* a */::/* b */INT, '4'::-- c\nINT, " ..
                                "5 :: VARCHAR ( 10 );"),
                        {{1, 2, 3, 4, '5'}})
        local _, err = _G.rows([[SELECT '1': :INT;]])
        t.assert_equals(err, "Syntax error at line 1 near ':'")
        _, err = _G.rows([[SELECT '1':/**/:INT;]])
        t.assert_equals(err, "Syntax error at line 1 near ':'")
    end)
end

-- The incorrect uses of the operator are syntax errors.
g.test_syntax_errors = function()
    g.server:exec(function()
        local _, err = _G.rows([[SELECT 1::foo;]])
        t.assert_equals(err, "Syntax error at line 1 near 'foo'")
        _, err = _G.rows([[SELECT 1::"INT";]])
        t.assert_equals(err, [[Syntax error at line 1 near '"INT"']])
        _, err = _G.rows([[SELECT 1::;]])
        t.assert_equals(err, "Syntax error at line 1 near ';'")
        _, err = _G.rows([[SELECT ::INT;]])
        t.assert_equals(err, "Syntax error at line 1 near '::'")
        _, err = _G.rows([[SELECT 1:::INT;]])
        t.assert_equals(err, "Syntax error at line 1 near ':'")
        _, err = _G.rows([[SELECT 1::::INT;]])
        t.assert_equals(err, "Syntax error at line 1 near '::'")
        _, err = _G.rows([[SELECT 1::(INT);]])
        t.assert_equals(err, "Syntax error at line 1 near '('")
        _, err = _G.rows([[SELECT 1::VARCHAR;]])
        t.assert_equals(err, "Syntax error at line 1 near ';'")
        _, err = _G.rows([[SELECT 1::1;]])
        t.assert_equals(err, "Syntax error at line 1 near '1'")
    end)
end

-- The operator works with the bound parameters of each kind. The name of
-- a named parameter starts with one colon, the operator has two.
g.test_bind_parameters = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT ?::INT, ?::TEXT;]], {'5', 6}),
                        {{5, '6'}})
        t.assert_equals(_G.rows([[SELECT $1::INT, $2::TEXT;]], {'5', 6}),
                        {{5, '6'}})
        t.assert_equals(_G.rows([[SELECT :a::INT, @b::TEXT, :a::INT::TEXT;]],
                                {{[':a'] = '5'}, {['@b'] = 6}}),
                        {{5, '6', '5'}})
        t.assert_equals(_G.rows([[SELECT :a::INT + :a ::INT;]],
                                {{[':a'] = '5'}}), {{10}})
        local res = box.execute([[SELECT ?::INT, :a::TEXT;]],
                                {1, {[':a'] = 1}})
        t.assert_equals(res.metadata, {
            {name = 'COLUMN_1', type = 'integer'},
            {name = 'COLUMN_2', type = 'string'},
        })
    end)
end

-- The operator works in a map literal. A named parameter after the colon
-- of a map literal needs a space before it.
g.test_map_literal = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT {'1'::INT : 2::TEXT,
                                          'a': '3'::INT};]]),
                        {{{[1] = '2', a = 3}}})
        t.assert_equals(_G.rows([[SELECT {5: :name, 6 : :name::TEXT};]],
                                {{[':name'] = 1}}), {{{[5] = 1, [6] = '1'}}})
        t.assert_equals(_G.rows([[SELECT {:name::TEXT: 1};]],
                                {{[':name'] = 1}}), {{{['1'] = 1}}})
        local _, err = _G.rows([[SELECT {5::name};]], {{[':name'] = 1}})
        t.assert_equals(err, "Syntax error at line 1 near 'name'")
        _, err = _G.rows([[SELECT {5::INT};]])
        t.assert_equals(err, "Syntax error at line 1 near '}'")
    end)
end

-- The operator works in each clause of SELECT.
g.test_select_clauses = function()
    g.server:exec(function()
        t.assert_equals(_G.rows([[SELECT id FROM t WHERE s::INT > 1
                                  ORDER BY s::INT;]]), {{2}, {1}})
        t.assert_equals(_G.rows([[SELECT id FROM t ORDER BY s::INT DESC
                                  LIMIT '2'::INT OFFSET '1'::INT;]]),
                        {{2}, {3}})
        t.assert_equals(_G.rows([[SELECT (a / 20)::TEXT, count(*) FROM t
                                  GROUP BY (a / 20)::TEXT
                                  HAVING count(*)::TEXT = '2';]]),
                        {{'1', 2}})
        t.assert_equals(_G.rows([[SELECT x.id, y.id FROM t AS x JOIN t AS y
                                  ON x.id = y.s::INT ORDER BY x.id;]]),
                        {{1, 3}, {2, 2}, {3, 1}})
        t.assert_equals(_G.rows([[SELECT sum(s::INT)::TEXT, max(a::TEXT),
                                         group_concat(id::TEXT, '')
                                  FROM t;]]), {{'6', '30', '123'}})
        t.assert_equals(_G.rows([[SELECT id FROM t WHERE id IN
                                  (SELECT s::INT FROM t WHERE a::TEXT != '20')
                                  ORDER BY 1;]]), {{1}, {3}})
        t.assert_equals(_G.rows([[SELECT * FROM (VALUES ('1'::INT, 2::TEXT),
                                                 ('3'::INT, 4::TEXT));]]),
                        {{1, '2'}, {3, '4'}})
        t.assert_equals(_G.rows([[SELECT s::INT AS x FROM t ORDER BY x;]]),
                        {{1}, {2}, {3}})
        t.assert_equals(_G.rows([[WITH w(x) AS (SELECT s::INT FROM t)
                                  SELECT sum(x) FROM w;]]), {{6}})
        t.assert_equals(_G.rows([[SELECT s::INT FROM t WHERE id < 3 UNION
                                  SELECT id::INT FROM t ORDER BY 1;]]),
                        {{1}, {2}, {3}})
    end)
end

-- Aggregates whose arguments differ only in the type of the operator are
-- computed separately.
g.test_aggregates_of_casts_to_different_types = function()
    g.server:exec(function()
        local decimal = require('decimal')
        local res = box.execute([[SELECT sum(s::INT), sum(s::DOUBLE),
                                         sum(CAST(s AS INT)) FROM t;]])
        t.assert_equals(res.metadata[1].type, 'decimal')
        t.assert_equals(res.metadata[2].type, 'double')
        t.assert_equals(res.metadata[3].type, 'decimal')
        t.assert_equals(res.rows, {{decimal.new(6), 6, decimal.new(6)}})
    end)
end

-- A comparison of an indexed column with the operator on a constant uses
-- the index, as with CAST.
g.test_index_is_used = function()
    g.server:exec(function()
        local plan = _G.rows([[EXPLAIN QUERY PLAN
                               SELECT id FROM t WHERE a = '20'::INT;]])
        t.assert_str_contains(plan[1][4], 'USING COVERING INDEX I (A=?)')
        t.assert_equals(plan, _G.rows([[
            EXPLAIN QUERY PLAN
            SELECT id FROM t WHERE a = CAST('20' AS INT);]]))
        t.assert_equals(_G.rows([[SELECT id FROM t WHERE a = '20'::INT;]]),
                        {{2}})
    end)
end

-- The operator works in INSERT, UPDATE and DELETE.
g.test_dml = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE d (id INT PRIMARY KEY, a INT, s TEXT);]])
        box.execute([[INSERT INTO d VALUES ('1'::INT, '10'::INT, 1::TEXT),
                                           (2, 20, 2::TEXT);]])
        box.execute([[INSERT INTO d SELECT id + 2, s::INT, a::TEXT FROM d;]])
        t.assert_equals(_G.rows([[SELECT * FROM d;]]),
                        {{1, 10, '1'}, {2, 20, '2'}, {3, 1, '10'},
                         {4, 2, '20'}})
        box.execute([[UPDATE d SET a = s::INT + 1, s = a::TEXT || '!'
                      WHERE id = '3'::INT;]])
        t.assert_equals(_G.rows([[SELECT * FROM d WHERE id = 3;]]),
                        {{3, 11, '1!'}})
        box.execute([[DELETE FROM d WHERE a::TEXT IN ('10', '2');]])
        t.assert_equals(_G.rows([[SELECT id FROM d;]]), {{2}, {3}})
        box.execute([[DROP TABLE d;]])
    end)
end

-- The operator works in a default value. A default value that is not
-- a literal must be in parentheses.
g.test_default_value = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE d (
                          id INT PRIMARY KEY,
                          a INT DEFAULT ('5'::INT),
                          b TEXT DEFAULT ((1 + 2) :: VARCHAR ( 10 ) ),
                          c TEXT DEFAULT (7::INT::TEXT),
                          d INT DEFAULT ('5'::INT + 1));]])
        local format = box.space.D:format()
        t.assert_equals(format[2].sql_default, "'5'::INT")
        t.assert_equals(format[3].sql_default, "(1 + 2) :: VARCHAR ( 10 )")
        t.assert_equals(format[4].sql_default, "7::INT::TEXT")
        t.assert_equals(format[5].sql_default, "'5'::INT + 1")
        box.execute([[INSERT INTO d(id) VALUES (1);]])
        t.assert_equals(_G.rows([[SELECT * FROM d;]]),
                        {{1, 5, '3', '7', 6}})
        box.execute([[DROP TABLE d;]])
        local _, err = _G.rows([[CREATE TABLE d (id INT PRIMARY KEY,
                                                 a INT DEFAULT '5'::INT);]])
        t.assert_equals(err, "Syntax error at line 2 near '::'")
    end)
end

-- The operator works in a CHECK constraint.
g.test_check_constraint = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE d (id INT PRIMARY KEY, s TEXT,
                                      CONSTRAINT c CHECK (s::INT > 5));]])
        box.execute([[INSERT INTO d VALUES (1, '6');]])
        local _, err = _G.rows([[INSERT INTO d VALUES (2, '5');]])
        t.assert_str_contains(err, "Check constraint")
        _, err = _G.rows([[INSERT INTO d VALUES (3, 'a');]])
        t.assert_str_contains(err, "Check constraint")
        t.assert_equals(_G.rows([[SELECT * FROM d;]]), {{1, '6'}})
        box.execute([[DROP TABLE d;]])
    end)
end

-- The operator works in a view and stays in the text of the view.
g.test_view = function()
    g.server:exec(function()
        local sql = [[CREATE VIEW v AS SELECT s::INT + 1 AS x, a::TEXT AS y ]]
                    .. [[FROM t WHERE id::TEXT != '2']]
        box.execute(sql)
        t.assert_equals(box.space._space.index.name:get('V').flags.sql, sql)
        local res = box.execute([[SELECT * FROM v;]])
        t.assert_equals(res.rows, {{4, '10'}, {2, '30'}})
        t.assert_equals(res.metadata, {
            {name = 'X', type = 'integer'},
            {name = 'Y', type = 'string'},
        })
        box.execute([[DROP VIEW v;]])
    end)
end

-- The operator works in the body and in the WHEN clause of a trigger.
g.test_trigger = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE d (id INT PRIMARY KEY, a INT, s TEXT);]])
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON d FOR EACH ROW
                      WHEN new.a::TEXT != '0' BEGIN
                          UPDATE d SET s = new.a::TEXT WHERE id = new.id;
                      END;]])
        box.execute([[INSERT INTO d VALUES (1, 0, 'a'), (2, 7, 'b');]])
        t.assert_equals(_G.rows([[SELECT * FROM d;]]),
                        {{1, 0, 'a'}, {2, 7, '7'}})
        box.execute([[DROP TABLE d;]])
    end)
end

-- The operator works in a prepared statement.
g.test_prepared_statement = function()
    g.server:exec(function()
        local stmt = box.prepare([[SELECT ?::INT + 1, a::TEXT FROM t
                                   WHERE id = ?::INT;]])
        t.assert_equals(stmt.metadata, {
            {name = 'COLUMN_1', type = 'integer'},
            {name = 'COLUMN_2', type = 'string'},
        })
        t.assert_equals(stmt:execute({'1', '2'}).rows, {{2, '20'}})
        t.assert_equals(stmt:execute({2, 3}).rows, {{3, '30'}})
        stmt:unprepare()
    end)
end
