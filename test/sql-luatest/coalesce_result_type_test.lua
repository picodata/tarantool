local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'coalesce-result-type'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_result_types = function()
    g.server:exec(function()
        local function assert_result(sql, expected_type, expected_rows, params)
            local result
            if params == nil then
                result = box.execute(sql)
            else
                result = box.execute(sql, params)
            end
            t.assert_equals(result.metadata[1].type, expected_type)
            t.assert_equals(result.rows, expected_rows)
        end

        assert_result([[SELECT COALESCE(NULL, 1, 2);]], 'integer', {{1}})
        assert_result([[SELECT IFNULL(NULL, 'a');]], 'string', {{'a'}})
        assert_result([[SELECT COALESCE(-1, 1.5, 2e0);]], 'double', {{-1}})
        assert_result([[SELECT COALESCE(1, 'a');]], 'scalar', {{1}})
        assert_result([[SELECT COALESCE(NULL, [1], [2]);]], 'array',
                      {{{1}}})
        assert_result([[SELECT COALESCE(NULL, {1: 1}, {2: 2});]], 'map',
                      {{{[1] = 1}}})
        assert_result([[SELECT COALESCE(NULL, 1, [1]);]], 'any', {{1}})
        assert_result([[SELECT COALESCE(NULL, NULL);]], 'any', {{box.NULL}})
        assert_result([[SELECT COALESCE(?, 1);]], 'any', {{2}}, {2})
        assert_result([[SELECT COALESCE(?, ?);]], 'any', {{1}},
                      {box.NULL, 1})

        local sql = [[SELECT TYPEOF(COALESCE(-1, 1.5, 2e0));]]
        t.assert_equals(box.execute(sql).rows, {{'integer'}})
        sql = [[SELECT TYPEOF(COALESCE(NULL, 1, [1]));]]
        t.assert_equals(box.execute(sql).rows, {{'integer'}})
        sql = [[SELECT TYPEOF(COALESCE(?, ?));]]
        t.assert_equals(box.execute(sql, {box.NULL, 1}).rows, {{'integer'}})
        sql = [[SELECT TYPEOF(COALESCE(?, 1, [1]));]]
        t.assert_equals(box.execute(sql, {box.NULL}).rows, {{'integer'}})
    end)
end

g.test_selected_value_types = function()
    g.server:exec(function()
        local decimal = require('decimal')
        -- Arguments, value, runtime type, metadata type.
        local cases = {
            {'1, 1.5', 1, 'integer', 'decimal'},
            {'1, 2e0', 1, 'integer', 'double'},
            {'1.5, 2e0', decimal.new('1.5'), 'decimal', 'double'},
            {'2e0, 1', 2, 'double', 'double'},
            {[[1, 'a']], 1, 'integer', 'scalar'},
            {[['a', 1]], 'a', 'string', 'scalar'},
            {'1, [1]', 1, 'integer', 'any'},
            {'[1], 1', {1}, 'array', 'any'},
            {'{1: 1}, 1', {[1] = 1}, 'map', 'any'},
        }
        for _, func in ipairs({'COALESCE', 'IFNULL'}) do
            for _, case in ipairs(cases) do
                local expr = ('%s(%s)'):format(func, case[1])
                local sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
                local result = assert(box.execute(sql))
                t.assert_equals(result.rows, {{case[2], case[3]}}, sql)
                t.assert_equals(result.metadata[1].type, case[4], sql)
            end
        end
    end)
end

g.test_selected_metatypes = function()
    g.server:exec(function()
        for _, func in ipairs({'COALESCE', 'IFNULL'}) do
            for _, metatype in ipairs({'ANY', 'SCALAR', 'NUMBER'}) do
                local cast = ('CAST(1 AS %s)'):format(metatype)
                local cases = {
                    {cast .. ', NULL', metatype:lower()},
                    {'NULL, ' .. cast, metatype:lower()},
                    {'1, ' .. cast, 'integer'},
                }
                for _, case in ipairs(cases) do
                    local expr = ('%s(%s)'):format(func, case[1])
                    local sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
                    local result = assert(box.execute(sql))
                    t.assert_equals(result.rows, {{1, case[2]}}, sql)
                    t.assert_equals(result.metadata[1].type,
                                    metatype:lower(), sql)
                end
            end
        end
    end)
end

