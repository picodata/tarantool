local t = require('luatest')
local server = require('luatest.server')

local g = t.group('table_func')

g.before_all(function(cg)
    cg.server = server:new({alias = 'table_func'})
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:stop()
end)

g.before_each(function(cg)
    cg.server:exec(function()
        box.execute([[SET SESSION "sql_seq_scan" = true;]])
    end)
end)

g.after_each(function(cg)
    cg.server:exec(function()
        pcall(function()
            box.execute([[DROP VIEW IF EXISTS V_GENERATE_SERIES;]])
        end)
        pcall(function()
            box.execute([[DROP TABLE IF EXISTS T_TFUNC_ARG;]])
        end)
        pcall(function()
            box.execute([[DROP TABLE IF EXISTS T_UNNEST_ARG;]])
        end)
        pcall(function()
            box.execute([[DROP TABLE IF EXISTS T_TFUNC_A;]])
        end)
        pcall(function()
            box.execute([[DROP TABLE IF EXISTS T_TFUNC_B;]])
        end)
        pcall(box.schema.func.drop, 'TF_SCALAR')
        pcall(box.schema.func.drop, 'TF_COUNTER')
        pcall(box.schema.func.drop, 'TF_WAIT')
        box.execute('DROP TABLE IF EXISTS UNNEST')
    end)
end)

local function assert_prepared_statement(conn, sql, metadata, rows)
    local stmt = conn:prepare(sql)
    local stmt_id = stmt.stmt_id
    stmt.stmt_id = nil
    t.assert_equals(stmt, {
        metadata = metadata,
        params = {},
        param_count = 0,
    })
    local res = conn:execute(stmt_id)
    t.assert_equals(res.metadata, metadata)
    t.assert_equals(res.rows, rows)
    conn:unprepare(stmt_id)
end

g.test_select = function(cg)
    cg.server:exec(function()
        local res = box.execute([[SELECT * FROM generate_series(1, 3);]])
        t.assert_equals(res.rows, {{1}, {2}, {3}})
        t.assert_equals(res.metadata[1].name, 'VALUE')
    end)
end

g.test_generate_series_seq_scan_disabled = function(cg)
    cg.server:exec(function()
        box.execute([[SET SESSION "sql_seq_scan" = false;]])
        local res = box.execute([[SELECT * FROM generate_series(1, 3);]])
        t.assert_equals(res.rows, {{1}, {2}, {3}})
    end)
end

g.test_generate_series_count = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT COUNT(*) FROM generate_series(1, 3);
        ]])
        t.assert_equals(res.rows, {{3}})
    end)
end

g.test_generate_series_plan_estimate = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            EXPLAIN QUERY PLAN SELECT * FROM generate_series(1, 1000000);
        ]])
        t.assert_equals(res.rows, {
            {0, 0, 0, "SCAN TABLE GENERATE_SERIES (~983040 rows)"},
        })
    end)
end

g.test_independent_table_func_opened_before_outer_loop = function(cg)
    cg.server:exec(function()
        local function opcode_addr(rows, opcode)
            for _, row in ipairs(rows) do
                if row[2]:match('^%s*(.-)%s*$') == opcode then
                    return row[1]
                end
            end
            error(('opcode %s not found'):format(opcode))
        end

        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 3);]])

        local rows = box.execute([[
            EXPLAIN (opcode)
            SELECT T.ID, S.VALUE
              FROM T_TFUNC_ARG AS T
                   LEFT JOIN generate_series(1, 3) AS S ON TRUE;
        ]]).rows
        t.assert_lt(opcode_addr(rows, 'TFuncOpen'),
                    opcode_addr(rows, 'Rewind'))

        rows = box.execute([[
            EXPLAIN (opcode)
            SELECT T.ID, S.VALUE
              FROM T_TFUNC_ARG AS T
                   LEFT JOIN generate_series(1, T.N) AS S ON TRUE;
        ]]).rows
        t.assert_gt(opcode_addr(rows, 'TFuncOpen'),
                    opcode_addr(rows, 'Rewind'))
    end)
end

g.test_generate_series_prepared_metadata_iproto = function(cg)
    local metadata = {{name = 'VALUE', type = 'integer'}}
    assert_prepared_statement(cg.server.net_box,
                              [[SELECT * FROM generate_series(1, 1);]],
                              metadata, {{1}})
end

g.test_generate_series_with_ordinality = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT * FROM generate_series(5, 6) WITH ORDINALITY;
        ]])
        t.assert_equals(res.metadata, {
            {name = 'VALUE', type = 'integer'},
            {name = 'ORDINALITY', type = 'unsigned'},
        })
        t.assert_equals(res.rows, {{5, 1}, {6, 2}})
    end)
end

g.test_where = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT VALUE FROM generate_series(1, 5)
             WHERE VALUE = 2 OR VALUE = 4;
        ]])
        t.assert_equals(res.rows, {{2}, {4}})
    end)
end

g.test_empty_range = function(cg)
    cg.server:exec(function()
        local res = box.execute([[SELECT * FROM generate_series(3, 1);]])
        t.assert_equals(res.rows, {})
    end)
end

g.test_generate_series_null_args = function(cg)
    cg.server:exec(function()
        local res = box.execute([[SELECT * FROM generate_series(NULL, 3);]])
        t.assert_equals(res.rows, {})

        res = box.execute([[SELECT * FROM generate_series(1, NULL);]])
        t.assert_equals(res.rows, {})

        res = box.execute([[SELECT * FROM generate_series(NULL, NULL);]])
        t.assert_equals(res.rows, {})

        for _, args in ipairs({"NULL, 'x'", "'x', NULL"}) do
            local r, err = box.execute('SELECT * FROM GENERATE_SERIES(' ..
                                      args .. ')')
            t.assert_equals(r, nil)
            t.assert_str_contains(err.message, 'wrong arguments for ' ..
                                  'function GENERATE_SERIES()')
        end
        -- The same with a value that has no type before the execution.
        for _, args in ipairs({'NULL, #x', '#x, NULL'}) do
            local r, err = box.execute('SELECT * FROM GENERATE_SERIES(' ..
                                      args .. ')', {{['#x'] = 'x'}})
            t.assert_equals(r, nil)
            t.assert_equals(err.message, "Type mismatch: can not convert " ..
                            "string('x') to integer")
        end
        for _, args in ipairs({'NULL, 1/0', '1/0, NULL'}) do
            local r, err = box.execute('SELECT * FROM GENERATE_SERIES(' ..
                                      args .. ')')
            t.assert_equals(r, nil)
            t.assert_str_contains(err.message, 'division by zero')
        end
    end)
end

g.test_unnest = function(cg)
    cg.server:exec(function()
        local res = box.execute([[SELECT * FROM unnest([1, 2, 3]);]])
        t.assert_equals(res.metadata[1].name, 'VALUE')
        t.assert_equals(res.metadata[1].type, 'integer')
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(tostring(res.rows[2][1]), '2')
        t.assert_equals(tostring(res.rows[3][1]), '3')

        res = box.execute([[SELECT * FROM unnest([]);]])
        t.assert_equals(res.rows, {})

        res = box.execute([[SELECT * FROM unnest(NULL);]])
        t.assert_equals(res.rows, {})

        res = box.execute([[SELECT * FROM unnest([1, NULL, 'x']);]])
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(res.rows[2][1], box.NULL)
        t.assert_equals(res.rows[3][1], 'x')
        t.assert_equals(res.rows[2][1] == box.NULL, true)
    end)
end

g.test_unnest_prepared_metadata_iproto = function(cg)
    local metadata = {{name = 'VALUE', type = 'scalar'}}
    local conn = cg.server.net_box
    local stmt = conn:prepare([[SELECT * FROM unnest([1, NULL, 'x']);]])
    local stmt_id = stmt.stmt_id
    stmt.stmt_id = nil
    t.assert_equals(stmt, {
        metadata = metadata,
        params = {},
        param_count = 0,
    })
    local res = conn:execute(stmt_id)
    t.assert_equals(res.metadata, metadata)
    t.assert_equals(tostring(res.rows[1][1]), '1')
    t.assert_equals(res.rows[2][1], box.NULL)
    t.assert_equals(res.rows[3][1], 'x')
    conn:unprepare(stmt_id)
end

g.test_unnest_json_array = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT VALUE FROM unnest(CAST([1, NULL, 'x'] AS JSON));
        ]])
        t.assert_equals(res.metadata, {{name = 'VALUE', type = 'json'}})
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(tostring(res.rows[2][1]), 'null')
        t.assert_equals(tostring(res.rows[3][1]), '"x"')
        t.assert_equals(res.rows[2][1] == box.NULL, false)

        res = box.execute([[
            SELECT CAST(VALUE AS INTEGER)
              FROM unnest(CAST([1, 2] AS JSON))
             ORDER BY CAST(VALUE AS INTEGER);
        ]])
        t.assert_equals(res.rows, {{1}, {2}})
    end)
end

