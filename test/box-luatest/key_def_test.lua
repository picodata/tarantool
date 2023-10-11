local t = require('luatest')

local g = t.group('tuple_hash')

g.test_key_def_tuple_hash = function()
    local key_def = require('key_def')
    local tuple = box.tuple.new({1, 2, 3})

    local def = key_def.new({
        {fieldno = 1, type = 'integer'},
        {fieldno = 2, type = 'integer'}
    })
    t.assert_equals(def:hash(tuple), 605624609)

    def = key_def.new({{fieldno = 1, type = 'integer'}})
    tuple = box.tuple.new({1})
    t.assert_equals(def:hash(tuple), 1457374933)

    def = key_def.new({
        {fieldno = 1, type = 'integer'},
        {fieldno = 2, type = 'integer', is_nullable = true}
    })
    tuple = box.tuple.new({1})
    t.assert_equals(def:hash(tuple), 766361540)
end