g.test_parameter_expressions = function()
    g.server:exec(function()
        -- Expression, non-NULL parameters, metadata type, optional fallback.
        local cases = {
            {'+?', {7}, 'any'},
            {'-?', {7}, 'any'},
            {'~?', {7}, 'any'},
            {'NOT ?', {true}, 'boolean', false},
        }
        for _, op in ipairs({'+', '-', '*', '/', '%', '&', '|', '<<', '>>'}) do
            table.insert(cases, {'? ' .. op .. ' 2', {7}, 'integer'})
            table.insert(cases, {'? ' .. op .. ' ?', {7, 2}, 'scalar'})
        end
        for _, op in ipairs({'+', '-', '*', '/'}) do
            table.insert(cases, {'? ' .. op .. ' 2', {7.5}, 'integer'})
            table.insert(cases, {'? ' .. op .. ' ?', {7.5, 2}, 'scalar'})
        end
        for _, case in ipairs(cases) do
            local nulls = {}
            for i = 1, #case[2] do
                nulls[i] = box.NULL
            end
            local fallback = 0
            if case[4] == false then
                fallback = false
            end
            local fallback_sql = case[4] == false and 'FALSE' or '0'
            for _, params in ipairs({case[2], nulls}) do
                -- Each expression occurs twice: as a value and in TYPEOF.
                local bindings = {}
                for _ = 1, 2 do
                    for _, value in ipairs(params) do
                        table.insert(bindings, value)
                    end
                end
                local sql = ('SELECT %s, TYPEOF(%s);'):format(case[1], case[1])
                local expected = assert(box.execute(sql, bindings)).rows
                if expected[1][1] == box.NULL then
                    local ty = case[4] == false and 'boolean' or 'integer'
                    expected = {{fallback, ty}}
                end
                for _, func in ipairs({'COALESCE', 'IFNULL'}) do
                    local expr = ('%s(%s, %s)'):format(func, case[1],
                                                      fallback_sql)
                    sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
                    local result = assert(box.execute(sql, bindings))
                    t.assert_equals(result.rows, expected, sql)
                    t.assert_equals(result.metadata[1].type, case[3], sql)
                end
            end
        end
    end)
end

g.test_prepared_runtime_type = function()
    g.server:exec(function()
        local cases = {
            {box.NULL, 1, 1, 'integer'},
            {2.5, box.NULL, 2.5, 'double'},
            {box.NULL, 'a', 'a', 'string'},
            {box.NULL, box.NULL, box.NULL, 'NULL'},
            {7, box.NULL, 7, 'integer'},
        }
        for _, func in ipairs({'COALESCE', 'IFNULL'}) do
            local expr = ('%s(?, ?)'):format(func)
            local sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
            local stmt = assert(box.prepare(sql))
            t.assert_equals(stmt.metadata[1].type, 'any')
            for _, case in ipairs(cases) do
                local result = assert(stmt:execute({case[1], case[2],
                                                    case[1], case[2]}))
                t.assert_equals(result.rows, {{case[3], case[4]}}, sql)
                t.assert_equals(result.metadata[1].type, 'any', sql)
            end
            stmt:unprepare()
        end
    end)
end