g.test_unnest_with_ordinality = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT * FROM unnest([10, 20]) WITH ORDINALITY;
        ]])
        t.assert_equals(res.metadata, {
            {name = 'VALUE', type = 'integer'},
            {name = 'ORDINALITY', type = 'unsigned'},
        })
        t.assert_equals(tostring(res.rows[1][1]), '10')
        t.assert_equals(res.rows[1][2], 1)
        t.assert_equals(tostring(res.rows[2][1]), '20')
        t.assert_equals(res.rows[2][2], 2)
    end)
end

g.test_json_each = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT KEY, VALUE FROM json_each(CAST({'b': 2, 'a': [1]} AS JSON));
        ]])
        t.assert_equals(res.metadata, {
            {name = 'KEY', type = 'string'},
            {name = 'VALUE', type = 'json'},
        })
        t.assert_equals(res.rows[1][1], 'a')
        t.assert_equals(tostring(res.rows[1][2]), '[1]')
        t.assert_equals(res.rows[2][1], 'b')
        t.assert_equals(tostring(res.rows[2][2]), '2')

        res = box.execute([[SELECT * FROM json_each(CAST({} AS JSON));]])
        t.assert_equals(res.rows, {})

        res = box.execute([[SELECT * FROM json_each(NULL);]])
        t.assert_equals(res.rows, {})
    end)
end

g.test_json_each_after_unnest_json_array = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT CAST(i.KEY AS TEXT) AS KEY,
                   CAST(i.VALUE AS INTEGER) AS VALUE
              FROM unnest(CAST([{'a': 1}, {'b': 2}] AS JSON)) AS o
                   JOIN json_each(o.VALUE) AS i ON true;
        ]])
        t.assert_equals(res.metadata, {
            {name = 'KEY', type = 'string'},
            {name = 'VALUE', type = 'integer'},
        })
        t.assert_equals(res.rows, {{'a', 1}, {'b', 2}})
    end)
end

g.test_json_each_with_ordinality = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT * FROM json_each(CAST({'a': 1} AS JSON)) WITH ORDINALITY;
        ]])
        t.assert_equals(res.metadata, {
            {name = 'KEY', type = 'string'},
            {name = 'VALUE', type = 'json'},
            {name = 'ORDINALITY', type = 'unsigned'},
        })
        t.assert_equals(res.rows[1][1], 'a')
        t.assert_equals(tostring(res.rows[1][2]), '1')
        t.assert_equals(res.rows[1][3], 1)
    end)
end

g.test_unnest_union = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT VALUE FROM unnest([1])
            UNION ALL
            SELECT VALUE FROM unnest(['x']);
        ]])
        t.assert_equals(res.metadata, {{name = 'VALUE', type = 'integer'}})
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(res.rows[2][1], 'x')

        res = box.execute([[
            SELECT VALUE FROM unnest([1, 1])
            UNION
            SELECT VALUE FROM unnest([1, 2])
            ORDER BY VALUE;
        ]])
        t.assert_equals(res.metadata, {{name = 'VALUE', type = 'integer'}})
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(tostring(res.rows[2][1]), '2')
    end)
end

g.test_unnest_correlated_args = function(cg)
    cg.server:exec(function()
        box.execute([[
            CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY, A ARRAY);
        ]])
        box.execute([[INSERT INTO T_UNNEST_ARG VALUES(1, [1, 2]);]])
        box.execute([[INSERT INTO T_UNNEST_ARG VALUES(2, []);]])
        box.execute([[INSERT INTO T_UNNEST_ARG VALUES(3, [2, 3]);]])

        local expected = {{1, 1}, {1, 2}, {3, 2}, {3, 3}}
        local res = box.execute([[
            SELECT ID, CAST(VALUE AS INTEGER)
              FROM T_UNNEST_ARG, unnest(A)
             ORDER BY ID, CAST(VALUE AS INTEGER);
        ]])
        t.assert_equals(res.rows, expected)

        res = box.execute([[
            SELECT T.ID, CAST(U.VALUE AS INTEGER)
              FROM T_UNNEST_ARG AS T
                   INNER JOIN unnest(T.A) AS U ON 1 = 1
             ORDER BY T.ID, CAST(U.VALUE AS INTEGER);
        ]])
        t.assert_equals(res.rows, expected)

        res = box.execute([[
            SELECT ID, CAST(U.VALUE AS INTEGER)
              FROM T_UNNEST_ARG, unnest(A) AS U
             WHERE CAST(U.VALUE AS INTEGER) = 2
             ORDER BY ID, CAST(U.VALUE AS INTEGER);
        ]])
        t.assert_equals(res.rows, {{1, 2}, {3, 2}})

        res = box.execute([[
            SELECT Q.ID, CAST(U.VALUE AS INTEGER)
              FROM (SELECT ID, A FROM T_UNNEST_ARG) AS Q,
                   unnest(Q.A) AS U
            ORDER BY Q.ID, CAST(U.VALUE AS INTEGER);
        ]])
        t.assert_equals(res.rows, expected)
    end)
end

g.test_join_rescan = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT A.VALUE, B.VALUE
              FROM generate_series(1, 2) AS A,
                   generate_series(10, 11) AS B
             ORDER BY A.VALUE, B.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 10}, {1, 11}, {2, 10}, {2, 11}})
    end)
end

g.test_builtin_not_in_func_space = function(cg)
    cg.server:exec(function()
        local tuple = box.space._func.index.name:get('GENERATE_SERIES')
        t.assert_equals(tuple, nil)
    end)
end

-- A user function can have the name of a table function, as it can have
-- the name of a built-in scalar function. SQL calls it as a scalar function,
-- and the FROM clause still uses the table function.
g.test_user_func_with_table_func_name = function(cg)
    cg.server:exec(function()
        box.schema.func.create('GENERATE_SERIES', {
            language = 'Lua',
            body = 'function(a, b) return a + b end',
            returns = 'integer',
            param_list = {'integer', 'integer'},
            exports = {'LUA', 'SQL'},
        })
        local res = box.execute([[SELECT generate_series(1, 3);]])
        t.assert_equals(res.rows, {{4}})
        res = box.execute([[SELECT * FROM generate_series(1, 3);]])
        t.assert_equals(res.rows, {{1}, {2}, {3}})
        box.schema.func.drop('GENERATE_SERIES')
        local _, err = box.execute([[SELECT generate_series(1, 3);]])
        t.assert_str_contains(err.message,
                              'cannot be used as a scalar function')
    end)
end

-- The name of a table function is case-sensitive, as the name of a built-in
-- scalar function is.
g.test_table_func_name_is_case_sensitive = function(cg)
    cg.server:exec(function()
        local res = box.execute([[SELECT * FROM "GENERATE_SERIES"(1, 2);]])
        t.assert_equals(res.rows, {{1}, {2}})
        for _, name in ipairs({'generate_series', 'unnest', 'Json_Each'}) do
            local _, err = box.execute(
                ([[SELECT * FROM "%s"(1, 2);]]):format(name))
            t.assert_equals(err.message,
                            ("'%s' is not a function"):format(name))
            box.schema.func.create(name, {
                language = 'Lua',
                body = 'function() return 1 end',
                returns = 'integer',
                exports = {'LUA', 'SQL'},
            })
            res = box.execute(([[SELECT "%s"();]]):format(name))
            t.assert_equals(res.rows, {{1}})
            box.schema.func.drop(name)
        end
    end)
end

-- GENERATE_SERIES checks and casts its arguments as a built-in scalar
-- function with INTEGER arguments does.
g.test_generate_series_arg_types = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, D DOUBLE,
                                               C DECIMAL, N NUMBER,
                                               S STRING);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2.0, 2, 2, 'a');]])
        -- A number with an exact integer value is cast to INTEGER.
        for _, case in ipairs({
            {[[SELECT * FROM generate_series(1.0, 2);]]},
            {[[SELECT * FROM generate_series(1, 2e0);]]},
            {[[SELECT * FROM generate_series(?, ?);]], {1, 2.0}},
            {[[SELECT g.VALUE FROM T_TFUNC_ARG t,
                      generate_series(1, t.D) g;]]},
            {[[SELECT g.VALUE FROM T_TFUNC_ARG t,
                      generate_series(1, t.C) g;]]},
        }) do
            local res = box.execute(case[1], case[2] or {})
            t.assert_equals(res.rows, {{1}, {2}}, case[1])
            t.assert_equals(res.metadata[1].type, 'integer')
        end
        -- A wrong type is an error of the preparation when it is known.
        for _, sql in ipairs({
            [[SELECT * FROM generate_series(1, 'a');]],
            [[SELECT * FROM generate_series(true, 1);]],
            [[SELECT * FROM generate_series(1, [1]);]],
            [[SELECT g.VALUE FROM T_TFUNC_ARG t, generate_series(1, t.S) g;]],
        }) do
            local stmt, err = box.prepare(sql)
            t.assert_equals(stmt, nil)
            t.assert_equals(err.message, 'Failed to execute SQL statement: ' ..
                            'wrong arguments for function GENERATE_SERIES()',
                            sql)
        end
        -- Other values give a type mismatch at the execution.
        for _, case in ipairs({
            {[[SELECT * FROM generate_series(1.5, 3);]], {},
             'decimal(1.5)'},
            {[[SELECT * FROM generate_series(?, ?);]], {1, 2.5},
             'double(2.5)'},
            {[[SELECT * FROM generate_series(?, ?);]], {'a', 2},
             "string('a')"},
            {[[SELECT g.VALUE FROM T_TFUNC_ARG t,
                      generate_series(1, t.N) g;]], {}, 'number(2)'},
        }) do
            local _, err = box.execute(case[1], case[2])
            t.assert_equals(err.message, 'Type mismatch: can not convert ' ..
                            case[3] .. ' to integer', case[1])
        end
        -- The bounds are signed 64-bit integers.
        local _, err = box.execute(
            [[SELECT * FROM generate_series(1, 18446744073709551615);]])
        t.assert_equals(err.message, 'Failed to execute SQL statement: ' ..
                        'integer is overflowed')
    end)
