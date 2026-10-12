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
-- on the stack by the last call may hide its leak from LSan. After the
-- errors a structure with repeated references to one object must still
-- be encoded and decoded back.

-- An error raised by __serialize is turned into a diagnostic by the
-- serializer, and luaL_checkfield() used to raise it right from dump_node(),
-- unwinding past yaml_emitter_delete() and losing the emitter. Now the
-- hook is called before the emitter is created.
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
