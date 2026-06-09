local t = require('luatest')
local server = require('luatest.server')

local g = t.group('box_tuple_check_size')

g.before_all(function()
    -- Each test sets the max_tuple_size it needs, so the server starts
    -- with the defaults.
    g.server = server:new{}
    g.server:start()
    g.server:exec(function()
        for _, engine in ipairs({'memtx', 'vinyl'}) do
            -- A single-key space: the field map is empty, so the size
            -- check is exact.
            local s = box.schema.space.create('test_' .. engine,
                                              {engine = engine})
            s:create_index('pk')
            -- A multikey space: the field map size grows with the tuple,
            -- so the check uses a conservative upper bound for it.
            local mk = box.schema.space.create('test_mk_' .. engine,
                                               {engine = engine})
            mk:create_index('pk')
            mk:create_index('mk', {parts = {{'[2][*]', 'unsigned'}}})
        end

        rawset(_G, 'check_size', function(space_id, payload)
            local ffi = require('ffi')
            local msgpackffi = require('msgpackffi')
            ffi.cdef([[
                int
                box_tuple_check_size(uint32_t space_id, const char *data,
                                     const char *end);
            ]])
            local data = msgpackffi.encode(payload)
            local buf = ffi.cast('const char *', data)
            return ffi.C.box_tuple_check_size(space_id, buf, buf + #data)
        end)
    end)
end)

g.after_all(function()
    g.server:drop()
end)

local KB = 1024

-- Test: the check tracks the engine's live max_tuple_size. Start with
-- the smallest limit, grow it, and watch a formerly-oversized tuple
-- start to pass; what the check accepts must really be insertable, and
-- what it rejects must really be too large.
g.test_dynamic_limit = function()
    g.server:exec(function(KB)
        local check_size = rawget(_G, 'check_size')

        local function assert_fits(space, data_size)
            local p = {1, string.rep('x', data_size)}
            t.assert_equals(check_size(space.id, p), 0,
                ('%s: %d-byte tuple must pass'):format(space.name, data_size))
            space:insert(p)
            space:delete(1)
        end
        local function assert_too_big(space, data_size, errcode)
            local p = {1, string.rep('x', data_size)}
            t.assert_equals(check_size(space.id, p), -1,
                ('%s: %d-byte tuple must be rejected')
                :format(space.name, data_size))
            t.assert_equals(box.error.last().code, errcode)
            t.assert_error(function() space:insert(p) end)
        end

        local engines = {
            {space = box.space.test_memtx, cfg = 'memtx_max_tuple_size',
             err = box.error.MEMTX_MAX_TUPLE_SIZE},
            {space = box.space.test_vinyl, cfg = 'vinyl_max_tuple_size',
             err = box.error.VINYL_MAX_TUPLE_SIZE},
        }
        for _, e in ipairs(engines) do
            -- Start as small as the limit is allowed to be.
            box.cfg{[e.cfg] = 256}
            assert_fits(e.space, 16)
            assert_too_big(e.space, 8 * KB, e.err)

            -- Grow the limit: the formerly-oversized tuple now fits,
            -- proving the check reads the live limit, not a cached one.
            box.cfg{[e.cfg] = 256 * KB}
            assert_fits(e.space, 8 * KB)
            -- A single-key tuple a few KiB under the new limit must
            -- pass: its field map is empty, so the check must not
            -- over-count it (regression against bounding the field map
            -- size by INT16_MAX).
            assert_fits(e.space, 256 * KB - 8 * KB)
            -- Anything past the new limit is the new oversized case and
            -- stays rejected.
            assert_too_big(e.space, 512 * KB, e.err)
        end
    end, {KB})
end

-- Test: for a multikey space the field map size is not fixed, so the
-- check uses a conservative upper bound. A tuple close to the limit may
-- be reported as oversized even though it inserts -- but the check must
-- never under-count, so a genuinely oversized tuple is always rejected.
g.test_multikey_is_conservative = function()
    g.server:exec(function(KB)
        local check_size = rawget(_G, 'check_size')
        box.cfg{memtx_max_tuple_size = 1024 * KB,
                vinyl_max_tuple_size = 1024 * KB}
        for _, name in ipairs({'test_mk_memtx', 'test_mk_vinyl'}) do
            local s = box.space[name]
            -- A few KiB under the limit, with a small real field map:
            -- the conservative bound reports it oversized, yet it
            -- inserts fine.
            local near = {1, {1, 2, 3}, string.rep('x', 1024 * KB - 8 * KB)}
            t.assert_equals(check_size(s.id, near), -1)
            s:insert(near)
            s:delete(1)
            -- A genuinely oversized multikey tuple is rejected and is
            -- not insertable.
            local big = {1, {1, 2, 3}, string.rep('x', 2 * 1024 * KB)}
            t.assert_equals(check_size(s.id, big), -1)
            t.assert_error(function() s:insert(big) end)
        end
    end, {KB})
end

-- Test: an unknown space id is an error with a diagnostic set.
g.test_unknown_space = function()
    g.server:exec(function()
        local check_size = rawget(_G, 'check_size')
        t.assert_equals(check_size(777777, {1, 2, 3}), -1)
        t.assert_equals(box.error.last().code, box.error.NO_SUCH_SPACE)
    end)
end