end

-- A DELETE and an UPDATE that find their rows by the primary key can read a
-- table function in a subquery of the WHERE clause.
g.test_delete_and_update_by_table_func = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 1), (3, 3), (4, 4),
                                                    (5, 5);]])
        local res = box.execute([[
            UPDATE T_TFUNC_ARG SET N = 0
            WHERE ID IN (SELECT VALUE FROM generate_series(4, 5));
        ]])
        t.assert_equals(res, {row_count = 2})
        res = box.execute([[
            DELETE FROM T_TFUNC_ARG
            WHERE ID IN (SELECT VALUE FROM generate_series(3, 4));
        ]])
        t.assert_equals(res, {row_count = 2})
        res = box.execute([[
            DELETE FROM T_TFUNC_ARG
            WHERE ID = (SELECT MAX(VALUE) FROM generate_series(1, 5));
        ]])
        t.assert_equals(res, {row_count = 1})
        res = box.execute([[SELECT * FROM T_TFUNC_ARG;]])
        t.assert_equals(res.rows, {{1, 1}})
    end)
end

g.test_column_free_args = function(cg)
    cg.server:exec(function()
        local res = box.execute([[
            SELECT * FROM generate_series(1, abs(-3));
        ]])
        t.assert_equals(res.rows, {{1}, {2}, {3}})

        res = box.execute([[
            SELECT * FROM generate_series(1, (SELECT 3));
        ]])
        t.assert_equals(res.rows, {{1}, {2}, {3}})
    end)
end

g.test_correlated_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(2, 3);]])

        local res = box.execute([[
            SELECT ID, VALUE
              FROM T_TFUNC_ARG, generate_series(1, N)
             ORDER BY ID, VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2},
                                   {2, 1}, {2, 2}, {2, 3}})

        res = box.execute([[
            SELECT ID, S.VALUE
              FROM T_TFUNC_ARG, generate_series(1, N) AS S
             WHERE S.VALUE = 3
             ORDER BY ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{2, 3}})

        res = box.execute([[
            SELECT ID, VALUE
              FROM T_TFUNC_ARG,
                   generate_series(1, CASE WHEN N IN (SELECT 2)
                                           THEN 2 ELSE 1 END)
             ORDER BY ID, VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2}, {2, 1}})

        res = box.execute([[
            SELECT G.VALUE, H.VALUE
              FROM generate_series(1, 2) AS G,
                   generate_series(G.VALUE, G.VALUE + 1) AS H
             ORDER BY G.VALUE, H.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2}, {2, 2}, {2, 3}})
    end)
end

g.test_correlated_null_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(2, NULL);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(3, 1);]])

        local res = box.execute([[
            SELECT ID, VALUE
              FROM T_TFUNC_ARG, generate_series(1, N)
             ORDER BY ID, VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2}, {3, 1}})

        res = box.execute([[
            SELECT ID, S.VALUE
              FROM T_TFUNC_ARG
                   LEFT JOIN generate_series(1, N) AS S ON true
             ORDER BY ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2},
                                   {2, box.NULL}, {3, 1}})
    end)
end

g.test_correlated_left_join_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(2, 0);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(3, 1);]])

        local res = box.execute([[
            SELECT ID, S.VALUE
              FROM T_TFUNC_ARG
                   LEFT JOIN generate_series(1, N) AS S ON 1 = 1
             ORDER BY ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2},
                                   {2, box.NULL}, {3, 1}})

        res = box.execute([[
            SELECT ID, S.VALUE
              FROM T_TFUNC_ARG
                   LEFT JOIN generate_series(1, N) AS S ON S.VALUE = 2
             ORDER BY ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 2}, {2, box.NULL},
                                   {3, box.NULL}})

        res = box.execute([[
            SELECT ID, S.VALUE
              FROM T_TFUNC_ARG
                   LEFT JOIN generate_series(1, N) AS S ON 1 = 1
             WHERE S.VALUE = 2
             ORDER BY ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 2}})

        box.execute([[CREATE TABLE T_TFUNC_A(ID INT PRIMARY KEY, M INT);]])
        box.execute([[CREATE TABLE T_TFUNC_B(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(1, 1);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(2, 3);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(2, 2);]])

        res = box.execute([[
            SELECT A.ID, S.VALUE
              FROM T_TFUNC_A AS A
                   INNER JOIN T_TFUNC_B AS B ON A.ID = B.ID
                   LEFT JOIN generate_series(A.M, B.N) AS S ON 1 = 1
             ORDER BY A.ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2}, {2, box.NULL}})

        local _, err = box.execute([[
            SELECT *
              FROM generate_series(1, N)
                   LEFT JOIN T_TFUNC_ARG ON 1 = 1;
        ]])
        t.assert_str_contains(err.message, "resolve field 'N'")
    end)
end

g.test_table_func_arg_name_resolution_scope = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_A(ID INT PRIMARY KEY, N INT);]])
        box.execute([[CREATE TABLE T_TFUNC_B(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(10, 100);]])

        local res = box.execute([[
            SELECT A.ID, S.VALUE, B.ID
              FROM T_TFUNC_A AS A,
                   generate_series(1, N) AS S,
                   T_TFUNC_B AS B
             ORDER BY A.ID, S.VALUE, B.ID;
        ]])
        t.assert_equals(res.rows, {{1, 1, 10}, {1, 2, 10}})

        local _, err = box.execute([[
            SELECT 2 AS N FROM generate_series(1, N);
        ]])
        t.assert_str_contains(err.message, "resolve field 'N'")
    end)
end

g.test_flattened_correlated_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_A(ID INT PRIMARY KEY);]])
        box.execute([[CREATE TABLE T_TFUNC_B(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(1);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(2, 3);]])

        local res = box.execute([[
            SELECT Q.ID, S.VALUE
              FROM (SELECT A.ID, B.N
                      FROM T_TFUNC_A AS A, T_TFUNC_B AS B
                     WHERE A.ID = B.ID) AS Q,
                   generate_series(1, Q.N) AS S
             ORDER BY Q.ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2},
                                   {2, 1}, {2, 2}, {2, 3}})
    end)
end

g.test_flattening_keeps_valid_correlated_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_A(ID INT PRIMARY KEY);]])
        box.execute([[CREATE TABLE T_TFUNC_B(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(1);]])
        box.execute([[INSERT INTO T_TFUNC_A VALUES(2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_B VALUES(2, 3);]])

        local res = box.execute([[
            SELECT Q.ID, S.VALUE
              FROM (SELECT A.ID,
                           (SELECT B.N
                              FROM T_TFUNC_B AS B
                             WHERE B.ID = A.ID) AS N
                      FROM T_TFUNC_A AS A) AS Q,
                   generate_series(1, Q.N) AS S
             ORDER BY Q.ID, S.VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2},
                                   {2, 1}, {2, 2}, {2, 3}})
    end)
end

g.test_duplicated_resolved_select_keeps_table_func_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(2, 3);]])

        local res = box.execute([[
            SELECT (SELECT COUNT(*)
                      FROM T_TFUNC_ARG AS T,
                           generate_series(1, T.N)) AS X
             WHERE X = 5;
        ]])
        t.assert_equals(res.rows, {{5}})
    end)
end

g.test_invalid_correlated_args = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])

        local _, err = box.execute([[
            SELECT * FROM generate_series(1, N), T_TFUNC_ARG;
        ]])
        t.assert_str_contains(err.message, "resolve field 'N'")

        _, err = box.execute([[
            SELECT * FROM generate_series(1, VALUE);
        ]])
        t.assert_str_contains(err.message, "resolve field 'VALUE'")

        _, err = box.execute([[
            SELECT *
              FROM generate_series(1, CASE WHEN N IN (SELECT 1)
                                           THEN 1 ELSE 2 END),
                   T_TFUNC_ARG;
        ]])
        t.assert_str_contains(err.message, "resolve field 'N'")

        _, err = box.execute([[
            SELECT * FROM T_TFUNC_ARG, generate_series(1, (SELECT N));
        ]])
        t.assert_str_contains(err.message,
                              'correlated subqueries are not supported in ' ..
                              'table function arguments')
    end)
end

