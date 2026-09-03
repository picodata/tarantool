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

-- An error raised by __serialize is turned into a diagnostic by the
-- serializer, and luaL_checkfield() used to raise it right from dump_node(),
-- unwinding past yaml_emitter_delete() and losing the emitter.
g.test_encode_serialize_error = function()
    g.server:exec(function()
        local yaml = require('yaml')
        local obj = setmetatable({}, {__serialize = function()
            error('serialize error')
        end})
        for _ = 1, 20 do
            local ok, err = pcall(yaml.encode, obj)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), 'serialize error')
        end
    end)
end

-- The same unwinding happens for a value the serializer cannot convert.
g.test_encode_unsupported_value = function()
    g.server:exec(function()
        local yaml = require('yaml')
        local obj = setmetatable({}, {__serialize = 42})
        for _ = 1, 20 do
            local ok = pcall(yaml.encode, obj)
            t.assert_equals(ok, false)
        end
    end)
end
