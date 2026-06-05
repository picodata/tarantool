local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
    cg.server:exec(function()
        box.schema.create_space('test', {engine = 'vinyl'})
        box.space.test:create_index('primary', {
            parts = {1, 'unsigned'},
        })
        box.space.test:create_index('secondary', {
            parts = {2, 'string'}, unique = false,
        })
        for i = 1, 10 do
            box.space.test:insert({i, string.rep('x', 1000)})
        end
        -- Push the tuples to disk so the selects below allocate
        -- fresh read-path tuples. Tuples still in a mem are
        -- already part of memory.tuple, so pinning them would
        -- not move the stat.
        box.snapshot()
        collectgarbage()
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_tuple_stat = function(cg)
    cg.server:exec(function()
        local function gc()
            box.tuple.new() -- drop blessed tuple ref
            collectgarbage()
        end
        local function tuple_mem()
            return box.stat.vinyl().memory.tuple
        end
        -- memory.tuple is the gross footprint of the vinyl TX
        -- tuple slab. Measure it as the *drop* when 10 pinned
        -- tuples are released: nothing allocates between the two
        -- readings, so the alloc-driven mem drain cannot move the
        -- slab under us. Ten tuples with a 1000-byte payload
        -- occupy between 10KB (payload alone) and 25KB (with
        -- msgpack headers and slab size-class rounding).
        local function assert_ten_tuples(delta)
            t.assert(delta >= 10 * 1000 and delta <= 10 * 2500,
                ('memory.tuple moved by %d bytes, ' ..
                 'expected ~10 pinned tuples'):format(delta))
        end

        -- Pinned by Lua.
        box.cfg({vinyl_cache = 0})
        local ret = box.space.test:select()
        t.assert_equals(#ret, 10)
        local with_lua = tuple_mem()
        ret = nil -- luacheck: ignore
        gc()
        assert_ten_tuples(with_lua - tuple_mem())

        -- Pinned by cache.
        box.cfg({vinyl_cache = 100 * 1000})
        ret = box.space.test:select()
        t.assert_equals(#ret, 10)
        ret = nil -- luacheck: ignore
        gc()
        local with_cache = tuple_mem()
        box.cfg({vinyl_cache = 0}) -- evict
        assert_ten_tuples(with_cache - tuple_mem())
    end)
end
