local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.after_each(function()
    if g.server ~= nil then
        g.server:drop()
        g.server = nil
    end
end)

-- A false->true enable whose journal_sync FAILS must not leave the
-- engine half-enabled. box.cfg's own rollback only restores the
-- Lua-visible box.cfg.wal_ext (the wal_ext module has no revert_cfg), so
-- the handler must also revert the engine-side global and every
-- space->wal_ext. Otherwise the engine keeps emitting old_tuple while
-- box.cfg.wal_ext reads 'off'.
g.test_failed_enable_reverts_engine_state = function()
    t.tarantool.skip_if_not_debug()
    g.server = server:new({ alias = 'master', box_cfg = { wal_ext = nil } })
    g.server:start()

    g.server:exec(function()
        local fio  = require('fio')
        local xlog = require('xlog').pairs

        local s = box.schema.space.create('test')
        s:create_index('pk')
        s:replace{ 1, 'old' }

        -- The old_tuple carried by the UPDATE row in the xlog segment
        -- that opens at the given lsn (nil if the extension is off).
        local function update_old_tuple(lsn)
            local path = fio.pathjoin(box.cfg.wal_dir,
                                      string.format('%020d.xlog', lsn))
            local upd
            for _, v in xlog(path) do
                if v.HEADER.type == 'UPDATE' and v.BODY.space_id == s.id then
                    upd = v
                end
            end
            t.assert(upd ~= nil, 'no UPDATE row found in ' .. path)
            return upd.BODY.old_tuple
        end

        -- Make the journal_sync inside the enable handler fail.
        box.error.injection.set('ERRINJ_WAL_SYNC', true)
        local ok = pcall(box.cfg, { wal_ext = { new_old = true } })
        box.error.injection.set('ERRINJ_WAL_SYNC', false)
        t.assert(not ok, 'enable must fail when journal_sync fails')

        -- (1) Engine must be back to disabled: an UPDATE must NOT carry
        --     old_tuple. Fails if the C global leaked true.
        box.snapshot()
        local lsn = box.info.lsn
        s:update({ 1 }, {{ '=', 2, 'mid' }})
        box.snapshot()
        t.assert_equals(update_old_tuple(lsn), nil,
            'after a failed enable the engine must stay disabled')

        -- (2) A retried enable now succeeds and takes effect.
        box.cfg { wal_ext = { new_old = true } }
        box.snapshot()
        local lsn2 = box.info.lsn
        s:update({ 1 }, {{ '=', 2, 'new' }})
        box.snapshot()
        t.assert(update_old_tuple(lsn2) ~= nil,
            'a retried enable must take effect (old_tuple present)')

        s:drop()
    end)
end

-- A transaction that has already reached the prepared state (passed
-- vy_tx_prepare, its rows are in the WAL pipeline) before the flip must
-- NOT be aborted: it commits normally, so any later snapshot captures
-- it. The flip flushes it via journal_sync instead of killing it.
g.test_prepared_blind_write_not_aborted_by_enable = function()
    t.tarantool.skip_if_not_debug()
    g.server = server:new({ alias = 'master', box_cfg = { wal_ext = nil } })
    g.server:start()

    g.server:exec(function()
        local fiber = require('fiber')

        local s = box.schema.space.create('t', { engine = 'vinyl' })
        s:create_index('pk')
        s:replace{ 1, 'init' }

        -- Park the WAL so a committing txn stops in the prepared state.
        box.error.injection.set('ERRINJ_WAL_DELAY', true)

        local ch = fiber.channel()
        local res = {}
        local f = fiber.new(function()
            box.begin()
            s:replace{ 1, 'blind' }
            ch:put(true)                  -- about to commit
            res.ok = pcall(box.commit)    -- prepares, then blocks in WAL
            ch:put(true)
        end)
        f:set_joinable(true)

        ch:get()                          -- txn open, blind write done
        -- Once the fiber is suspended again it has passed vy_tx_prepare.
        t.helpers.retrying({ timeout = 5 }, function()
            t.assert_equals(f:status(), 'suspended')
        end)

        -- The flip's (non-yielding) abort sweep runs before it blocks
        -- waiting for the WAL; once it is suspended the prepared txn has
        -- already survived the sweep.
        local flip = fiber.new(function()
            box.cfg{ wal_ext = { new_old = true } }
        end)
        flip:set_joinable(true)
        t.helpers.retrying({ timeout = 5 }, function()
            t.assert_equals(flip:status(), 'suspended')
        end)

        -- Release the WAL: the prepared txn commits, the flip finishes.
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        ch:get()
        f:join()
        flip:join()

        t.assert_equals(res.ok, true,
            'a txn prepared before the flip must NOT be aborted')
    end)
end
