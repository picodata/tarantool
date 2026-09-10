local server = require('luatest.server')
local t = require('luatest')

-- `server:exec()` ships the function to the server without its upvalues, so
-- the helper has to be installed there as a global.
local function install_helper(cg)
    cg.server:exec(function()
        rawset(_G, 'sync_wal_txn', function(f)
            box.begin{flags = box.internal.TXN_SYNC_WAL}
            local ok, err = pcall(f)
            if not ok then
                box.rollback()
                error(err)
            end
            box.commit()
        end)
        rawset(_G, 'sync_wal_count', function()
            return box.error.injection.get('ERRINJ_SYNC_WAL_COUNT')
        end)
    end)
end

local g = t.group('txn_sync_wal')

g.before_each(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new({alias = 'master', box_cfg = {wal_mode = 'write'}})
    cg.server:start()
    install_helper(cg)
    cg.server:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')
    end)
end)

g.after_each(function(cg)
    cg.server:drop()
end)

-- Only a transaction that asked for it is flushed to stable storage.
g.test_only_marked_txns_are_flushed = function(cg)
    cg.server:exec(function()
        local before = _G.sync_wal_count()
        box.space.test:insert{1}
        t.assert_equals(_G.sync_wal_count(), before,
                        'an ordinary transaction does not trigger a flush')

        _G.sync_wal_txn(function() box.space.test:insert{2} end)
        t.assert_equals(_G.sync_wal_count(), before + 1,
                        'a TXN_SYNC_WAL transaction triggers a flush')
    end)
end

-- The flag is per transaction, not per statement: one flush covers the batch.
g.test_flag_covers_whole_txn = function(cg)
    cg.server:exec(function()
        local before = _G.sync_wal_count()
        _G.sync_wal_txn(function()
            for i = 1, 10 do
                box.space.test:insert{i}
            end
        end)
        t.assert_equals(_G.sync_wal_count(), before + 1)
        t.assert_equals(box.space.test:count(), 10)
    end)
end

-- The flush must happen before the commit is reported to tx.
g.test_flush_is_on_the_commit_path = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        box.error.injection.set('ERRINJ_SYNC_WAL_HIT', false)
        box.error.injection.set('ERRINJ_SYNC_WAL_DELAY', true)

        local committed = false
        fiber.create(function()
            _G.sync_wal_txn(function() box.space.test:insert{1} end)
            committed = true
        end)

        -- The WAL thread sets the HIT injection once it is inside the flush,
        -- so this waits for the barrier itself rather than for a timeout.
        t.helpers.retrying({}, function()
            t.assert(box.error.injection.get('ERRINJ_SYNC_WAL_HIT'),
                     'the flush was reached')
        end)
        t.assert_not(committed, 'the commit has not returned yet')

        box.error.injection.set('ERRINJ_SYNC_WAL_DELAY', false)
        t.helpers.retrying({}, function()
            t.assert(committed)
        end)
    end)
end

local g_fsync = t.group('txn_sync_wal_wal_mode_fsync')

g_fsync.before_all(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new({alias = 'master', box_cfg = {wal_mode = 'fsync'}})
    cg.server:start()
    install_helper(cg)
end)

g_fsync.after_all(function(cg)
    cg.server:drop()
end)

-- Under wal_mode = 'fsync' the xlog is already opened with O_SYNC, so there is
-- nothing left for the barrier to do.
g_fsync.test_no_extra_flush = function(cg)
    cg.server:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')

        local before = _G.sync_wal_count()
        _G.sync_wal_txn(function() box.space.test:insert{1} end)
        t.assert_equals(_G.sync_wal_count(), before)
    end)
end

-- Two flagged transactions landing in one WAL batch are made durable by a
-- single flush: the flush is a property of the batch, not of the entry.
g.test_one_flush_per_batch = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local before = _G.sync_wal_count()
        -- Both fibers reach the journal within one event loop iteration,
        -- so their entries queue up into the same WAL batch.
        local fibers = {}
        for i = 1, 2 do
            fibers[i] = fiber.new(function()
                _G.sync_wal_txn(function() box.space.test:insert{i} end)
            end)
            fibers[i]:set_joinable(true)
        end
        for i = 1, 2 do
            fibers[i]:join()
        end
        t.assert_equals(_G.sync_wal_count(), before + 1)
        t.assert_equals(box.space.test:count(), 2)
    end)
end

local g_none = t.group('txn_sync_wal_wal_mode_none')

g_none.before_all(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new({alias = 'master', box_cfg = {wal_mode = 'none'}})
    cg.server:start()
    install_helper(cg)
end)

g_none.after_all(function(cg)
    cg.server:drop()
end)

-- Under wal_mode = 'none' there is no file to flush: the flag is ignored and
-- the transaction commits as usual.
g_none.test_flag_is_ignored = function(cg)
    cg.server:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')

        local before = _G.sync_wal_count()
        _G.sync_wal_txn(function() box.space.test:insert{1} end)
        t.assert_equals(_G.sync_wal_count(), before)
        t.assert_equals(box.space.test:get(1), {1})
    end)
end