g.test_unnest_errors = function(cg)
    cg.server:exec(function()
        box.execute([[
            CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY, A ARRAY);
        ]])
        box.execute([[INSERT INTO T_UNNEST_ARG VALUES(1, [1]);]])

        local _, err = box.execute([[SELECT * FROM unnest(1);]])
        t.assert_str_contains(err.message, 'unnest expects array argument')

        _, err = box.execute([[
            SELECT * FROM unnest(CAST({'a': 1} AS JSON));
        ]])
        t.assert_str_contains(err.message,
                              'unnest expects array or json array argument')

        _, err = box.execute([[SELECT * FROM unnest(CAST(1 AS JSON));]])
        t.assert_str_contains(err.message,
                              'unnest expects array or json array argument')

        _, err = box.execute([[SELECT * FROM unnest(json_null());]])
        t.assert_str_contains(err.message,
                              'unnest expects array or json array argument')

        _, err = box.execute([[SELECT * FROM json_each(CAST([1] AS JSON));]])
        t.assert_str_contains(err.message,
                              'json_each expects json object argument')

        _, err = box.execute([[SELECT * FROM json_each(CAST(1 AS JSON));]])
        t.assert_str_contains(err.message,
                              'json_each expects json object argument')

        _, err = box.execute([[SELECT * FROM unnest([1], [2]);]])
        t.assert_str_contains(err.message, 'Wrong number of arguments')

        _, err = box.execute([[
            SELECT * FROM unnest(A), T_UNNEST_ARG;
        ]])
        t.assert_str_contains(err.message, "resolve field 'A'")
    end)
end

g.test_view = function(cg)
    cg.server:exec(function()
        box.execute([[CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, N INT);]])
        box.execute([[INSERT INTO T_TFUNC_ARG VALUES(1, 2);]])
        box.execute([[
            CREATE VIEW V_GENERATE_SERIES AS
            SELECT ID, VALUE FROM T_TFUNC_ARG, generate_series(1, N);
        ]])
        local res = box.execute([[
            SELECT * FROM V_GENERATE_SERIES ORDER BY ID, VALUE;
        ]])
        t.assert_equals(res.rows, {{1, 1}, {1, 2}})
    end)
end

g.test_errors = function(cg)
    cg.server:exec(function()
        local _, err = box.execute([[SELECT generate_series(1, 3);]])
        t.assert_str_contains(err.message,
                              'cannot be used as a scalar function')

        _, err = box.execute([[SELECT * FROM generate_series('a', 1);]])
        t.assert_str_contains(err.message, 'wrong arguments for function ' ..
                              'GENERATE_SERIES()')

        _, err = box.execute([[SELECT * FROM generate_series(1);]])
        t.assert_str_contains(err.message,
                              'Wrong number of arguments')
    end)
end

-- The examples below cover schema inference as well as the original values.
g.test_native_types = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local uuid = require('uuid')
        local cases = {
            {'[1, 2]', 'integer', {{1}, {2}}},
            {'[1, 1.5]', 'number', {{1}, {decimal.new('1.5')}}},
            {'[1, 2e0]', 'number', {{1}, {2}}},
            {'[1.5, 2e0]', 'number', {{decimal.new('1.5')}, {2}}},
            {'[CAST(1 AS UNSIGNED), -1]', 'integer', {{1}, {-1}}},
            {"[1, 'x']", 'scalar', {{1}, {'x'}}},
            {'[1, [2]]', 'any', {{1}, {{2}}}},
            {'[[1], [2]]', 'array', {{{1}}, {{2}}}},
            {"[{'x':1}]", 'map', {{{x = 1}}}},
            {'[NULL, 1]', 'integer', {{box.NULL}, {1}}},
            {'[NULL]', 'any', {{box.NULL}}},
            {'[]', 'any', {}},
            {'[CAST(NULL AS DOUBLE)]', 'double', {{box.NULL}}},
            {'[CAST(1 AS DOUBLE), CAST(1.5 AS DOUBLE)]',
             'double', {{1}, {1.5}}},
            {"[CAST('11111111-1111-1111-1111-111111111111' AS UUID)]",
             'uuid', {{uuid.fromstr('11111111-1111-1111-1111-111111111111')}}},
        }
        for _, case in ipairs(cases) do
            local sql = 'SELECT * FROM UNNEST(' .. case[1] .. ')'
            local r = assert(box.execute(sql))
            t.assert_equals(r.metadata[1].type, case[2], sql)
            t.assert_equals(r.rows, case[3], sql)
        end
        for _, expr in ipairs({'COALESCE(1.5, 2e0)', 'IFNULL(1.5, 2e0)'}) do
            local stmt = assert(box.prepare('SELECT * FROM UNNEST([' ..
                                            expr .. '])'))
            t.assert_equals(stmt.metadata[1].type, 'double')
            local r, err = box.execute(stmt.stmt_id)
            t.assert_equals(r, nil)
            t.assert_str_contains(err.message, 'Type mismatch')
            stmt:unprepare()
            r = assert(box.execute('SELECT * FROM UNNEST([CAST(' .. expr ..
                                   ' AS NUMBER)])'))
            t.assert_equals(r.metadata[1].type, 'number')
            t.assert_equals(r.rows, {{decimal.new('1.5')}})
        end
    end)
end

g.test_null_counts = function(cg)
    cg.server:exec(function()
        local cases = {
            {'NULL', 0, 0}, {'[]', 0, 0}, {'[NULL]', 1, 0},
            {'[1, NULL]', 2, 1}, {'[NULL, JSON_NULL()]', 2, 1},
            {[[CAST('[1,null]' AS JSON)]], 2, 2},
        }
        for _, c in ipairs(cases) do
            local r = assert(box.execute('SELECT COUNT(*), COUNT(VALUE) ' ..
                                         'FROM UNNEST(' .. c[1] .. ')'))
            t.assert_equals(r.rows, {{c[2], c[3]}}, c[1])
        end
    end)
end

g.test_parameter_schema = function(cg)
    local conn = cg.server.net_box
    local stmt = conn:prepare('SELECT * FROM UNNEST(?)')
    t.assert_equals(stmt.metadata, {{name = 'VALUE', type = 'any'}})
    for _, array in ipairs({{1, 2}, {'a', 'b'}, {{1}, {2}}}) do
        local r = conn:execute(stmt.stmt_id, {array})
        t.assert_equals(r.metadata, stmt.metadata)
        t.assert_equals(r.rows, {{array[1]}, {array[2]}})
    end
    conn:unprepare(stmt.stmt_id)
end

g.test_independent_schemas = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY, ' ..
                           'A INT, B INT)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1, 2, 3)'))
        local r = assert(box.execute([[
            SELECT i.VALUE, s.VALUE, a.VALUE, b.VALUE
            FROM T_TFUNC_ARG t, UNNEST([1]) i, UNNEST(['x']) s,
                 UNNEST([t.A, t.B]) a, UNNEST([a.VALUE]) b
        ]]))
        for i, typ in ipairs({'integer', 'string', 'integer', 'integer'}) do
            t.assert_equals(r.metadata[i].type, typ)
        end
        t.assert_equals(r.rows, {{1, 'x', 2, 2}, {1, 'x', 3, 3}})
        for _, source in ipairs({
            '(SELECT A FROM T_TFUNC_ARG) s',
            '(SELECT A FROM T_TFUNC_ARG LIMIT 1) s',
        }) do
            r = assert(box.execute('SELECT VALUE FROM ' .. source ..
                                   ', UNNEST([CAST(s.A AS INTEGER)])'))
            t.assert_equals(r.metadata[1].type, 'integer')
            t.assert_equals(r.rows, {{2}})
        end
        r = assert(box.execute([[
            WITH c(x) AS (SELECT VALUE FROM UNNEST([1])) SELECT x FROM c
        ]]))
        t.assert_equals(r.metadata[1].name, 'X')
        t.assert_equals(r.rows, {{1}})
    end)
end

g.test_grouped_join = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY,' ..
                           ' A ARRAY)'))
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_UNNEST_ARG VALUES' ..
                           '(1,[10,20]),(2,[]),(3,[30]),(4,NULL)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(20),(30)'))
        local query = [[
            SELECT t.ID, u.VALUE, u.ORDINALITY
            FROM %s t LEFT JOIN
                (UNNEST(t.A) WITH ORDINALITY AS u
                 JOIN T_TFUNC_ARG x ON x.ID = CAST(u.VALUE AS INTEGER))
                ON true ORDER BY t.ID
        ]]
        for _, source in ipairs({'T_UNNEST_ARG',
                                 '(SELECT * FROM T_UNNEST_ARG)'}) do
            local r = assert(box.execute(query:format(source)))
            t.assert_equals(r.rows, {{1, 20, 2}, {2, box.NULL, box.NULL},
                                    {3, 30, 1}, {4, box.NULL, box.NULL}})
        end
        local r = assert(box.execute([[
            SELECT a.VALUE, b.VALUE
            FROM UNNEST([20,30]) a,
                 ((UNNEST([a.VALUE]) b JOIN T_TFUNC_ARG x
                   ON x.ID = b.VALUE) JOIN GENERATE_SERIES(1,1) g ON true)
            ORDER BY a.VALUE
        ]]))
        t.assert_equals(r.rows, {{20, 20}, {30, 30}})
        local _, err = box.execute([[
            SELECT * FROM (UNNEST(t.A) u JOIN T_TFUNC_ARG x ON true),
                          T_UNNEST_ARG t
        ]])
        t.assert(err)
        r = assert(box.execute([[
            SELECT t.ID FROM T_UNNEST_ARG t WHERE EXISTS (
                SELECT * FROM (UNNEST(t.A) u JOIN T_TFUNC_ARG x ON true))
        ]]))
        t.assert_equals(r.rows, {{1}, {3}})
    end)
