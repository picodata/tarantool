local server = require('luatest.server')
local t = require('luatest')

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
-- on the stack by the last call may hide its leak from LSan. After the
-- errors a structure with repeated references to one object must still
-- be encoded and decoded back.

-- An error raised by __serialize is turned into a diagnostic by the
-- serializer, and luaL_checkfield() used to raise it right from dump_node(),
-- unwinding past yaml_emitter_delete() and losing the emitter.
g.test_encode_serialize_error = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local obj = setmetatable({}, {__serialize = function()
            error('serialize error')
        end})
        for _ = 1, 20 do
            local ok, err = pcall(yaml.encode, obj)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), 'serialize error')
        end
        local shared = {1, 2}
        local res = yaml.decode(yaml.encode({a = shared, b = shared}))
        t.assert_equals(res.a, shared)
        t.assert(rawequal(res.a, res.b), 'the reference is kept')
    end)
end

g.test_encode_tostring_error = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{encode_use_tostring = true}
        local function fail()
            error('tostring error')
        end
        for _ = 1, 20 do
            for _, value in ipairs({function() end, coroutine.create(fail)}) do
                local mt = debug.getmetatable(value)
                debug.setmetatable(value, {__tostring = fail})
                local ok, err = pcall(yaml.encode, value)
                debug.setmetatable(value, mt)
                t.assert_equals(ok, false)
                t.assert_str_contains(err, 'tostring error')
            end
            local saved = _G.tostring
            _G.tostring = fail
            local ok, err = pcall(yaml.encode, function() end)
            _G.tostring = saved
            t.assert_equals(ok, false)
            t.assert_str_contains(err, 'tostring error')
        end
        t.assert_equals(yaml.decode(yaml.encode({1, 2})), {1, 2})
    end)
end

g.test_encode_mutating_serialize = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local calls, value
        local child = setmetatable({}, {__serialize = function()
            calls = calls + 1
            if calls == 2 then
                value.child = nil
                for i = 1, 64 do
                    value['k' .. i] = i
                end
            end
        end})
        for _ = 1, 20 do
            calls, value = 0, {child = child}
            t.assert_error_msg_contains("invalid key to 'next'", yaml.encode,
                                        value)
        end
        local shared = {1, 2}
        local res = yaml.decode(yaml.encode({shared, shared}))
        t.assert_equals(res[1], shared)
        t.assert(rawequal(res[1], res[2]))
    end)
end

g.test_encode_invalid_number = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{encode_invalid_numbers = false}
        for _ = 1, 20 do
            t.assert_error_msg_contains('number must not be NaN or Inf',
                                        yaml.encode, {a = 0 / 0})
        end
        t.assert_equals(yaml.decode(yaml.encode({a = 1})), {a = 1})
    end)
end

g.test_encode_too_deep = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        yaml.cfg{encode_max_depth = 2, encode_deep_as_nil = false}
        for _ = 1, 20 do
            t.assert_error_msg_contains('Too high nest level', yaml.encode,
                                        {{{1}}})
        end
        t.assert_equals(yaml.decode(yaml.encode({{1}})), {{1}})
    end)
end

-- The same unwinding happens for a value the serializer cannot convert.
g.test_encode_unsupported_value = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        local obj = setmetatable({}, {__serialize = 42})
        for _ = 1, 20 do
            local ok = pcall(yaml.encode, obj)
            t.assert_equals(ok, false)
        end
        local shared = {1, 2}
        local res = yaml.decode(yaml.encode({a = shared, b = shared}))
        t.assert_equals(res.a, shared)
        t.assert(rawequal(res.a, res.b), 'the reference is kept')
    end)
end

-- A function is rejected once the emitter is created.
g.test_encode_function = function(cg)
    cg.server:exec(function()
        local yaml = require('yaml')
        for _ = 1, 20 do
            local ok, err = pcall(yaml.encode, function() end)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), "unsupported Lua type")
        end
        local shared = {1, 2}
        local res = yaml.decode(yaml.encode({a = shared, b = shared}))
        t.assert_equals(res.a, shared)
        t.assert(rawequal(res.a, res.b), 'the reference is kept')
    end)
end

-- A malformed JSON value is rejected once the emitter is created. The text
-- of a valid one goes on the fiber region and must be freed without
-- touching what the caller keeps there.
g.test_encode_invalid_json = function(cg)
    cg.server:exec(function()
        local ffi = require('ffi')
        local yaml = require('yaml')
        ffi.cdef([[
            void *box_region_alloc(size_t size);
            size_t box_region_used(void);
            void box_region_truncate(size_t size);
        ]])
        local function json(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        local bad = json('\xc4\x00')
        local good = json('\x81\xa1\x61\x01')

        local svp = ffi.C.box_region_used()
        local caller = ffi.cast('char *', ffi.C.box_region_alloc(16))
        ffi.copy(caller, 'caller data', 12)
        local used = ffi.C.box_region_used()
        for _ = 1, 20 do
            local ok, err = pcall(yaml.encode, bad)
            t.assert_equals(ok, false)
            t.assert_str_contains(tostring(err), 'Invalid JSON value')
            t.assert_equals(yaml.encode(good), "--- '{\"a\": 1}'\n...\n")
        end
        t.assert_equals(ffi.C.box_region_used(), used)
        t.assert_equals(ffi.string(caller), 'caller data')
        ffi.C.box_region_truncate(svp)
        local shared = {1, 2}
        local res = yaml.decode(yaml.encode({a = shared, b = shared}))
        t.assert_equals(res.a, shared)
        t.assert(rawequal(res.a, res.b), 'the reference is kept')
    end)
end
