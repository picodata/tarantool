local t = require('luatest')
local yaml = require('yaml')
local yaml_helper = require('test.app-luatest.yaml_helper')

local g = t.group()

-- The syntax fixes came with the update of the bundled libyaml, a system
-- one may lack them.
g.before_all(function()
    t.skip_if(not yaml_helper.is_bundled_libyaml(),
              'checks the bundled libyaml')
end)

-- Tarantool keeps the space after the indicator of an empty value.
g.test_empty_value_spaces = function()
    t.assert_equals(yaml.encode(''), '--- \n...\n')
    t.assert_equals(yaml.encode({''}), '---\n- \n...\n')
    t.assert_equals(yaml.encode({key = ''}), '---\nkey: \n...\n')
end

g.test_yaml_1_2_directive = function()
    t.assert_equals(yaml.decode('%YAML 1.2\n---\na: 1\n'), {a = 1})
end

-- '?' inside a flow scalar doesn't start an explicit key.
g.test_question_mark_in_flow_scalar = function()
    t.assert_equals(yaml.decode('[foo?bar]'), {'foo?bar'})
end

-- An explicit empty key right before the end of a flow sequence. Empty
-- plain scalars are decoded as empty strings, as before.
g.test_empty_explicit_key = function()
    t.assert_equals(yaml.decode('[ ? ]'), {{[''] = ''}})
end

-- An alias used as a key is followed by a space, otherwise ':' would be
-- read as a part of the alias name.
g.test_alias_key = function()
    local obj = {1}
    local doc = yaml.encode({obj, {[obj] = 1}})
    t.assert_equals(doc, '---\n- &0\n  - 1\n- *0 : 1\n...\n')
    local res = yaml.decode(doc)
    t.assert_equals(res[1], {1})
    t.assert(rawequal(next(res[2]), res[1]), 'the alias key is the object')
end