end

g.test_names_parentheses_and_seqscan = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE UNNEST(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO UNNEST VALUES(9)'))
        local r = assert(box.execute('SELECT * FROM (UNNEST([10,20]) ' ..
                                     'WITH ORDINALITY) AS u ' ..
                                     'WHERE VALUE=20'))
        t.assert_equals(r.rows, {{20, 2}})
        r = assert(box.execute('SELECT * FROM UNNEST'))
        t.assert_equals(r.rows, {{9}})
        r = assert(box.execute('WITH UNNEST AS (SELECT 9) ' ..
                               'SELECT u.VALUE AS x FROM UNNEST([1]) u'))
        t.assert_equals(r.rows, {{1}})
        t.assert_equals(r.metadata[1].name, 'X')
        r = assert(box.execute('WITH UNNEST AS (SELECT 9 AS x) ' ..
                               'SELECT x FROM UNNEST'))
        t.assert_equals(r.rows, {{9}})
        assert(box.execute('SET SESSION "sql_seq_scan" = false'))
        for _, source in ipairs({'UNNEST([1])', 'GENERATE_SERIES(1,1)',
                                 [[JSON_EACH(CAST('{"a":1}' AS JSON))]]}) do
            r = assert(box.execute('SELECT * FROM ' .. source))
            t.assert_equals(#r.rows, 1)
        end
        local _, err = box.execute('SELECT * FROM UNNEST')
        t.assert_str_contains(err.message, 'Scanning is not allowed')
        assert(box.execute('DROP TABLE UNNEST'))
    end)
end

g.test_view_dependencies = function(cg)
    cg.server:exec(function()
        for _, same_name in ipairs({false, true}) do
            if same_name then
                assert(box.execute('CREATE TABLE UNNEST(ID INT PRIMARY KEY)'))
            end
            assert(box.execute('CREATE VIEW V_GENERATE_SERIES AS ' ..
                               'SELECT VALUE FROM UNNEST([1,2])'))
            t.assert_equals(box.execute('SELECT * FROM V_GENERATE_SERIES').rows,
                            {{1}, {2}})
            if same_name then
                assert(box.execute('DROP TABLE UNNEST'))
            end
            assert(box.execute('DROP VIEW V_GENERATE_SERIES'))
        end
        assert(box.execute('CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY,' ..
                           ' A ARRAY)'))
        assert(box.execute('INSERT INTO T_UNNEST_ARG VALUES(1,[1,2])'))
        for _, query in ipairs({
            'SELECT VALUE FROM T_UNNEST_ARG t, UNNEST(t.A)',
            'SELECT VALUE FROM UNNEST((SELECT A FROM T_UNNEST_ARG))',
        }) do
            assert(box.execute('CREATE VIEW V_GENERATE_SERIES AS ' .. query))
            local _, err = box.execute('DROP TABLE T_UNNEST_ARG')
            t.assert(err)
            t.assert_equals(box.execute('SELECT * FROM V_GENERATE_SERIES').rows,
                            {{1}, {2}})
            assert(box.execute('DROP VIEW V_GENERATE_SERIES'))
        end
        assert(box.execute('DROP TABLE T_UNNEST_ARG'))
    end)
end

g.test_estimates_and_overflow = function(cg)
    cg.server:exec(function()
        local cases = {
            {'UNNEST([1,2])', 2}, {'GENERATE_SERIES(1,2)', 2},
            {'GENERATE_SERIES(0x100000000,0x100000001)', 2},
            {'UNNEST([])', 1}, {'GENERATE_SERIES(3,1)', 1},
            {'UNNEST(NULL)', 1}, {'GENERATE_SERIES(-2,2)', 5},
            {[[UNNEST(CAST('[1,2,3]' AS JSON))]], 96},
            {'GENERATE_SERIES(1, ABS(-3))', 960},
        }
        for _, c in ipairs(cases) do
            local r = assert(box.execute('EXPLAIN QUERY PLAN SELECT * FROM ' ..
                                         c[1]))
            t.assert_str_contains(r.rows[1][4], '(~' .. c[2] .. ' row')
        end
        local max = '9223372036854775807'
        local r = assert(box.execute('SELECT * FROM GENERATE_SERIES(' ..
                                     max .. ',' .. max .. ')'))
        t.assert_equals(r.rows, {{9223372036854775807LL}})
        r = assert(box.execute('SELECT * FROM GENERATE_SERIES(-' ..
                               '9223372036854775808,' .. max .. ') LIMIT 1'))
        t.assert_equals(r.rows, {{-9223372036854775808LL}})
        r = assert(box.execute('EXPLAIN QUERY PLAN SELECT * FROM ' ..
                               'GENERATE_SERIES(-9223372036854775808,' ..
                               max .. ')'))
        t.assert_str_contains(r.rows[1][4], 'SCAN TABLE GENERATE_SERIES')
        local _, err = box.execute("SELECT * FROM GENERATE_SERIES(NULL,'bad')")
        t.assert(err) -- An estimate of zero does not remove execution errors.
    end)
end

g.test_evaluation_and_no_flatten = function(cg)
    cg.server:exec(function()
        rawset(_G, 'tf_calls', 0)
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        local stmt = assert(box.prepare('SELECT * FROM ' ..
                                        'GENERATE_SERIES(1, TF_COUNTER())'))
        assert(box.execute('EXPLAIN QUERY PLAN SELECT * FROM ' ..
                           'GENERATE_SERIES(1, TF_COUNTER())'))
        t.assert_equals(_G.tf_calls, 0)
        t.assert_equals(box.execute(stmt.stmt_id).rows, {{1}})
        t.assert_equals(_G.tf_calls, 1)
        t.assert_equals(box.execute(stmt.stmt_id).rows, {{1}, {2}})
        t.assert_equals(_G.tf_calls, 2)
        stmt:unprepare()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1),(2),(3)'))
        rawset(_G, 'tf_calls', 0)
        local r = assert(box.execute([[
            SELECT g.VALUE
            FROM (SELECT TF_COUNTER() AS n FROM T_TFUNC_ARG) AS s,
                 GENERATE_SERIES(1, s.n) AS g
        ]]))
        t.assert_equals(_G.tf_calls, 3)
        t.assert_equals(#r.rows, 6)
        rawset(_G, 'tf_calls', 0)
        r = assert(box.execute([[
            SELECT t.ID, u.VALUE FROM T_TFUNC_ARG t CROSS JOIN
                 GENERATE_SERIES(1,2) x CROSS JOIN
                 UNNEST([CAST(t.ID AS INTEGER) + TF_COUNTER() * 0]) u
            ORDER BY t.ID, x.VALUE
        ]]))
        t.assert_equals(r.rows, {
            {1, 1}, {1, 1}, {2, 2}, {2, 2}, {3, 3}, {3, 3},
        })
        t.assert_equals(_G.tf_calls, 6) -- This plan opens u inside both loops.
        rawset(_G, 'tf_calls', 0)
        r = assert(box.execute([[
            SELECT t.ID, u.VALUE FROM T_TFUNC_ARG t CROSS JOIN
                 UNNEST([TF_COUNTER()]) u ORDER BY t.ID
        ]]))
        t.assert_equals(r.rows, {{1, 1}, {2, 1}, {3, 1}})
        t.assert_equals(_G.tf_calls, 1)
        rawset(_G, 'tf_calls', nil)
    end)
end

g.test_no_automatic_index = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1),(2),(3)'))
        for _, query in ipairs({
            'SELECT u.VALUE FROM T_TFUNC_ARG t CROSS JOIN UNNEST([1,2,3]) u ' ..
            'WHERE u.VALUE=t.ID',
            'SELECT u.VALUE FROM T_TFUNC_ARG t CROSS JOIN UNNEST([t.ID]) u ' ..
            'WHERE u.VALUE=t.ID',
        }) do
            local plan = assert(box.execute('EXPLAIN QUERY PLAN ' .. query))
            for _, row in ipairs(plan.rows) do
                t.assert_not_str_contains(row[4], 'AUTOMATIC')
            end
            local r = assert(box.execute(query))
            t.assert_equals(r.rows, {{1}, {2}, {3}})
        end
    end)
end

