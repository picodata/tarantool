-- vinyl_memory = 0 is the "vinyl disabled" configuration. Two
-- properties must hold:
--
--   writes blocked -- the memory quota grants nothing while used is at
--     the limit, so every data write blocks on the quota and times out
--     rather than landing. An empty space can still be created, since
--     building an index over no rows charges no quota.
--
--   no idle dumping -- with nothing in memory there is nothing to
--     dump. The dump watermark is zero here, so a check that only asks
--     "used >= watermark" would fire on an empty system and the
--     scheduler would spin empty dump rounds forever. An idle instance
--     must not dump.

local server = require('luatest.server')
local t = require('luatest')

-- {{{ writes blocked when disabled

local gw = t.group('vinyl_memory_zero.writes')

gw.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {
            vinyl_memory = 0,
            vinyl_timeout = 0.5,
        },
    })
    cg.server:start()
end)

gw.after_all(function(cg)
    cg.server:drop()
end)

gw.test_write_blocks_until_timeout = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('disabled', {engine = 'vinyl'})
        s:create_index('pk')
        -- The first row must acquire memory quota, but the limit is
        -- zero and nothing can ever free quota, so the write blocks
        -- and surfaces a timeout instead of landing.
        local ok, err = pcall(s.insert, s, {1})
        t.assert_not(ok, 'write must not be admitted at vinyl_memory = 0')
        t.assert_equals(err.code, box.error.VY_QUOTA_TIMEOUT)
        t.assert_equals(s:count(), 0, 'nothing may land')
    end)
end

-- }}}

-- {{{ no idle dump loop

local gi = t.group('vinyl_memory_zero.idle')

gi.before_all(function(cg)
    cg.server = server:new({box_cfg = {vinyl_memory = 0}})
    cg.server:start()
end)

gi.after_all(function(cg)
    cg.server:drop()
end)

gi.test_idle_instance_does_not_dump = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        -- Sample the dump counter across many quota-timer periods
        -- (0.1s each) and require it to stay put.
        local before = box.stat.vinyl().scheduler.dump_count
        fiber.sleep(1)
        local after = box.stat.vinyl().scheduler.dump_count
        t.assert_equals(after, before,
                        'an idle disabled instance must not dump')
    end)
end

-- }}}

-- {{{ internal work overshoots rather than blocks

local go = t.group('vinyl_memory_zero.overshoot')

go.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {
            vinyl_memory = 64 * 1024 * 1024,
            vinyl_timeout = 0.5,
        },
    })
    cg.server:start()
    -- Commit rows under a real quota and flush them to disk.
    cg.server:exec(function()
        local s = box.schema.space.create('seed', {engine = 'vinyl'})
        s:create_index('pk')
        for i = 1, 100 do s:insert({i, i}) end
        box.snapshot()
    end)
    -- Reopen with the engine disabled; the rows now live on disk.
    cg.server:restart({
        box_cfg = {
            vinyl_memory = 0,
            vinyl_timeout = 0.5,
        },
    })
end)

go.after_all(function(cg)
    cg.server:drop()
end)

go.test_index_build_over_existing_data_completes = function(cg)
    cg.server:exec(function()
        local s = box.space.seed
        -- Building a secondary index reads the on-disk rows and writes
        -- one entry per row. Those entries must land for the index to
        -- be correct, so the build proceeds and overshoots the zero
        -- quota instead of blocking forever on it.
        s:create_index('sk', {parts = {{2, 'unsigned'}}})
        t.assert_equals(s.index.sk:count(), 100,
                        'index build must complete at vinyl_memory = 0')
        -- A user write is still refused.
        local ok, err = pcall(s.insert, s, {101, 101})
        t.assert_not(ok, 'a user write must not be admitted')
        t.assert_equals(err.code, box.error.VY_QUOTA_TIMEOUT)
    end)
end

-- }}}
