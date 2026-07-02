-- SQL-aware update operations.
--
-- 'p'/'m' are SQL +/-: NULL in any operand yields NULL out.
-- 'a'/'o' are SQL AND/OR with three-valued logic on NULL.

local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        for _, name in ipairs({
                'sql_update_ops', 'sql_update_ops_format',
                'sql_update_ops_format_bool',
                'sql_update_ops_format_double',
                'sql_update_ops_vinyl'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

g.test_arith_null_propagation = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- Both operands NULL on a NULL field: NULL stays NULL.
        s:replace{1, box.NULL, box.NULL}
        t.assert_equals(s:update({1}, {{'p', 2, 1}, {'m', 3, 1}}):totable(),
                        {1, box.NULL, box.NULL})

        -- Decimal/float arith preserves the operand types.
        s:replace{1, 10, decimal.new('2.000'), 1.5}
        local r = s:update({1}, {{'p', 2, 5},
                                 {'m', 3, decimal.new('1.000')},
                                 {'p', 4, 0.5}}):totable()
        t.assert_equals(r[2], 15)
        t.assert_equals(tostring(r[3]), '1.000')
        t.assert_equals(r[4], 2)
    end)
end

g.test_arith_overflow = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- SQL integer arithmetic is limited to signed int64.
        s:replace{1, 0x7ffffffffffffffeLL}
        t.assert_equals(s:update({1}, {{'p', 2, 1}}):totable()[2],
                        0x7fffffffffffffffLL)
        t.assert_error_msg_contains("Integer overflow",
            s.update, s, {1}, {{'p', 2, 1}})

        s:replace{1, 0x7fffffffffffffffLL}
        t.assert_error_msg_contains("Integer overflow",
            s.update, s, {1}, {{'p', 2, 0x7fffffffffffffffLL}})

        s:replace{1, 0x7fffffffffffffffLL}
        t.assert_error_msg_contains("Integer overflow",
            s.update, s, {1}, {{'m', 2, -1}})

        s:replace{1, -2}
        t.assert_error_msg_contains("Integer overflow",
            s.update, s, {1}, {{'m', 2, 0x7fffffffffffffffULL}})

        -- Decimal at the precision boundary.
        local dec_max =
            decimal.new('90000000000000000000000000000000000000')
        s:replace{1, dec_max}
        t.assert_error_msg_contains("Decimal overflow",
            s.update, s, {1}, {{'p', 2, dec_max}})
        s:replace{1, decimal.new(
            '-90000000000000000000000000000000000000')}
        t.assert_error_msg_contains("Decimal overflow",
            s.update, s, {1}, {{'m', 2, dec_max}})

        local dec_full =
            decimal.new('99999999999999999999999999999999999999')
        s:replace{1, dec_full}
        t.assert_error_msg_contains("Decimal overflow",
            s.update, s, {1}, {{'p', 2, 1}})
        s:replace{1, decimal.new(
            '-99999999999999999999999999999999999999')}
        t.assert_error_msg_contains("Decimal overflow",
            s.update, s, {1}, {{'m', 2, 1}})
    end)
end

g.test_sql_bool_null_propagation = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- Mixed-type fields with NULL args on each: independent
        -- NULL outcomes for each op.
        s:replace{1, 10, 10, true, false}
        t.assert_equals(s:update({1}, {{'p', 2, box.NULL},
                                       {'m', 3, box.NULL},
                                       {'a', 4, box.NULL},
                                       {'o', 5, box.NULL}}):totable(),
                        {1, box.NULL, box.NULL, box.NULL, box.NULL})

        -- AND/OR with one NULL operand: dominator wins,
        -- otherwise rhs (= existing value) is preserved.
        --   false AND NULL = false  (dominant)
        --   true  OR  NULL = true   (dominant)
        s:replace{1, false, true}
        t.assert_equals(s:update({1}, {{'a', 2, box.NULL},
                                       {'o', 3, box.NULL}}):totable(),
                        {1, false, true})
    end)