g.test_cast_before_materialization = function(cg)
    cg.server:exec(function()
        local cases = {
            {'ARRAY', {10}}, {'MAP', {x = 10}}, {'INTEGER', 10},
        }
        for _, c in ipairs(cases) do
            local inner = 'SELECT CAST(VALUE AS ' .. c[1] .. ') AS v, ' ..
                          'ORDINALITY AS n FROM UNNEST(#a) WITH ORDINALITY ' ..
                          'LIMIT 2'
            local query = 'SELECT ALL s.v FROM (' .. inner .. ') s, ' ..
                          'GENERATE_SERIES(1,1) g ORDER BY s.n'
            local r = assert(box.execute(query, {{['#a'] = {c[2], c[2]}}}))
            t.assert_equals(r.rows, {{c[2]}, {c[2]}})
            r = assert(box.execute('WITH s AS (' .. inner .. ') ' ..
                                   'SELECT ALL s.v FROM s, ' ..
                                   'GENERATE_SERIES(1,1) g ORDER BY s.n',
                                   {{['#a'] = {c[2], c[2]}}}))
            t.assert_equals(r.rows, {{c[2]}, {c[2]}})
        end
        local r = assert(box.execute([[
            SELECT ALL s.v FROM
                (SELECT CAST(VALUE AS JSON) v, ORDINALITY n
                 FROM UNNEST(#a) WITH ORDINALITY LIMIT 2) s,
                GENERATE_SERIES(1,1) g ORDER BY s.n
        ]], {{['#a'] = {{x = 1}, {x = 2}}}}))
        t.assert_equals(tostring(r.rows[1][1]), '{"x": 1}')
        t.assert_equals(tostring(r.rows[2][1]), '{"x": 2}')
        assert(box.execute([=[
            CREATE VIEW V_GENERATE_SERIES AS
                SELECT CAST(VALUE AS ARRAY) v, ORDINALITY n
                FROM UNNEST(CAST([[1],[2]] AS ARRAY)) WITH ORDINALITY LIMIT 2
        ]=]))
        r = assert(box.execute([[
            SELECT ALL v.v FROM V_GENERATE_SERIES v,
                                GENERATE_SERIES(1,1) g ORDER BY v.n
        ]]))
        t.assert_equals(r.rows, {{{1}}, {{2}}})
        local _, err = box.execute([[
            SELECT ALL s.v FROM
                (SELECT VALUE v FROM UNNEST(#a) LIMIT 2) s,
                GENERATE_SERIES(1,1) g
        ]], {{['#a'] = {{1}}}})
        t.assert(err) -- Existing ANY -> SCALAR temporary format is unchanged.
    end)
end

g.test_errors_limit_and_cancel = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local stmt = assert(box.prepare('SELECT * FROM UNNEST(#a)'))
        for _ = 1, 10 do
            local r, err = box.execute(stmt.stmt_id, {{['#a'] = 1}})
            t.assert_equals(r, nil)
            t.assert(err)
            r = assert(box.execute(stmt.stmt_id, {{['#a'] = {1, 2}}}))
            t.assert_equals(r.rows, {{1}, {2}})
        end
        stmt:unprepare()
        for _ = 1, 10 do
            local r = assert(box.execute('SELECT * FROM ' ..
                'GENERATE_SERIES(1,9223372036854775807) LIMIT 1'))
            t.assert_equals(r.rows, {{1}})
            local _, err = box.execute('SELECT COUNT(*) FROM ' ..
                'GENERATE_SERIES(1,9223372036854775807)', {},
                {{sql_vdbe_max_steps = 100}})
            t.assert_str_contains(err.message, 'max executed vdbe opcodes')
        end
        rawset(_G, 'tf_entered', fiber.channel(1))
        box.schema.func.create('TF_WAIT', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_entered:put(true)
                require('fiber').sleep(1000)
                return 1
            end]],
        })
        for _, query in ipairs({
            'SELECT TF_WAIT() FROM GENERATE_SERIES(1,1000000)',
            -- Cancel with the dependent group's coroutine suspended.
            'SELECT TF_WAIT() FROM GENERATE_SERIES(1,1) a, ' ..
            '(GENERATE_SERIES(1,1000000+a.VALUE) b ' ..
            'JOIN UNNEST([10]) c ON true)',
        }) do
            local result = fiber.channel(1)
            local f = fiber.create(function()
                local ok, r, err = pcall(box.execute, query)
                result:put({ok, r, err})
            end)
            t.assert(_G.tf_entered:get(5))
            f:cancel()
            local r = result:get(5)
            t.assert(r)
            t.assert(not r[1] or r[3] ~= nil)
            t.assert_equals(box.execute('SELECT * FROM UNNEST([1])').rows,
                            {{1}})
        end
        rawset(_G, 'tf_entered', nil)
    end)
end

g.test_extended_types_and_containers = function(cg)
    cg.server:exec(function()
        local datetime = require('datetime')
        local dt = datetime.new({year = 2026, month = 1, day = 1})
        local interval = datetime.interval.new({day = 1})
        for _, c in ipairs({{'DATETIME', dt}, {'INTERVAL', interval}}) do
            local r = assert(box.execute('SELECT * FROM ' ..
                'UNNEST([CAST(#v AS ' .. c[1] .. ')])', {{['#v'] = c[2]}}))
            t.assert_equals(r.metadata[1].type, c[1]:lower())
            t.assert_equals(r.rows, {{c[2]}})
        end
        local r = assert(box.execute('SELECT * FROM ' ..
            'UNNEST([CASE WHEN true THEN 1.5 ELSE 2e0 END])'))
        -- CASE already converts the selected value in the SQL engine.
        t.assert_equals(r.metadata[1].type, 'double')
        t.assert_equals(r.rows, {{1.5}})
        for _, source in ipairs({'JSON_EACH(NULL)',
                                 [[JSON_EACH(CAST('{}' AS JSON))]],
                                 [[UNNEST(CAST('[]' AS JSON))]]}) do
            t.assert_equals(box.execute('SELECT * FROM ' .. source).rows, {})
        end
        for _, source in ipairs({"JSON_EACH({'x':1})",
                                 'JSON_EACH(JSON_NULL())',
                                 'GENERATE_SERIES(1.5,2)',
                                 'GENERATE_SERIES(0,9223372036854775808)'}) do
            local _, err = box.execute('SELECT * FROM ' .. source)
            t.assert(err)
        end
        r = assert(box.execute([[
            SELECT KEY, VALUE FROM JSON_EACH(CAST('{"a":null,"b":[1]}' AS JSON))
            ORDER BY KEY
        ]]))
        t.assert_equals(r.rows[1][1], 'a')
        t.assert_equals(tostring(r.rows[1][2]), 'null')
        t.assert_not_equals(r.rows[1][2], box.NULL)
        t.assert_equals(tostring(r.rows[2][2]), '[1]')
        local _, err = box.execute('SELECT * FROM UNNEST([1]) WITH wrong')
        t.assert_str_contains(err.message, 'expected ORDINALITY')
    end)
end

g.test_view_recovery = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY,' ..
                           ' A ARRAY)'))
        assert(box.execute('INSERT INTO T_UNNEST_ARG VALUES(1,[1,2])'))
        assert(box.execute('CREATE VIEW V_GENERATE_SERIES AS ' ..
                           'SELECT VALUE FROM T_UNNEST_ARG t, UNNEST(t.A)'))
        box.snapshot()
    end)
    cg.server:restart()
    cg.server:exec(function()
        assert(box.execute('SET SESSION "sql_seq_scan" = true'))
        t.assert_equals(box.execute('SELECT * FROM V_GENERATE_SERIES').rows,
                        {{1}, {2}})
        local _, err = box.execute('DROP TABLE T_UNNEST_ARG')
        t.assert(err)
        assert(box.execute('DROP VIEW V_GENERATE_SERIES'))
        assert(box.execute('DROP TABLE T_UNNEST_ARG'))
    end)
end

g.test_insert_function_with_same_name_table = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE UNNEST(VALUE INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO UNNEST VALUES(99)'))
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(VALUE INT PRIMARY KEY)'))
        local r = assert(box.execute('INSERT INTO T_TFUNC_ARG ' ..
                                     'SELECT * FROM UNNEST([1,2])'))
        t.assert_equals(r.row_count, 2)
        t.assert_equals(box.execute('SELECT * FROM T_TFUNC_ARG ' ..
                                    'ORDER BY VALUE').rows, {{1}, {2}})
        t.assert_equals(box.execute('SELECT * FROM UNNEST').rows, {{99}})
    end)
end

g.test_function_in_same_name_cte = function(cg)
    cg.server:exec(function()
        local r = assert(box.execute([[
            WITH UNNEST(VALUE) AS (
                SELECT 0 UNION ALL SELECT VALUE FROM UNNEST([1,2])
            ) SELECT * FROM UNNEST LIMIT 4
        ]]))
        t.assert_equals(r.rows, {{0}, {1}, {2}})
    end)
end

g.test_parameters_in_array_constructor = function(cg)
    local conn = cg.server.net_box
    for _, param in ipairs({'?', ':a', '$1', '@a', '#a'}) do
        local stmt = conn:prepare('SELECT * FROM UNNEST([' .. param .. '])')
        t.assert_equals(stmt.metadata, {{name = 'VALUE', type = 'any'}})
        for _, value in ipairs({1, 'x', {1, 2}}) do
            local r = conn:execute(stmt.stmt_id, {value})
            t.assert_equals(r.metadata, stmt.metadata)
            t.assert_equals(r.rows, {{value}})
        end
        conn:unprepare(stmt.stmt_id)
    end
    for _, case in ipairs({
        {'[@a,@b]', {1, 'x'}, {{1}, {'x'}}, 'any'},
        {'[#a,1]', {'x'}, {{'x'}, {1}}, 'any'},
        {'[CAST(#a AS INTEGER)]', {2}, {{2}}, 'integer'},
    }) do
        local stmt = conn:prepare('SELECT * FROM UNNEST(' .. case[1] .. ')')
        t.assert_equals(stmt.metadata, {{name = 'VALUE', type = case[4]}})
        local r = conn:execute(stmt.stmt_id, case[2])
        t.assert_equals(r.metadata, stmt.metadata)
        t.assert_equals(r.rows, case[3])
        conn:unprepare(stmt.stmt_id)
    end