g.test_bound_parameters_keep_runtime_type = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE "coalesce_bound"(
            "id" INTEGER PRIMARY KEY, "value" INTEGER);]])

        box.execute([[INSERT INTO "coalesce_bound" VALUES
            (1, COALESCE(?, ?)), (2, IFNULL(?, ?)),
            (3, COALESCE(COALESCE(NULL, NULL), ?)),
            (4, COALESCE(?, COALESCE(NULL, NULL))),
            (5, IFNULL(IFNULL(NULL, NULL), ?)),
            (6, IFNULL(?, IFNULL(NULL, NULL)));]],
            {box.NULL, 99, box.NULL, 100, 101, 102, 103, 104})

        local result = box.execute(
            [[SELECT * FROM "coalesce_bound" ORDER BY "id";]])
        t.assert_equals(result.rows, {
            {1, 99}, {2, 100}, {3, 101}, {4, 102}, {5, 103}, {6, 104},
        })

        box.execute([[UPDATE "coalesce_bound"
                      SET "value" = COALESCE(? + ?, ?) WHERE "id" = 1;]],
                    {42, 1, box.NULL})
        result = box.execute([[SELECT "value" FROM "coalesce_bound"
                               WHERE "id" = 1;]])
        t.assert_equals(result.rows, {{43}})

        box.execute([[INSERT INTO "coalesce_bound" VALUES
            (7, COALESCE(+?, 0)), (8, IFNULL(-?, 0)),
            (9, COALESCE(1, CAST(2 AS ANY)));]], {7, 8})
        result = box.execute([[SELECT * FROM "coalesce_bound"
                               WHERE "id" >= 7 ORDER BY "id";]])
        t.assert_equals(result.rows, {{7, 7}, {8, -8}, {9, 1}})

        local _, err = box.execute(
            [[INSERT INTO "coalesce_bound" VALUES (10, COALESCE(?, ?));]],
            {box.NULL, 'not an integer'})
        local message =
            [[can not convert string('not an integer') to integer]]
        t.assert_str_contains(err.message, message)

        for _, func in ipairs({'COALESCE', 'IFNULL'}) do
            local sql = ([[INSERT INTO "coalesce_bound"
                VALUES (10, %s(CAST(1 AS ANY), 0));]]):format(func)
            _, err = box.execute(sql)
            t.assert_str_contains(err.message,
                                  'can not convert any(1) to integer')
        end

        box.execute([[DROP TABLE "coalesce_bound";]])
    end)
end

g.test_coalesce_runtime_type = function()
    g.server:exec(function()
        local sql = [[SELECT TYPEOF(COALESCE(COALESCE(?, 1), 2));]]
        t.assert_equals(box.execute(sql, {box.NULL}).rows, {{'integer'}}, sql)

        sql = [[SELECT TYPEOF(COALESCE(COALESCE(?, NULL), NULL));]]
        t.assert_equals(box.execute(sql, {99}).rows, {{'integer'}}, sql)

        sql = [[SELECT TYPEOF(IFNULL((SELECT ?), 1));]]
        t.assert_equals(box.execute(sql, {box.NULL}).rows, {{'integer'}}, sql)
    end)
end

g.test_nested_null_bound_runtime_type = function()
    g.server:exec(function()
        local expressions = {
            [[COALESCE(COALESCE(NULL, NULL), ?)]],
            [[COALESCE(?, COALESCE(NULL, NULL))]],
            [[IFNULL(IFNULL(NULL, NULL), ?)]],
            [[IFNULL(?, IFNULL(NULL, NULL))]],
        }
        for _, expr in ipairs(expressions) do
            local sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
            local result = box.execute(sql, {99, 99})
            t.assert_equals(result.rows, {{99, 'integer'}}, sql)
            t.assert_equals(result.metadata[1].type, 'any', sql)

            result = box.execute(sql, {box.NULL, box.NULL})
            t.assert_equals(result.rows, {{box.NULL, 'NULL'}}, sql)
            t.assert_equals(result.metadata[1].type, 'any', sql)
        end
    end)
end

g.test_nested_null_known_types = function()
    g.server:exec(function()
        local cases = {
            {[[COALESCE(COALESCE(NULL, NULL), 1)]], 'integer'},
            {[[COALESCE(1, COALESCE(NULL, NULL))]], 'integer'},
            {[[COALESCE(1, COALESCE(NULL, NULL), [1])]], 'integer'},
            {[[COALESCE(COALESCE(NULL, NULL), CAST(1 AS ANY))]], 'any'},
        }
        for _, case in ipairs(cases) do
            local sql = ('SELECT %s, TYPEOF(%s);'):format(case[1], case[1])
            local result = box.execute(sql)
            t.assert_equals(result.rows, {{1, case[2]}}, sql)
            t.assert_equals(result.metadata[1].type, 'any', sql)
        end
    end)
end

g.test_only_null_arguments = function()
    g.server:exec(function()
        local expressions = {
            [[COALESCE(NULL, NULL)]],
            [[IFNULL(NULL, NULL)]],
            [[COALESCE(COALESCE(NULL, NULL), NULL)]],
            [[IFNULL(NULL, IFNULL(NULL, NULL))]],
        }
        for _, expr in ipairs(expressions) do
            local sql = ('SELECT %s, TYPEOF(%s);'):format(expr, expr)
            local result = box.execute(sql)
            t.assert_equals(result.rows, {{box.NULL, 'NULL'}}, sql)
            t.assert_equals(result.metadata[1].type, 'any', sql)
        end
    end)
