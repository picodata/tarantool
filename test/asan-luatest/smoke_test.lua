local t = require('luatest')
local justrun = require('luatest.justrun')
local tarantool = require('tarantool')
local ffi = require('ffi')

local g = t.group()

local function has_asan_smoke_trigger()
    ffi.cdef[[char asan_smoke_trigger(void);]]
    return pcall(function() return ffi.C.asan_smoke_trigger end)
end

g.test_asan_smoke = function()
    t.skip_if(not tarantool.build.asan, 'requires ASAN build')
    t.skip_if(not has_asan_smoke_trigger(),
              'requires ENABLE_ASAN_SMOKE_TEST=ON')

    local res = justrun.tarantool('.', {}, {
        '-e', 'local ffi = require("ffi"); ' ..
              'ffi.cdef[[char asan_smoke_trigger(void)]]; ' ..
              'ffi.C.asan_smoke_trigger()'
    }, {nojson = true, stderr = true, quote_args = true})

    t.assert_not_equals(res.exit_code, 0,
        'ASan should abort the process on heap-buffer-overflow')
    t.assert_str_contains(res.stderr, 'heap-buffer-overflow', false,
        'ASan error message should mention heap-buffer-overflow')
end