end

g.test_sql_bool_dominator = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- AND with non-dominant arg (true) leaves rhs unchanged
        -- where rhs is true/false/NULL; the third stays NULL
        -- because NULL AND true = NULL.
        s:replace{1, true, false, box.NULL}
        t.assert_equals(s:update({1}, {{'a', 2, true},
                                       {'a', 3, true},
                                       {'a', 4, true}}):totable(),
                        {1, true, false, box.NULL})

        -- AND with dominant arg (false) forces all to false.
        s:replace{1, true, false, box.NULL}
        t.assert_equals(s:update({1}, {{'a', 2, false},
                                       {'a', 3, false},
                                       {'a', 4, false}}):totable(),
                        {1, false, false, false})

        -- OR with dominant arg (true) forces all to true.
        s:replace{1, true, false, box.NULL}
        t.assert_equals(s:update({1}, {{'o', 2, true},
                                       {'o', 3, true},
                                       {'o', 4, true}}):totable(),
                        {1, true, true, true})

        -- OR with non-dominant arg (false): rhs preserved.
        s:replace{1, true, false, box.NULL}
        t.assert_equals(s:update({1}, {{'o', 2, false},
                                       {'o', 3, false},
                                       {'o', 4, false}}):totable(),
                        {1, true, false, box.NULL})
    end)
end

g.test_double_update_same_field = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{1, true}
        t.assert_error_msg_contains("double update of the same field",
            s.update, s, {1}, {{'a', 2, true}, {'o', 2, false}})

        -- Mixing plain and SQL on the same field, both orders.
        s:replace{1, 1}
        t.assert_error_msg_contains("double update of the same field",
            s.update, s, {1}, {{'+', 2, 1}, {'p', 2, 1}})
        t.assert_error_msg_contains("double update of the same field",
            s.update, s, {1}, {{'p', 2, 1}, {'+', 2, 1}})
    end)
end

g.test_short_circuit_skips_old_type_check = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- Plain '+' on non-numeric old errors out.
        s:replace{1, 'str'}
        t.assert_error_msg_contains("expected a number",
            s.update, s, {1}, {{'p', 2, 1}})

        -- 'p' with NULL arg short-circuits before the old type
        -- is read: NULL flows through regardless of old type.
        t.assert_equals(s:update({1}, {{'p', 2, box.NULL}}):totable(),
                        {1, box.NULL})
        s:replace{1, {a = 1}}
        t.assert_equals(s:update({1}, {{'p', 2, box.NULL}}):totable(),
                        {1, box.NULL})
    end)
end

g.test_sql_bool_invalid_arg_type = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{1, true}
        for _, arg in ipairs({'true', 1, 1.5, {1, 2}}) do
            t.assert_error_msg_contains("expected a boolean or nil",
                s.update, s, {1}, {{'a', 2, arg}})
        end
    end)
end

g.test_sql_bool_invalid_old_type = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{1, 1}
        t.assert_error_msg_contains("expected a boolean or nil",
            s.update, s, {1}, {{'a', 2, true}})

        s:replace{1, decimal.new('1')}
        t.assert_error_msg_contains("expected a boolean or nil",
            s.update, s, {1}, {{'a', 2, true}})

        s:replace{1, {1, 2, 3}}
        t.assert_error_msg_contains("expected a boolean or nil",
            s.update, s, {1}, {{'a', 2, true}})
    end)
end

g.test_plain_bit_rejects_null = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- NULL arg acceptance is for 'p'/'m'/'a'/'o' only.
        s:replace{1, 1}
        t.assert_error_msg_contains("expected a positive integer",
            s.update, s, {1}, {{'&', 2, box.NULL}})
    end)
end

g.test_multi_op_independent_fields = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{1, 10, true}
        t.assert_equals(
            s:update({1}, {{'p', 2, box.NULL}, {'a', 3, false}}):totable(),
            {1, box.NULL, false})
    end)