end

g.test_numeric_functions = function()
    g.server:exec(function()
        local result = box.execute([[SELECT ABS(COALESCE(1, 0));]])
        t.assert_equals(result.metadata[1].type, 'integer')
        t.assert_equals(result.rows, {{1}})

        result = box.execute([[SELECT ABS(IFNULL(1, 0));]])
        t.assert_equals(result.metadata[1].type, 'integer')
        t.assert_equals(result.rows, {{1}})

        -- The enclosing function still applies its own argument types.
        result = box.execute([[SELECT ABS(COALESCE(-1, 2e0)),
                                      TYPEOF(ABS(COALESCE(-1, 2e0)));]])
        t.assert_equals(result.metadata[1].type, 'double')
        t.assert_equals(result.rows, {{1, 'double'}})

        result = box.execute([[SELECT ROUND(COALESCE(1.5, 0));]])
        t.assert_equals(result.metadata[1].type, 'decimal')
        t.assert_equals(result.rows, {{2}})

        box.execute([[CREATE TABLE "coalesce_values"(
            "id" INTEGER PRIMARY KEY, "value" INTEGER);]])
        box.execute([[INSERT INTO "coalesce_values" VALUES
            (1, 1), (2, NULL), (3, 2);]])
        result = box.execute([[SELECT SUM(COALESCE("value", 0))
                              FROM "coalesce_values";]])
        t.assert_equals(result.metadata[1].type, 'integer')
        t.assert_equals(result.rows, {{3}})
        box.execute([[DROP TABLE "coalesce_values";]])
    end)
end

g.test_numeric_arithmetic = function()
    g.server:exec(function()
        for _, func in ipairs({'COALESCE', 'IFNULL'}) do
            local sql = ('SELECT %s(1, 2e0) / 2;'):format(func)
            local result = assert(box.execute(sql))
            t.assert_equals(result.rows, {{0}}, sql)
            t.assert_equals(result.metadata[1].type, 'double', sql)

            sql = ('SELECT %s(CAST(1 AS DOUBLE), 2e0) / 2;'):format(func)
            result = assert(box.execute(sql))
            t.assert_equals(result.rows, {{0.5}}, sql)
            t.assert_equals(result.metadata[1].type, 'double', sql)
        end
    end)
end

g.test_wrapped_null_type = function()
    g.server:exec(function()
        local queries = {
            [[SELECT ABS(COALESCE(LIKELY(NULL), 1));]],
            [[SELECT ABS(COALESCE(1, UNLIKELY(NULL)));]],
            [[SELECT ABS(IFNULL(NULL COLLATE "unicode_ci", 1));]],
            [[SELECT ABS(IFNULL(1, NULL COLLATE "unicode_ci"));]],
        }
        for _, sql in ipairs(queries) do
            local result = box.execute(sql)
            t.assert_equals(result.metadata[1].type, 'integer')
            t.assert_equals(result.rows, {{1}})
        end
    end)
end

g.test_check_constraint = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE "coalesce_check"(
            "id" INTEGER PRIMARY KEY,
            "value" INTEGER,
            CONSTRAINT "positive" CHECK(
                ABS(COALESCE("value", 0)) >= 0));]])
        box.execute([[INSERT INTO "coalesce_check" VALUES (1, 1), (2, NULL);]])
        local result = box.execute([[SELECT * FROM "coalesce_check"
                                    ORDER BY "id";]])
        t.assert_equals(result.rows, {{1, 1}, {2, box.NULL}})
        box.execute([[DROP TABLE "coalesce_check";]])
    end)
end

g.test_lazy_evaluation = function()
    g.server:exec(function()
        local body = [[function() error('must not be called') end]]
        local func = {body = body, returns = 'integer', param_list = {},
                      exports = {'SQL'}}
        box.schema.func.create('COALESCE_MUST_NOT_BE_CALLED', func)

        local sql = [[SELECT COALESCE(1, COALESCE_MUST_NOT_BE_CALLED());]]
        t.assert_equals(box.execute(sql).rows, {{1}})
        sql = [[SELECT IFNULL(1, COALESCE_MUST_NOT_BE_CALLED());]]
        t.assert_equals(box.execute(sql).rows, {{1}})

        box.schema.func.drop('COALESCE_MUST_NOT_BE_CALLED')
    end)
end
