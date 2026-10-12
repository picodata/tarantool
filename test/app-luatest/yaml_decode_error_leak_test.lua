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

-- Server:stop() fails on any LeakSanitizer report in the instance stderr.
-- Until the instance shutdown is complete (see the lj_BC_FUNCC comment in
-- asan/lsan.supp), an ASAN build running with the LSan profile reports
-- unrelated leaks as well: the error objects the tests below leave for the
-- Lua garbage collector, among others. Only what libyaml itself allocated
-- is checked here.
g.after_each(function(cg)
    local ok, err = pcall(cg.server.stop, cg.server)
    if ok then
        return
    end
    err = tostring(err)
    if not err:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    cg.server:save_artifacts()
    t.assert_not_str_contains(err, 'third_party/libyaml', false,
                              'LSan reported a leak in libyaml')
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
        end
        t.assert_equals(yaml.decode('a: 1'), {a = 1})
    end)
end

-- A document deeper than the limit of the bundled libyaml.
g.test_decode_too_deep = function(cg)
    t.skip_if(not yaml_helper.is_bundled_libyaml(),
              'the depth limit is a feature of the bundled libyaml')
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
