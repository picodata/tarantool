local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
end)

-- Server:stop() fails on any LeakSanitizer report in the instance stderr.
-- Until the instance shutdown is complete (see the lj_BC_FUNCC comment in
-- asan/lsan.supp), an ASAN build running with the LSan profile reports
-- unrelated leaks as well: the error objects the tests below leave for the
-- Lua garbage collector, among others. Only what libyaml itself allocated
-- is checked here.
g.after_all(function()
    local ok, err = pcall(g.server.stop, g.server)
    if ok then
        return
    end
    err = tostring(err)
    if not err:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    g.server:save_artifacts()
    t.assert_not_str_contains(err, 'third_party/libyaml', false,
                              'LSan reported a leak in libyaml')
end)

-- l_load() raises the decoding error with lua_error(), which unwinds past
-- yaml_parser_delete() and loses the parser.
g.test_decode_invalid_number = function()
    g.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{encode_invalid_numbers = true}
        local nan = yaml.encode(0 / 0)
        yaml.cfg{decode_invalid_numbers = false}
        for _ = 1, 20 do
            local ok = pcall(yaml.decode, nan)
            t.assert_equals(ok, false)
        end
        yaml.cfg{decode_invalid_numbers = true}
    end)
end

-- The options of yaml.decode() used to be validated after the parser had
-- been created, so the usage error lost it as well.
g.test_decode_bad_options = function()
    g.server:exec(function()
        local yaml = require('yaml')
        for _ = 1, 20 do
            local ok, err = pcall(yaml.decode, 'a: 1', 5)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), 'Usage: yaml.decode')
        end
    end)
end