end

g.test_tuple_paths = function(cg)
    cg.server:exec(function()
        -- SQL ops at JSON paths inside a nested array.
        --   p(NULL,1)=NULL, o(NULL,true)=true,
        --   m(NULL,1)=NULL, a(NULL,false)=false
        local r = box.tuple.new(
            {1, {box.NULL, box.NULL, box.NULL, box.NULL}}):update(
            {{'p', '[2][1]', 1}, {'o', '[2][2]', true},
             {'m', '[2][3]', 1}, {'a', '[2][4]', false}})
        t.assert_equals(r:totable(),
                        {1, {box.NULL, true, box.NULL, false}})
    end)
end

g.test_format_constraints = function(cg)
    cg.server:exec(function()
        -- 'p' producing a negative result into an unsigned column
        -- fails the format check.
        local sf = box.schema.create_space('sql_update_ops_format',
            {format = {{'id', 'unsigned'}, {'v', 'unsigned'}}})
        sf:create_index('pk')
        sf:replace{1, 1}
        t.assert_error_msg_contains("expected unsigned, got integer",
            sf.update, sf, {1}, {{'p', 2, -2}})
        sf:drop()

        -- Nullable unsigned accepts NULL.
        sf = box.schema.create_space('sql_update_ops_format',
            {format = {{'id', 'unsigned'},
                       {'v', 'unsigned', is_nullable = true}}})
        sf:create_index('pk')
        sf:replace{1, 1}
        t.assert_equals(sf:update({1}, {{'p', 2, box.NULL}}):totable(),
                        {1, box.NULL})
        sf:drop()

        -- Non-nullable boolean rejects 3VL-induced NULL.
        sf = box.schema.create_space('sql_update_ops_format_bool',
            {format = {{'id', 'unsigned'}, {'v', 'boolean'}}})
        sf:create_index('pk')
        sf:replace{1, true}
        t.assert_error_msg_contains("expected boolean, got nil",
            sf.update, sf, {1}, {{'a', 2, box.NULL}})
        sf:drop()

        -- Nullable boolean accepts 3VL-induced NULL.
        sf = box.schema.create_space('sql_update_ops_format_bool',
            {format = {{'id', 'unsigned'},
                       {'v', 'boolean', is_nullable = true}}})
        sf:create_index('pk')
        sf:replace{1, true}
        t.assert_equals(sf:update({1}, {{'a', 2, box.NULL}}):totable(),
                        {1, box.NULL})
    end)
end

g.test_format_double_preserves_type = function(cg)
    cg.server:exec(function()
        local ffi = require('ffi')
        local msgpackffi = require('msgpackffi')
        local MP_DOUBLE = 0xcb

        local sf = box.schema.create_space('sql_update_ops_format_double',
            {format = {{'id', 'unsigned'}, {'v', 'double'}}})
        sf:create_index('pk')

        local flt1 = ffi.cast('float', 1)
        sf:replace{1, flt1}
        sf:update({1}, {{'p', 2, 1}})
        -- Verify the result kept the column's declared double width.
        t.assert_equals(msgpackffi.encode(sf:get{1}):byte(3),
                        MP_DOUBLE)

        sf:replace{1, flt1}
        sf:update({1}, {{'m', 2, ffi.cast('float', 0.5)}})
        t.assert_equals(msgpackffi.encode(sf:get{1}):byte(3),
                        MP_DOUBLE)
    end)
end

g.test_upsert = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        -- Insert path: ops do not apply.
        s:upsert({100, 1}, {{'p', 2, box.NULL}})
        t.assert_equals(s:get{100}:totable(), {100, 1})

        -- Update path: SQL arith with NULL produces NULL.
        s:upsert({100, 1}, {{'p', 2, box.NULL}})
        t.assert_equals(s:get{100}:totable(), {100, box.NULL})

        -- 3VL via update path: AND false dominates over true.
        s:replace{101, true}
        s:upsert({101, true}, {{'a', 2, false}})
        t.assert_equals(s:get{101}:totable(), {101, false})

        -- 3VL via update path: AND of false with NULL stays false.
        s:upsert({101, false}, {{'a', 2, box.NULL}})
        t.assert_equals(s:get{101}:totable(), {101, false})
    end)
