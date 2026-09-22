local t = require('luatest')
local fio = require('fio')
local server = require('luatest.server')
local replica_set = require('luatest.replica_set')

--
-- Whether a replicated transaction enters the synchro queue is decided by
-- the queue owner and travels in the flags of the transaction's last row.
-- The applier must mirror that decision rather than re-derive it from the
-- local state of the spaces, which can disagree with the master's:
--
-- * the master may write to a synchronous space with TXN_FORCE_ASYNC, so it
--   never queues the transaction and never CONFIRMs it;
-- * a transaction may be synchronous on the master while the space it
--   touches is not synchronous on the replica.
--
-- A transaction queued on the replica but not on the master waits for a
-- CONFIRM. During join it waits forever: the replica makes its initial
-- checkpoint, which waits for the queue to drain, before it subscribes
-- and could ever receive a CONFIRM.
--

-- See src/box/txn.h.
local TXN_WAIT_SYNC = 0x10
local TXN_WAIT_ACK = 0x20

local g = t.group('qsync-applier-mirrors-master-flags')

g.before_each(function(cg)
    cg.replica_set = replica_set:new{}
    cg.box_cfg = {
        election_mode = 'off',
        replication_timeout = 0.1,
        replication_synchro_quorum = 1,
        replication_synchro_timeout = 1000,
    }
    cg.master = cg.replica_set:build_and_add_server{
        alias = 'master',
        box_cfg = cg.box_cfg,
    }
    cg.master:start()
    cg.master:exec(function()
        box.ctl.promote()
        box.ctl.wait_rw()
        box.schema.space.create('sync', {is_sync = true})
        box.space.sync:create_index('pk')
        box.schema.space.create('async')
        box.space.async:create_index('pk')
        box.schema.space.create('loc', {is_local = true})
        box.space.loc:create_index('pk')
    end)
end)

g.after_each(function(cg)
    cg.replica_set:drop()
end)

local function add_replica(cg, opts)
    local box_cfg = table.deepcopy(cg.box_cfg)
    box_cfg.replication = {
        server.build_listen_uri('master', cg.replica_set.id),
    }
    cg.replica = cg.replica_set:build_and_add_server{
        alias = 'replica',
        box_cfg = box_cfg,
    }
    cg.replica:start(opts)
end

--
-- Start a replica and stop the master's JOIN handler right after the
-- replica is registered in _cluster.
--
local function join_replica_with_final_join_write(cg, write)
    cg.master:exec(function()
        box.error.injection.set('ERRINJ_REPLICA_JOIN_DELAY', true)
    end)
    add_replica(cg, {wait_until_ready = false})
    cg.master:exec(function(write)
        t.helpers.retrying({}, function()
            t.assert_equals(box.space._cluster:count(), 2)
        end)
        loadstring(write)()
        box.error.injection.set('ERRINJ_REPLICA_JOIN_DELAY', false)
    end, {write})
    -- The replica cannot be queried until it has bootstrapped, so watch its
    -- log instead. A replica stuck in its initial checkpoint never gets here.
    local log = fio.pathjoin(cg.replica.workdir, cg.replica.alias .. '.log')
    t.helpers.retrying({timeout = 30}, function()
        t.assert(cg.replica:grep_log('ready to accept requests', nil,
                                     {filename = log}),
                 'replica finished bootstrap')
    end)
    cg.replica:wait_until_ready()
end

local function check_replica_queue_empty_and_checkpoints(cg)
    cg.replica:exec(function()
        t.assert_equals(box.info.synchro.queue.len, 0)
        -- Would wait for replication_synchro_timeout on a non-empty queue.
        box.snapshot()
    end)
end

g.test_force_async_alter_to_sync_during_final_join = function(cg)
    t.tarantool.skip_if_not_debug()
    join_replica_with_final_join_write(cg, [[
        box.begin{flags = box.internal.TXN_FORCE_ASYNC}
        box.space.async:alter{is_sync = true}
        box.space.async:replace{1}
        box.commit()
    ]])
    cg.replica:exec(function()
        t.assert(box.space.async.is_sync)
        t.assert_equals(box.space.async:get{1}, {1})
    end)
    check_replica_queue_empty_and_checkpoints(cg)
end

g.test_force_async_write_to_subscribed_replica = function(cg)
    add_replica(cg)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.master:exec(function()
        box.begin{flags = box.internal.TXN_FORCE_ASYNC}
        box.space.sync:replace{1}
        box.commit()
    end)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.replica:exec(function()
        t.assert_equals(box.space.sync:get{1}, {1})
    end)
    check_replica_queue_empty_and_checkpoints(cg)
end

