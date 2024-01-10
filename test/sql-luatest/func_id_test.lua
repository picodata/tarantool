local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'func_id'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_func_from_reserved_range = function()
    g.server:exec(function()
        local id = box.internal.generate_func_id(true)
        t.assert(id > 32000)
        local def = {language = 'LUA',
                     body = 'function() return 1 end',
                     id = id}
        local _, err = box.schema.func.create('abc', def)
        t.assert(err == nil)
        local next_id = box.internal.generate_func_id(true)
        t.assert(next_id == id + 1)
        _, err = box.schema.func.drop(id)
        t.assert(err == nil)
    end)
end

g.test_func_from_default_range = function()
    g.server:exec(function()
        local id = box.internal.generate_func_id(false)
        t.assert(id <= 32000)
        local def = {language = 'LUA', body = 'function() return 1 end' }
        local _, err = box.schema.func.create('abc', def)
        t.assert(err == nil)
        local next_id = box.internal.generate_func_id(false)
        t.assert(next_id == id + 1)
        _, err = box.schema.func.drop(id)
        t.assert(err == nil)
    end)
end

g.test_ffi_reserved_range = function()
    g.server:exec(function()
        local id = box.internal.generate_func_id(true)
        local ffi = require('ffi')
        ffi.cdef([[int box_generate_func_id(
            uint32_t *new_func_id,
            bool use_reserved_range
        );]])
        local ptr = ffi.new('uint32_t[1]')
        local res = ffi.C.box_generate_func_id(ptr, true)
        t.assert(res == 0)
        t.assert(ptr[0] == id)
    end)
end

g.test_ffi_default_range = function()
    g.server:exec(function()
        local id = box.internal.generate_func_id(false)
        local ffi = require('ffi')
        ffi.cdef([[int box_generate_func_id(
            uint32_t *new_func_id,
            bool use_reserved_range
        );]])
        local ptr = ffi.new('uint32_t[1]')
        local res = ffi.C.box_generate_func_id(ptr, false)
        t.assert(res == 0)
        t.assert(ptr[0] == id)
    end)
end