end

g.test_upsert_sql_arith_errors_are_strict = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{1, 0x7fffffffffffffffLL}
        t.assert_error_msg_contains("Integer overflow",
            s.upsert, s, {1, 2}, {{'p', 2, 1}})
        t.assert_equals(s:get{1}:totable(), {1, 0x7fffffffffffffffLL})

        t.assert_error_msg_contains("Integer overflow",
            s.upsert, s, {1, 2}, {{'p', 2, 0x7fffffffffffffffLL}})
        t.assert_equals(s:get{1}:totable(), {1, 0x7fffffffffffffffLL})

        t.assert_error_msg_contains("Integer overflow",
            s.upsert, s, {1, 2}, {{'p', 2, 0x7fffffffffffffffLL}})
        t.assert_equals(s:get{1}:totable(), {1, 0x7fffffffffffffffLL})

        t.assert_error_msg_contains("Integer overflow",
            s.upsert, s, {1, 2}, {{'m', 2, -1}})
        t.assert_equals(s:get{1}:totable(), {1, 0x7fffffffffffffffLL})

        s:replace{2, 'str'}
        s:upsert({2, 'str'}, {{'+', 2, 1}})
        t.assert_equals(s:get{2}:totable(), {2, 'str'})
        t.assert_error_msg_contains("expected a number",
            s.upsert, s, {2, 'str'}, {{'p', 2, 1}})
        t.assert_equals(s:get{2}:totable(), {2, 'str'})

        local sf = box.schema.create_space('sql_update_ops_format',
            {format = {{'id', 'unsigned'}, {'v', 'unsigned'}}})
        sf:create_index('pk')
        sf:replace{1, 0}
        t.assert_error_msg_contains("expected unsigned, got integer",
            sf.upsert, sf, {1, 2}, {{'m', 2, 1}})
        t.assert_equals(sf:get{1}:totable(), {1, 0})
    end)
end

g.test_pk_update_rejected = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')

        s:replace{200, 0}
        -- Plain modification of the PK is rejected; SQL 'p' is no
        -- different.
        t.assert_error_msg_contains(
            "Attempt to modify a tuple field which is part of",
            s.update, s, {200}, {{'p', 1, 1}})
        -- NULL into an unsigned PK trips the format check.
        t.assert_error_msg_contains("expected unsigned, got nil",
            s.update, s, {200}, {{'p', 1, box.NULL}})
    end)
end

g.test_unique_sk_update = function(cg)
    cg.server:exec(function()
        -- 'p' producing NULL through a unique SK on a nullable
        -- field: the index allows the resulting NULL key.
        local s = box.schema.create_space('sql_update_ops')
        s:create_index('pk')
        s:create_index('uniq', {parts = {2, 'unsigned',
                                         is_nullable = true},
                                unique = true})
        s:replace{1, 100}
        t.assert_equals(
            s.index.uniq:update({100}, {{'p', 2, box.NULL}}):totable(),
            {1, box.NULL})
    end)
end

g.test_vinyl = function(cg)
    cg.server:exec(function()
        -- SQL update producing NULL must round-trip through the
        -- vinyl dump path and remain reachable via a nullable SK.
        local vy = box.schema.create_space('sql_update_ops_vinyl',
                                           {engine = 'vinyl'})
        vy:create_index('pk')
        vy:create_index('sk', {parts = {2, 'unsigned',
                                        is_nullable = true},
                               unique = false})
        vy:replace{1, 10}
        vy:update({1}, {{'p', 2, box.NULL}})
        box.snapshot()
        t.assert_equals(vy.index.sk:select{}[1]:totable(), {1, box.NULL})
    end)
end
