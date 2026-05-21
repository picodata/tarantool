local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {
            -- Force each seek through the run reader.
            vinyl_cache = 0,
        },
    })
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_lcp_datetime_min_key = function(cg)
    cg.server:exec(function()
        local datetime = require('datetime')
        local digest = require('digest')

        local s = box.schema.space.create('t', { engine = 'vinyl' })
        -- We need 4KB string padding.
        s:format {
            { name = 'c1',  type = 'integer' },
            { name = 'c2',  type = 'datetime' },
            { name = 'c3',  type = 'integer' },
            { name = 'pad', type = 'string' },
        }
        s:create_index('pk', {
            parts = { { 1, 'integer' }, { 2, 'datetime' }, { 3, 'integer' } },
            page_size = 256,
        })

        -- 1672531200 (2023-01-01T00:00:00Z) is a multiple of 256
        -- epoch[0] % 256 == 128
        -- epoch[1..14] % 256 == 0
        -- epoch[15] % 256 == 128
        local BASE = 1672531200 + 128
        local epoch = { [0] = BASE, [15] = BASE + 15 * 256 }
        for j = 1, 14 do
            epoch[j] = BASE + j * 256 - 128
        end

        for j = 0, 15 do
            s:insert({ 11, datetime.new {
                timestamp = epoch[j] }, 1, digest.urandom(4096) })
        end
        box.snapshot()

        -- One row per page.
        t.assert_equals(s.index.pk:stat().disk.pages, 16)

        -- Seeking (11, ts[j], 2) is routed strictly below the seek key
        -- which breaks read iterator's invariant.
        for j = 1, 14 do
            local got = s:select(
                { 11, datetime.new { timestamp = epoch[j] }, 2 },
                { iterator = 'GT', limit = 1 })
            t.assert_equals(#got, 1)
            t.assert_equals(got[1].c1, 11)
            t.assert_equals(got[1].c2, datetime.new {
                timestamp = epoch[j + 1] })
            t.assert_equals(got[1].c3, 1)
        end
    end)
end