end

g.test_outer_result_alias_is_not_visible = function(cg)
    cg.server:exec(function()
        for _, query in ipairs({
            'SELECT [1,2] AS a WHERE EXISTS (SELECT * FROM UNNEST(a))',
            'SELECT 2 AS n WHERE EXISTS ' ..
            '(SELECT 1 FROM GENERATE_SERIES(1,n))',
        }) do
            local stmt, err = box.prepare(query)
            t.assert_equals(stmt, nil)
            t.assert(err, query)
        end
    end)
end

-- The arguments of a table function in a subquery can read the columns of
-- an outer query. The function starts again for each outer row.
g.test_outer_query_columns_in_args = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY,' ..
                           ' A ARRAY)'))
        assert(box.execute('INSERT INTO T_UNNEST_ARG VALUES' ..
                           '(1,[1]),(2,[]),(3,[7,8,9])'))
        for _, case in ipairs({
            {[[SELECT t.ID FROM T_UNNEST_ARG t
               WHERE EXISTS (SELECT 1 FROM UNNEST(t.A))]],
             {{1}, {3}}},
            {[[SELECT t.ID, (SELECT COUNT(*) FROM GENERATE_SERIES(1, t.ID))
               FROM T_UNNEST_ARG t]],
             {{1, 1}, {2, 2}, {3, 3}}},
            {[[SELECT t.ID FROM T_UNNEST_ARG t
               WHERE t.ID IN (SELECT VALUE FROM GENERATE_SERIES(t.ID, 2))]],
             {{1}, {2}}},
            -- An outer column and a preceding FROM item in one call.
            {[[SELECT t.ID, (SELECT COUNT(*) FROM T_UNNEST_ARG x,
                             GENERATE_SERIES(x.ID, t.ID))
               FROM T_UNNEST_ARG t]],
             {{1, 1}, {2, 3}, {3, 6}}},
            -- A join group and two levels of subqueries.
            {[[SELECT t.ID, (SELECT COUNT(*) FROM
                             (GENERATE_SERIES(1, t.ID) g
                              JOIN UNNEST(t.A) u ON true))
               FROM T_UNNEST_ARG t]],
             {{1, 1}, {2, 0}, {3, 9}}},
            {[[SELECT t.ID,
                      (SELECT (SELECT COUNT(*) FROM GENERATE_SERIES(1, t.ID)))
               FROM T_UNNEST_ARG t]],
             {{1, 1}, {2, 2}, {3, 3}}},
            -- The outer query is a table function.
            {[[SELECT g.VALUE FROM GENERATE_SERIES(1, 3) g
               WHERE EXISTS (SELECT 1 FROM GENERATE_SERIES(1, g.VALUE) h
                             WHERE h.VALUE = 2)]],
             {{2}, {3}}},
        }) do
            local stmt = assert(box.prepare(case[1]))
            for _ = 1, 2 do
                t.assert_equals(stmt:execute().rows, case[2], case[1])
            end
            stmt:unprepare()
        end
        -- A FROM subquery still cannot read the item on its left.
        local _, err = box.execute([[
            SELECT * FROM T_UNNEST_ARG t, (SELECT * FROM UNNEST(t.A)) s
        ]])
        t.assert_equals(err.message,
                        "Field 'A' was not found in space 'T' format")
    end)
end

g.test_group_keeps_ordinary_name_scope = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('CREATE TABLE T_UNNEST_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('CREATE TABLE T_TFUNC_A(K INT PRIMARY KEY)'))
        assert(box.execute('CREATE TABLE T_TFUNC_B(K INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1)'))
        assert(box.execute('INSERT INTO T_UNNEST_ARG VALUES(2)'))
        assert(box.execute('INSERT INTO T_TFUNC_A VALUES(1)'))
        assert(box.execute('INSERT INTO T_TFUNC_B VALUES(1)'))
        local query = [[
            SELECT * FROM T_TFUNC_ARG o WHERE EXISTS (
                SELECT 1 FROM T_UNNEST_ARG t JOIN
                (T_TFUNC_A a JOIN T_TFUNC_B b ON b.k=id) ON true
            )
        ]]
        local r = assert(box.execute(query))
        t.assert_equals(r.rows, {{1}})
        local plan = assert(box.execute('EXPLAIN QUERY PLAN ' .. query))
        for _, row in ipairs(plan.rows) do
            t.assert_not_str_contains(row[4], 'SCAN SUBQUERY')
        end
        for _, row in ipairs(box.execute('EXPLAIN (opcode) ' .. query).rows) do
            t.assert_not_equals(row[2]:match('^%s*(.-)%s*$'), 'OpenTEphemeral')
        end
        local stmt, err = box.prepare([[
            SELECT * FROM T_UNNEST_ARG t,
                (T_TFUNC_A a JOIN (SELECT t.id AS z) s ON true)
        ]])
        t.assert_equals(stmt, nil)
        t.assert(err)
    end)
end

g.test_outer_correlated_subquery_materialization = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(K INT PRIMARY KEY)'))
        assert(box.execute('CREATE TABLE T_TFUNC_A(K INT PRIMARY KEY)'))
        assert(box.execute('CREATE TABLE T_TFUNC_B(K INT PRIMARY KEY, Y INT)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1),(2)'))
        assert(box.execute('INSERT INTO T_TFUNC_A VALUES(1),(2),(3)'))
        assert(box.execute('INSERT INTO T_TFUNC_B VALUES(1,7),(2,8)'))
        rawset(_G, 'tf_count', 0)
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            param_list = {'integer'},
            body = [[function(y)
                _G.tf_count = _G.tf_count + 1
                return y
            end]],
        })
        local r = assert(box.execute([[
            SELECT (SELECT COUNT(*) FROM T_TFUNC_A t2 CROSS JOIN
                (SELECT DISTINCT TF_COUNTER(y) AS y FROM T_TFUNC_B t3
                 WHERE t3.k=t1.k) s)
            FROM T_TFUNC_ARG t1
        ]]))
        t.assert_equals(r.rows, {{3}, {3}})
        t.assert_equals(rawget(_G, 'tf_count'), 2)
        rawset(_G, 'tf_count', nil)
    end)
end

g.test_grouped_join_with_or_indexes = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG' ..
                           '(ID INT PRIMARY KEY, N INT)'))
        assert(box.execute('CREATE INDEX idx ON T_TFUNC_ARG(N)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1,2),(2,1)'))
        for _, condition in ipairs({'t.ID=1 OR t.N=1',
                                     't.N=1 OR t.N>1', 't.N>0'}) do
            for _, join in ipairs({',', 'LEFT JOIN'}) do
                local query = [[
                    SELECT t.ID, g.VALUE FROM T_TFUNC_ARG t %s
                        (GENERATE_SERIES(1,t.N) g
                         JOIN GENERATE_SERIES(1,1) h ON true)
                    %s WHERE %s ORDER BY t.ID, g.VALUE
                ]]
                local on = join == ',' and '' or 'ON true'
                local r = assert(box.execute(query:format(join, on, condition)))
                t.assert_equals(r.rows, {{1, 1}, {1, 2}, {2, 1}})
            end
        end
    end)
end

g.test_group_keeps_independent_arguments = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG' ..
                           '(ID INT PRIMARY KEY, N INT)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1,1),(2,1),(3,1)'))
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        for _, sources in ipairs({
            'T_TFUNC_ARG t, UNNEST([TF_COUNTER()]) u ' ..
            'JOIN GENERATE_SERIES(1,t.N) g ON true',
            'T_TFUNC_ARG t, (UNNEST([TF_COUNTER()]) u ' ..
            'JOIN GENERATE_SERIES(1,t.N) g ON true)',
            'T_TFUNC_ARG t LEFT JOIN (UNNEST([TF_COUNTER()]) u ' ..
            'JOIN GENERATE_SERIES(1,t.N) g ON true) ON true',
            'T_TFUNC_ARG t LEFT JOIN ((UNNEST([TF_COUNTER()]) u ' ..
            'JOIN GENERATE_SERIES(1,t.N) g ON true) ' ..
            'JOIN GENERATE_SERIES(1,1) h ON true) ON true',
            'T_TFUNC_ARG t, ((SELECT VALUE FROM UNNEST([TF_COUNTER()])) u ' ..
            'JOIN GENERATE_SERIES(1,t.N) g ON true)',
        }) do
            rawset(_G, 'tf_calls', 0)
            local stmt = assert(box.prepare('SELECT t.ID, u.VALUE FROM ' ..
                                            sources .. ' ORDER BY t.ID'))
            t.assert_equals(_G.tf_calls, 0)
            for n = 1, 2 do
                local r = assert(box.execute(stmt.stmt_id))
                t.assert_equals(r.rows, {{1, n}, {2, n}, {3, n}})
                t.assert_equals(_G.tf_calls, n)
            end
            stmt:unprepare()
        end
        rawset(_G, 'tf_calls', nil)
    end)
