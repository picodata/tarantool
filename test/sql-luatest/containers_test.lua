local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'containers'})
    g.server:start()
    g.server:exec(function()
        local build_path = os.getenv("BUILDDIR")
        package.cpath = build_path..'/test/sql-luatest/?.so;'..
                        build_path..'/test/sql-luatest/?.dylib;'..
                        package.cpath
        local opts = {language = 'C', returns = 'any', exports = {'SQL'}}
        box.schema.func.create('sql_containers.ret_array', opts)
        box.schema.func.create('sql_containers.ret_map', opts)
        box.schema.func.create('sql_containers.ret_array_tuple', opts)
        box.schema.func.create('sql_containers.ret_map_tuple', opts)
    end)
end)

g.after_all(function()
    g.server:exec(function()
        box.schema.func.drop('sql_containers.ret_array', {if_exists = true})
        box.schema.func.drop('sql_containers.ret_map', {if_exists = true})
        box.schema.func.drop('sql_containers.ret_array_tuple',
                             {if_exists = true})
        box.schema.func.drop('sql_containers.ret_map_tuple',
                             {if_exists = true})
    end)
    g.server:stop()
end)

-- Make sure that it is possible to get elements from MAP и ARRAY.
g.test_containers_success = function()
    g.server:exec(function()
        local sql = [[SELECT [123, 234, 356, 467][2];]]
        t.assert_equals(box.execute(sql).rows, {{234}})

        sql = [[SELECT {'one' : 123, 3 : 'two', '123' : true}[3];]]
        t.assert_equals(box.execute(sql).rows, {{'two'}})

        sql = [[SELECT {'one' : [11, 22, 33], 3 : 'two'}['one'][2];]]
        t.assert_equals(box.execute(sql).rows, {{22}})

        sql = [[SELECT {'one' : 123, 3 : 'two', '123' : true}['three'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        -- Subscripting a typed NULL container yields NULL.
        t.assert_equals(box.execute([[SELECT CAST(NULL AS ARRAY)[1];]]).rows,
                        {{}})
        t.assert_equals(box.execute([[SELECT CAST(NULL AS MAP)['k'];]]).rows,
                        {{}})

        -- ANY values are indexable iff they are containers.
        sql = [[SELECT CAST([1] AS ANY)[1];]]
        t.assert_equals(box.execute(sql).rows, {{1}})
    end)
end

--
-- Make sure that operator [] cannot get elements from values of types other
-- than MAP and ARRAY.
--
g.test_containers_error = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT 1[1];]])
        local res = "Selecting is only possible from map and array values"
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT -1[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT 1.1[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT 1.2e0[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT '1'[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT x'31'[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT true[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT uuid()[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT now()[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT (now() - now())[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT CAST(1 AS NUMBER)[1];]])
        t.assert_equals(err.message, res)

        _, err = box.execute([[SELECT CAST(1 AS SCALAR)[1];]])
        t.assert_equals(err.message, res)

        -- ANY-typed values are only checked at runtime: a non-container
        -- value produces a type mismatch error instead.
        _, err = box.execute([[SELECT CAST(1 AS ANY)[1];]])
        t.assert_equals(err.message,
                         "Type mismatch: can not convert any(1) to map " ..
                         "or array")

        _, err = box.execute([[SELECT NULL[1];]])
        t.assert_equals(err.message, res)
    end)
end

--
-- Make sure that the second and the following operators do not throw type
-- error.
--
g.test_containers_followers = function()
    g.server:exec(function()
        local sql = [[SELECT [1, 2, 3][1][2];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        sql = [[SELECT [1, 2, 3][1][2][3][4][5][6][7];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        -- The result of the first [] is statically typed as ANY, so the
        -- following [] is only checked at runtime.
        sql = [[SELECT ([1, 2, 3][1])[2];]]
        local _, err = box.execute(sql)
        local res = "Type mismatch: can not convert any(1) to map or array"
        t.assert_equals(err.message, res)
    end)
end

-- Make sure that the received element is of type ANY.
g.test_containers_elem_type = function()
    g.server:exec(function()
        local sql = [[SELECT typeof([123, 234, 356, 467][2]);]]
        t.assert_equals(box.execute(sql).rows, {{'any'}})

        sql = [[SELECT [123, 234, 356, 467][2];]]
        t.assert_equals(box.execute(sql).metadata[1].type, 'any')

        sql = [[SELECT typeof({'one' : 123, 3 : 'two', '123' : true}[3]);]]
        t.assert_equals(box.execute(sql).rows, {{'any'}})

        sql = [[SELECT {'one' : 123, 3 : 'two', '123' : true}[3];]]
        t.assert_equals(box.execute(sql).metadata[1].type, 'any')

        sql = [[SELECT typeof({'one' : [11, 22, 33], 3 : 'two'}['one']);]]
        t.assert_equals(box.execute(sql).rows, {{'any'}})

        sql = [[SELECT {'one' : [11, 22, 33], 3 : 'two'}['one'];]]
        t.assert_equals(box.execute(sql).metadata[1].type, 'any')
    end)
end

--
-- Make sure that an ARRAY value returned from a C stored procedure via
-- box_return_mp() is properly delivered to SQL.
--
g.test_c_ret_array_to_sql = function()
    g.server:exec(function()
        local sql = [[SELECT "sql_containers.ret_array"();]]
        t.assert_equals(box.execute(sql), {
            metadata = {{name = "COLUMN_1", type = "any"}},
            rows = {{{2, 42}}
        }})

        -- indexing the returned container directly works
        sql = [[SELECT "sql_containers.ret_array"()[1];]]
        t.assert_equals(box.execute(sql).rows, {{2}})
    end)
end

--
-- Make sure that a MAP value returned from a C stored procedure via
-- box_return_mp() is properly delivered to SQL.
--
g.test_c_ret_map_to_sql = function()
    g.server:exec(function()
        local sql = [[SELECT "sql_containers.ret_map"();]]
        t.assert_equals(box.execute(sql), {
            metadata = {{name = "COLUMN_1", type = "any"}},
            rows = {{{key1 = 2, key2 = 42}}
        }})

        -- indexing the returned container directly works
        sql = [[SELECT "sql_containers.ret_map"()['key1'];]]
        t.assert_equals(box.execute(sql).rows, {{2}})
    end)
end

--
-- Make sure that an ARRAY value returned from a C stored procedure inside
-- a tuple via box_return_tuple() is properly unwrapped and delivered to SQL.
--
g.test_c_ret_array_tuple_to_sql = function()
    g.server:exec(function()
        local sql = [[SELECT "sql_containers.ret_array_tuple"();]]
        t.assert_equals(box.execute(sql), {
            metadata = {{name = "COLUMN_1", type = "any"}},
            rows = {{{2, 42}}
        }})

        -- indexing the returned container directly works
        sql = [[SELECT "sql_containers.ret_array_tuple"()[1];]]
        t.assert_equals(box.execute(sql).rows, {{2}})
    end)
end

--
-- Make sure that a MAP value returned from a C stored procedure inside
-- a tuple via box_return_tuple() is properly unwrapped and delivered to SQL.
--
g.test_c_ret_map_tuple_to_sql = function()
    g.server:exec(function()
        local sql = [[SELECT "sql_containers.ret_map_tuple"();]]
        t.assert_equals(box.execute(sql), {
            metadata = {{name = "COLUMN_1", type = "any"}},
            rows = {{{key1 = 2, key2 = 42}}
        }})

        -- indexing the returned container directly works
        sql = [[SELECT "sql_containers.ret_map_tuple"()['key1'];]]
        t.assert_equals(box.execute(sql).rows, {{2}})
    end)
end

--
-- Make sure that a string key is parsed as an integer and used to index an
-- ARRAY, while the result type stays ANY.
--
g.test_containers_array_string_key = function()
    g.server:exec(function()
        local sql = [[SELECT [10, 20, 30]['1'];]]
        t.assert_equals(box.execute(sql).rows, {{10}})

        sql = [[SELECT [10, 20, 30]['2'];]]
        t.assert_equals(box.execute(sql).rows, {{20}})

        sql = [[SELECT [10, 20, 30]['3'];]]
        t.assert_equals(box.execute(sql).rows, {{30}})

        -- Leading/trailing whitespace is trimmed before parsing the key.
        sql = [[SELECT [10, 20, 30][' 2 '];]]
        t.assert_equals(box.execute(sql).rows, {{20}})

        -- Out of range and zero indexes yield NULL, just like with an
        -- integer key.
        sql = [[SELECT [10, 20, 30]['0'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        sql = [[SELECT [10, 20, 30]['4'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        -- Negative indexes are not supported, same as for an integer key.
        sql = [[SELECT [10, 20, 30]['-1'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        -- Keys that cannot be parsed as an integer yield NULL.
        sql = [[SELECT [10, 20, 30]['abc'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        sql = [[SELECT [10, 20, 30]['1.5'];]]
        t.assert_equals(box.execute(sql).rows, {{}})

        -- Chaining works: a string key can be used at any nesting level.
        sql = [[SELECT {'one' : [11, 22, 33], 3 : 'two'}['one']['2'];]]
        t.assert_equals(box.execute(sql).rows, {{22}})

        -- The result is still typed as ANY.
        sql = [[SELECT typeof([10, 20, 30]['1']);]]
        t.assert_equals(box.execute(sql).rows, {{'any'}})

        -- MAP lookup is unaffected: a string key is not converted to an
        -- integer, so it does not match an integer map key.
        sql = [[SELECT {3 : 'two'}['3'];]]
        t.assert_equals(box.execute(sql).rows, {{}})
    end)
end
