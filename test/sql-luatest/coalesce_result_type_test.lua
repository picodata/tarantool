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

        local sql = [[SELECT TYPEOF(COALESCE(-1, 1.5, 2e0));]]
        t.assert_equals(box.execute(sql).rows, {{'double'}})
        sql = [[SELECT TYPEOF(COALESCE(NULL, 1, [1]));]]
        t.assert_equals(box.execute(sql).rows, {{'any'}})
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
