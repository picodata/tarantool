local t = require('luatest')
local yaml = require('yaml')
local yaml_helper = require('test.app-luatest.yaml_helper')

local g = t.group()

local g_build = t.group('yaml_build_options')

g_build.test_build_options = function()
    local build = require('tarantool').build
    local saved = build.options
    for _, value in ipairs({'TRUE', 'FALSE', ''}) do
        build.options = '-DENABLE_BUNDLED_LIBYAML=' .. value
        local ok, result = pcall(yaml_helper.is_bundled_libyaml)
        build.options = saved
        if value == '' then
            t.assert_not(ok)
            t.assert_str_contains(result, 'ENABLE_BUNDLED_LIBYAML is missing')
        else
            t.assert(ok)
            t.assert_equals(result, value == 'TRUE')
        end
    end
end

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

g.test_utf8_scalar_boundaries = function()
    local cases = {
        {'\237\160\128', '\\xED\\xA0\\x80'},
        {'\237\191\191', '\\xED\\xBF\\xBF'},
        {'\244\144\128\128', '\\xF4\\x90\\x80\\x80'},
        {'\237\159\191'}, -- U+D7FF
        {'\238\128\128'}, -- U+E000
        {'\244\143\191\191'}, -- U+10FFFF
    }
    for _, case in ipairs(cases) do
        local encoded = yaml.encode(case[1])
        if case[2] ~= nil then
            t.assert_str_contains(encoded, case[2])
        end
        t.assert_equals(yaml.decode(encoded), case[1])
    end
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

local g_alias = t.group('yaml_alias')

-- A value converted only while it is dumped can turn out to be a table that
-- already has an anchor. It must become an alias, not a collection with an
-- empty anchor.
g_alias.test_alias_after_conversion = function()
    local s = yaml.new()
    s.cfg{encode_use_tostring = true}
    local shared = {1, 2}
    local f = function() end
    debug.setmetatable(f, {__tostring = function() return shared end})
    local ok, doc, err = pcall(s.encode, {shared, shared, f})
    debug.setmetatable(f, nil)
    t.assert(ok, doc)
    t.assert_equals(err, nil)
    t.assert_equals(doc, '---\n- &0\n  - 1\n  - 2\n- *0\n- *0\n...\n')
end