-- An async transaction submitted during a CONFIRM write still carries
-- WAIT_SYNC, but its WAL row follows the CONFIRM. There is no dependency
-- left when the replica applies it or the master recovers it from WAL.
g.test_async_txn_after_confirm = function(cg)
    t.tarantool.skip_if_not_debug()
    add_replica(cg)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.master:exec(function()
        local fiber = require('fiber')
        box.error.injection.set('ERRINJ_WAL_DELAY_COUNTDOWN', 1)
        local sync = fiber.create(function() box.space.sync:replace{1} end)
        sync:set_joinable(true)
        t.helpers.retrying({}, function()
            t.assert(box.error.injection.get('ERRINJ_WAL_DELAY'))
        end)
        local async = fiber.create(function() box.space.async:replace{1} end)
        async:set_joinable(true)
        t.assert_equals(box.info.synchro.queue.len, 2)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        t.assert(sync:join())
        t.assert(async:join())
        t.assert_equals(box.info.synchro.queue.len, 0)
    end)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.replica:exec(function()
        t.assert_equals(box.space.sync:get{1}, {1})
        t.assert_equals(box.space.async:get{1}, {1})
    end)
    check_replica_queue_empty_and_checkpoints(cg)

    -- The master's original WAL retains WAIT_SYNC on the async row.
    -- Restart without a checkpoint to exercise the recovery path too.
    cg.master:restart()
    cg.master:exec(function()
        t.assert_equals(box.info.synchro.queue.len, 0)
        t.assert_equals(box.space.sync:get{1}, {1})
        t.assert_equals(box.space.async:get{1}, {1})
        box.snapshot()
    end)
end

local SYNC_TXN_ON_ASYNC_SPACE = ([[
    box.begin{flags = %d}
    box.space.async:replace{1}
    box.commit()
]]):format(bit.bor(TXN_WAIT_SYNC, TXN_WAIT_ACK))

local function wait_queue_len(server, len)
    server:exec(function(len)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, len)
        end)
    end, {len})
end

local function check_row(server, space, key, expected)
    server:exec(function(space, key, expected)
        t.assert_equals(box.space[space]:get{key}, expected)
    end, {space, key, expected})
end

--
-- Run the write in a fiber on the master and leave its transaction waiting for
-- a quorum. The master gets acks only from its direct replica, so it can't
-- gather a quorum of three.
--
local function spawn_pending_txn(cg, write)
    cg.master:exec(function(write)
        box.cfg{replication_synchro_quorum = 3}
        local len = box.info.synchro.queue.len
        require('fiber').create(pcall, loadstring(write))
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, len + 1)
        end)
    end, {write})
end

local function roll_back_pending_txns(cg)
    cg.master:exec(function()
        box.cfg{replication_synchro_timeout = 0.01}
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 0)
        end)
    end)
end

local function add_synced_replica(cg)
    add_replica(cg)
    cg.replica:wait_for_vclock_of(cg.master)
end

--
-- A transaction which is synchronous on the master while the space is not
-- synchronous anywhere has to wait for the master's decision on the replica
-- too, otherwise the replica commits what the master rolls back.
--
g.test_sync_txn_on_async_space_rollback = function(cg)
    add_synced_replica(cg)
    spawn_pending_txn(cg, SYNC_TXN_ON_ASYNC_SPACE)
    wait_queue_len(cg.replica, 1)

    roll_back_pending_txns(cg)
    cg.replica:wait_for_vclock_of(cg.master)
    wait_queue_len(cg.replica, 0)
    check_row(cg.master, 'async', 1, nil)
    check_row(cg.replica, 'async', 1, nil)
end

--
-- The master writes the flags of a transaction to its last row, which is a
-- local one here and isn't sent to the replica. The relay has to move them to
-- the last row it does send, because that's where the applier takes them from.
--
g.test_sync_then_local_row_rollback = function(cg)
    add_synced_replica(cg)
    spawn_pending_txn(cg, [[
        box.begin()
        box.space.sync:replace{1}
        box.space.loc:replace{1}
        box.commit()
    ]])
    wait_queue_len(cg.replica, 1)

    roll_back_pending_txns(cg)
    cg.replica:wait_for_vclock_of(cg.master)
    wait_queue_len(cg.replica, 0)
    check_row(cg.master, 'sync', 1, nil)
    check_row(cg.master, 'loc', 1, nil)
    check_row(cg.replica, 'sync', 1, nil)
    check_row(cg.replica, 'loc', 1, nil)
end

--
-- A trigger or replication_skip_conflict on the replica may turn all the rows
-- of a synchronous transaction into NOPs. The transaction still has to enter
-- the queue as on the master. Otherwise the master's CONFIRM for it falls
-- outside the queue, and the replica takes it for a split-brain and stops the
-- applier.
--
g.test_sync_txn_of_nops_only = function(cg)
    add_synced_replica(cg)
    cg.replica:exec(function()
        box.space.sync:before_replace(function(old) return old end)
    end)
    -- The write returns once the CONFIRM for it is written.
    local id, lsn = cg.master:exec(function()
        box.space.sync:replace{1}
        return box.info.id, box.info.lsn
    end)
    cg.replica:exec(function(id, lsn)
        t.helpers.retrying({}, function()
            local upstream = box.info.replication[id].upstream
            t.assert_equals(upstream.status, 'follow', upstream.message)
            t.assert_equals(box.info.vclock[id], lsn)
        end)
        t.assert_equals(box.info.synchro.queue.len, 0)
        t.assert_equals(box.space.sync:get{1}, nil)
    end, {id, lsn})
end
