local t = require('luatest')

local common = require('test.replication-luatest.qpromote_common')

local g = common.make_test_group({nodes = 3, quorum = 2})

-- Write to a local space in a fiber, so that a write waiting in the limbo
-- doesn't block the test. The outcome is kept in _G.local_write.
local function spawn_local_write(server, key)
    server:exec(function(key)
        local q = box.info.synchro.queue
        t.assert_not_equals(q.len, 0, 'the write must hit the async barrier')
        t.assert_not_equals(q.owner, box.info.id)
        rawset(_G, 'local_write', {status = 'pending'})
        require('fiber').new(function()
            local ok, err = pcall(box.space.wal_barrier.replace,
                                  box.space.wal_barrier, {key})
            _G.local_write = ok and {status = 'ok'} or
                             {status = 'error', code = err.code,
                              message = err.message}
        end)
        -- Wait until the write is either in the limbo or rejected.
        t.helpers.retrying({}, function()
            t.assert(_G.local_write.status ~= 'pending' or
                     box.info.synchro.queue.len == q.len + 1)
        end)
    end, {key})
end

local function local_write_result(server)
    return server:exec(function()
        return _G.local_write
    end)
end

-- n3 is promoting: its PROMOTE is written and waits for a quorum, while the
-- queue still belongs to n1 and isn't empty. A write to a local space on n3
-- gets WAIT_SYNC then, as a barrier behind the queued transactions.
--
-- Before fix:
-- txn_limbo_submit() rejected the write with ER_SYNC_QUEUE_UNCLAIMED, as if
-- it were a synchronous transaction of n3's own. n2 accepts the same write,
-- because the owner check lets fully local transactions in. Test fails.
-- After fix:
-- The write waits behind the queued transactions and shares their fate once
-- the PROMOTE is applied, same as on n2. Test passes.

-- The PROMOTE covers n1's transaction, so it confirms the transaction and
-- the write behind it.
g.test_local_write_behind_covered_txn = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote(n1)
    -- n1 writes a transaction everybody acks but nobody confirms.
    common.server_set_synchro_quorum(n1, 4)
    local lsn = n1:exec(function()
        local lsn = box.info.lsn
        require('fiber').new(function()
            box.space.test:replace({1})
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.lsn, lsn + 1)
        end)
        return box.info.lsn
    end)
    n2:wait_for_vclock_of(n1)
    n3:wait_for_vclock_of(n1)
    common.server_set_replication(n1, {})
    common.make_connected_mesh({n2, n3})

    -- n3 wins with n2's vote, its PROMOTE covers n1's transaction.
    common.spawn_stuck_promote(n3)
    common.server_set_replication(n2, {})
    common.remove_wal_delay_on_xrow_type(n3)
    common.wait_for_promote_queue_len(n3, 1)
    t.assert_equals(n3:exec(function(id)
        return {box.info.synchro.queue.len, box.info.vclock[id]}
    end, {n1:get_instance_id()}), {1, lsn})

    spawn_local_write(n2, 2)
    spawn_local_write(n3, 3)
    t.assert_equals(local_write_result(n2), {status = 'pending'})
    t.assert_equals(local_write_result(n3), {status = 'pending'})

    -- The PROMOTE gathers a quorum and confirms n1's transaction.
    common.make_connected_mesh({n2, n3})
    common.wait_for_promote_queue_len(n3, 0)
    n3:exec(function()
        t.assert_equals(box.info.synchro.queue.owner, box.info.id)
        t.assert_equals(box.space.test:get({1}), {1})
    end)
    t.helpers.retrying({}, function()
        t.assert_equals(local_write_result(n2), {status = 'ok'})
    end)
    t.assert_equals(local_write_result(n3), {status = 'ok'})
    t.assert_equals(n3:exec(function()
        return box.space.wal_barrier:get({3})
    end), {3})

    -- n1 learns about the PROMOTE, which confirms its transaction too.
    common.make_connected_mesh(g.cluster.servers)
    n1:wait_for_vclock_of(n3)
    common.server_set_synchro_quorum(n1, 2)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
end

-- The queued transaction is n1's tail, which reaches n3 after its PROMOTE
-- is written. The PROMOTE rolls the tail back, and the write with it.
g.test_local_write_behind_owner_tail = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote(n1)
    n2:wait_for_vclock_of(n1)
    n3:wait_for_vclock_of(n1)

    -- n1 goes away and leaves a tail nobody has.
    common.server_set_replication(n1, {})
    common.make_connected_mesh({n2, n3})
    local tail_lsn = n1:exec(function()
        local lsn = box.info.lsn
        require('fiber').new(function()
            box.space.test:replace({1})
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.lsn, lsn + 1)
        end)
        return box.info.lsn
    end)

    -- n3's PROMOTE is written but can't gather a quorum.
    common.spawn_stuck_promote(n3)
    common.server_set_replication(n2, {})
    common.remove_wal_delay_on_xrow_type(n3)
    common.wait_for_promote_queue_len(n3, 1)
    t.assert_equals(n3:exec(function()
        return box.info.synchro.queue.len
    end), 0)

    -- n1 learns the new term, so that it doesn't confirm the tail, and
    -- the tail gets to n3 through n2.
    common.server_set_replication(n1, {n2.net_box_uri})
    local term = n3:exec(function()
        return box.info.election.term
    end)
    t.helpers.retrying({}, function()
        t.assert_equals(n1:exec(function()
            return box.info.election.term
        end), term)
    end)
    common.server_set_replication(n2, {n1.net_box_uri})
    t.helpers.retrying({}, function()
        t.assert_equals(n3:exec(function(id)
            return {box.info.synchro.queue.len, box.info.vclock[id]}
        end, {n1:get_instance_id()}), {1, tail_lsn})
    end)

    spawn_local_write(n2, 2)
    spawn_local_write(n3, 3)
    t.assert_equals(local_write_result(n2), {status = 'pending'})
    t.assert_equals(local_write_result(n3), {status = 'pending'})

    -- The PROMOTE gathers a quorum and rolls the tail back.
    common.make_connected_mesh(g.cluster.servers)
    common.wait_for_promote_queue_len(n3, 0)
    t.helpers.retrying({}, function()
        t.assert_equals(local_write_result(n2).status, 'error')
    end)
    t.assert_equals(local_write_result(n2).code, box.error.SYNC_ROLLBACK)
    t.assert_equals(local_write_result(n3), local_write_result(n2))
    t.assert_equals(n3:exec(function()
        return box.space.wal_barrier:get({3})
    end), nil)

    n1:wait_for_vclock_of(n3)
    n2:wait_for_vclock_of(n3)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
end
