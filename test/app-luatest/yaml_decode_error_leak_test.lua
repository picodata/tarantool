local server = require('luatest.server')
local t = require('luatest')
local yaml_helper = require('test.app-luatest.yaml_helper')

local g = t.group()

-- Every test runs in its own instance: a leak reported at the instance exit
-- then belongs to one class of errors, and a test run alone shows whether
-- it catches the leak of its class.
g.before_each(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
end)

g.after_each(function(cg)
    require('test.lsan').stop(cg.server, {'third_party/libyaml/', 'third_party/lua-yaml/'})
end)

-- Each error is repeated from the same place in one fiber: a pointer left
-- on the stack by the last call may hide its leak from LSan. A valid
-- document must be decoded after the errors.

-- The options of yaml.decode() used to be validated after the parser had
-- been created, so the usage error lost it.
g.test_decode_bad_options = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        for _ = 1, 20 do
            local ok, err = pcall(yaml.decode, 'a: 1', 5)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), 'Usage: yaml.decode')
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

-- l_load() raised the error of luaL_checkfinite() with lua_error(), which
-- unwound past yaml_parser_delete() and lost the parser.
g.test_decode_invalid_number = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{decode_invalid_numbers = false}
        for _ = 1, 20 do
            for _, doc in ipairs({'nan', 'inf', '-inf'}) do
                local ok, err = pcall(yaml.decode, doc)
                t.assert_equals(ok, false, doc)
                t.assert_str_contains(tostring(err),
                                      'number must not be NaN or Inf')
            end
        end
        local decode = assert(loadstring('return function()\n' ..
            'local value = require("yaml").decode("nan")\n' ..
            'return value\nend', '@yaml-number.lua'))()
        local message = 'yaml-number.lua:2: number must not be NaN or Inf'
        t.assert_error_msg_contains(message, decode)
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

-- The same for a number with the explicit float tag.
g.test_decode_invalid_float_tag = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{decode_invalid_numbers = false}
        for _ = 1, 20 do
            for _, doc in ipairs({'!!float nan', '!!float inf'}) do
                local ok, err = pcall(yaml.decode, doc)
                t.assert_equals(ok, false, doc)
                t.assert_str_contains(tostring(err),
                                      'number must not be NaN or Inf')
            end
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

g.test_decode_syntax_error = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        for _ = 1, 20 do
            local ok = pcall(yaml.decode, 'a: [1, 2\nb: c')
            t.assert_equals(ok, false)
            for _, case in ipairs({
                {']', 'did not find expected node content', 'column: 1'},
                {'--- ]', 'did not find expected node content', 'column: 5'},
                {'--- "\\uD800"', 'found invalid Unicode character escape code',
                 'column: 8'},
            }) do
                local success, err = pcall(yaml.decode, case[1])
                t.assert_equals(success, false)
                t.assert_str_contains(err, case[2])
                t.assert_str_contains(err, case[3])
                t.assert_not_str_contains(err, 'unexpected END event')
            end
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

g.test_decode_stack_overflow = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        t.assert_equals(select('#', yaml.decode(('---\n'):rep(65000))), 65000)
        local docs = ('---\n'):rep(66000)
        for _ = 1, 20 do
            t.assert_error_msg_contains('stack overflow', yaml.decode, docs)
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

-- A document deeper than the limit of the bundled libyaml.
g.test_decode_too_deep = function(cg)
    yaml_helper.skip_if_not_bundled()
    cg.server:exec(function()
        local yaml = require('yaml')
        local doc = ('['):rep(1001) .. '0' .. (']'):rep(1001)
        for _ = 1, 20 do
            local ok, err = pcall(yaml.decode, doc)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err),
                                  'exceeded maximum nesting depth')
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

-- Lua never accepts NaN as a table key, and lua_rawset() used to raise that
-- error right from load_map(), past yaml_parser_delete().
g.test_decode_nan_key = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{decode_invalid_numbers = true}
        local docs = {'nan: 1', '{nan: 1}', '!!float nan: 1',
                      '? !!float nan\n: 1'}
        for _ = 1, 20 do
            for _, doc in ipairs(docs) do
                local ok, err = pcall(yaml.decode, doc)
                t.assert_equals(ok, false, doc)
                t.assert_str_contains(tostring(err), 'table index is NaN')
            end
        end
        local res = yaml.decode('a: nan')
        t.assert_not_equals(res.a, res.a, 'NaN is still a valid value')
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end