end

g.test_argument_initialization_in_or_subqueries = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG' ..
                           '(ID INT PRIMARY KEY, N INT, X INT)'))
        assert(box.execute('CREATE INDEX tf_n ON T_TFUNC_ARG(N)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1,1,5),(2,2,5)'))
        for _, subquery in ipairs({
            'SELECT VALUE FROM UNNEST([5])',
            'SELECT u.VALUE FROM (UNNEST([5]) u ' ..
                'JOIN GENERATE_SERIES(1,1) h ON true)',
            -- Keep a dependent group as a reusable subroutine.
            'SELECT u.VALUE FROM GENERATE_SERIES(1,1) g LEFT JOIN ' ..
                '(UNNEST([5]) u JOIN GENERATE_SERIES(1,g.VALUE) h ' ..
                'ON true) ON true',
            'SELECT u.VALUE FROM GENERATE_SERIES(1,1) g LEFT JOIN ' ..
                '((UNNEST([5]) u JOIN GENERATE_SERIES(1,g.VALUE) h ' ..
                'ON true) JOIN GENERATE_SERIES(1,1) j ON true) ON true',
        }) do
            -- The first OR branch must not execute its scalar subquery.
            local query = 'SELECT ID FROM T_TFUNC_ARG ' ..
                'WHERE (ID=10 OR N=2) AND X=(' .. subquery .. ')'
            local plan = assert(box.execute('EXPLAIN QUERY PLAN ' .. query))
            local scans = 0
            local index_used = false
            for _, row in ipairs(plan.rows) do
                if row[4]:find('SEARCH TABLE T_TFUNC_ARG', 1, true) then
                    scans = scans + 1
                    index_used = index_used or row[4]:find('TF_N', 1, true)
                end
            end
            t.assert_equals(scans, 2)
            t.assert(index_used)
            local stmt = assert(box.prepare(query))
            for _ = 1, 2 do
                t.assert_equals(box.execute(stmt.stmt_id).rows, {{2}})
            end
            stmt:unprepare()
        end
    end)
end

g.test_distinct_left_join_keeps_function = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1)'))
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        for _, distinct in ipairs({'', 'DISTINCT '}) do
            local query = 'SELECT ' .. distinct .. 't.ID FROM T_TFUNC_ARG t ' ..
                'LEFT JOIN UNNEST(%s) u ON true'
            local r, err = box.execute(query:format('1'))
            t.assert_equals(r, nil)
            t.assert_str_contains(err.message, 'unnest expects array argument')
            rawset(_G, 'tf_calls', 0)
            r = assert(box.execute(query:format('[TF_COUNTER()]')))
            t.assert_equals(r.rows, {{1}})
            t.assert_equals(_G.tf_calls, 1)
        end
        rawset(_G, 'tf_calls', nil)
    end)
end

g.test_distinct_left_join_keeps_group = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG' ..
                           '(ID INT PRIMARY KEY, N INT)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1,1)'))
        assert(box.execute('CREATE TABLE T_TFUNC_A(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_A VALUES(1)'))
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        local cases = {
            {'(UNNEST(%s) u JOIN GENERATE_SERIES(1,1) g ON true)', 't.N'},
            -- The function can be independent inside a dependent group.
            {'(UNNEST(%s) u JOIN GENERATE_SERIES(1,t.N) g ON true)', '1'},
            -- All functions are inside the nested dependent group.
            {'((UNNEST(%s) u JOIN T_TFUNC_A a ON true) ' ..
             'JOIN T_TFUNC_A b ON true)', 't.N'},
        }
        for _, case in ipairs(cases) do
            for _, distinct in ipairs({'', 'DISTINCT '}) do
                local prefix = 'SELECT ' .. distinct ..
                    't.ID FROM T_TFUNC_ARG t LEFT JOIN '
                local query = prefix .. case[1]:format(case[2]) .. ' ON true'
                local r, err = box.execute(query)
                t.assert_equals(r, nil, query)
                t.assert_str_contains(err.message,
                                      'unnest expects array argument')
                local arg = '[TF_COUNTER() + ' .. case[2] .. ']'
                query = prefix .. case[1]:format(arg) .. ' ON true'
                local stmt = assert(box.prepare(query))
                for _ = 1, 2 do
                    rawset(_G, 'tf_calls', 0)
                    r = assert(box.execute(stmt.stmt_id))
                    t.assert_equals(r.rows, {{1}}, query)
                    t.assert_equals(_G.tf_calls, 1, query)
                end
                stmt:unprepare()
            end
        end
        rawset(_G, 'tf_calls', nil)
    end)
end

g.test_unary_parameters_in_array_constructor = function(cg)
    local conn = cg.server.net_box
    for _, param in ipairs({'?', ':a', '$1', '@a', '#a'}) do
        for _, sign in ipairs({'+', '-'}) do
            for _, cast in ipairs({false, true}) do
                local expr = cast and 'CAST(' .. param .. ' AS INTEGER)' or
                             param
                local stmt = conn:prepare('SELECT * FROM UNNEST([' ..
                                          sign .. expr .. '])')
                t.assert_equals(stmt.metadata, {{
                    name = 'VALUE', type = cast and 'integer' or 'any',
                }})
                for value = 1, 2 do
                    local r = conn:execute(stmt.stmt_id, {value})
                    t.assert_equals(r.metadata, stmt.metadata)
                    t.assert_equals(r.rows, {{sign == '-' and -value or value}})
                end
                conn:unprepare(stmt.stmt_id)
            end
        end
    end
end

g.test_mixed_arguments_follow_call_dependency = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG' ..
                           '(ID INT PRIMARY KEY, N INT)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1,1),(2,2),(3,3)'))
        rawset(_G, 'tf_calls', 0)
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        local query = [[
            SELECT t.ID, g.VALUE
            FROM T_TFUNC_ARG t, GENERATE_SERIES(TF_COUNTER(), t.N) g
            ORDER BY t.ID, g.VALUE
        ]]
        local plan = assert(box.execute('EXPLAIN QUERY PLAN ' .. query))
        t.assert_str_contains(plan.rows[1][4], 'SCAN TABLE T_TFUNC_ARG')
        t.assert_str_contains(plan.rows[2][4], 'SCAN TABLE GENERATE_SERIES')
        -- This plan scans the primary index forwards and opens g per row.
        local r = assert(box.execute(query))
        t.assert_equals(r.rows, {{1, 1}, {2, 2}, {3, 3}})
        t.assert_equals(_G.tf_calls, 3)
        local stmt = assert(box.prepare([[
            SELECT t.ID, g.VALUE FROM T_TFUNC_ARG t,
                (GENERATE_SERIES(TF_COUNTER(), t.N) g
                 JOIN UNNEST([10]) u ON true)
            ORDER BY t.ID, g.VALUE
        ]]))
        for _ = 1, 2 do
            rawset(_G, 'tf_calls', 0)
            t.assert_equals(stmt:execute().rows, {{1, 1}, {2, 2}, {3, 3}})
            t.assert_equals(_G.tf_calls, 3)
        end
        stmt:unprepare()
        rawset(_G, 'tf_calls', nil)
    end)
end

g.test_scalar_subquery_cache_in_arguments = function(cg)
    cg.server:exec(function()
        assert(box.execute('CREATE TABLE T_TFUNC_ARG(ID INT PRIMARY KEY)'))
        assert(box.execute('INSERT INTO T_TFUNC_ARG VALUES(1),(2),(3)'))
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
        for _, case in ipairs({
            {'TF_COUNTER()', 3, false}, {'(SELECT TF_COUNTER())', 1, false},
            {'TF_COUNTER()', 3, true}, {'(SELECT TF_COUNTER())', 1, true},
        }) do
            rawset(_G, 'tf_calls', 0)
            local source = 'UNNEST([' .. case[1] .. ']) u'
            if case[3] then
                source = 'GENERATE_SERIES(1,1) x, (' .. source ..
                    ' JOIN GENERATE_SERIES(1,x.VALUE) g ON true)'
            end
            local query = [[
                SELECT t.ID, (SELECT SUM(u.VALUE)
                              FROM %s WHERE t.ID>0)
                FROM T_TFUNC_ARG t ORDER BY t.ID
            ]]
            local stmt = assert(box.prepare(query:format(source)))
            t.assert_equals(_G.tf_calls, 0)
            for run = 1, 2 do
                local r = assert(box.execute(stmt.stmt_id))
                local expected = {}
                for id = 1, 3 do
                    local value = case[2] == 1 and run or 3 * (run - 1) + id
                    expected[id] = {id, value}
                end
                t.assert_equals(r.rows, expected)
                t.assert_equals(_G.tf_calls, run * case[2])
            end
            stmt:unprepare()
        end
        rawset(_G, 'tf_calls', nil)
    end)
end
