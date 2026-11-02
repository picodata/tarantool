local t = require('luatest')

local common = require('test.replication-luatest.qpromote_common')

local g = common.make_test_group({nodes = 3, quorum = 2})

local function upstream_of(server, source)
    return server:exec(function(id)
        return box.info.replication[id].upstream
    end, {source:get_instance_id()})
end

-- A master of a synchronous replicaset is restarted under write load and
-- comes back with a tail of unconfirmed transactions the replicas haven't
-- received. Meanwhile a replica is promoted, and while its PROMOTE waits
-- for a quorum, the tail reaches it through the other replica.
--
-- Before fix:
-- The new leader rejected the tail with ER_SYNC_QUEUE_UNCLAIMED, which
-- stopped all its appliers. It never learned the tail, so the others
-- refused to vote for it in the next elections. Test fails.
-- After fix:
-- Test passes.
--
-- n1 is the old master, n3 is the new one, n2 is the other replica.
g.test_accept_owner_txns_while_promoting = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote(n1)
    n1:exec(function()
        box.space.test:replace({1})
    end)
    n2:wait_for_vclock_of(n1)
    n3:wait_for_vclock_of(n1)

    -- n1 goes away and leaves a tail nobody has.
    common.server_set_replication(n1, {})
    common.make_connected_mesh({n2, n3})
    local tail_lsn = n1:exec(function()
        local lsn = box.info.lsn
        require('fiber').new(function()
            box.space.test:replace({2})
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.lsn, lsn + 1)
        end)
        return box.info.lsn
    end)

    -- n3 wins the elections with n2's vote. n2 stops following n3 before
    -- the PROMOTE is written, so the PROMOTE can't gather a quorum yet.
    common.spawn_stuck_promote(n3)
    common.server_set_replication(n2, {})
    common.remove_wal_delay_on_xrow_type(n3)
    common.wait_for_promote_queue_len(n3, 1)

    -- n1 comes back. It learns the new term first, so that it doesn't
    -- confirm the tail once n2 acks it.
    common.server_set_replication(n1, {n2.net_box_uri})
    local term = n3:exec(function()
        return box.info.election.term
    end)
    t.helpers.retrying({}, function()
        t.assert_equals(n1:exec(function()
            return box.info.election.term
        end), term)
    end)

    -- n2 gets the tail and relays it to n3, whose PROMOTE is pending.
    common.server_set_replication(n2, {n1.net_box_uri})
    t.helpers.retrying({}, function()
        local lsn = n3:exec(function(id)
            return box.info.vclock[id] or 0
        end, {n1:get_instance_id()})
        t.assert_equals(lsn, tail_lsn, ('n3 has not applied the tail of ' ..
                        'n1, upstream: %s'):format(
                        require('json').encode(upstream_of(n3, n2))))
    end)
    t.assert_equals(upstream_of(n3, n2).status, 'follow')
    common.wait_for_promote_queue_len(n3, 1)

    -- The PROMOTE gathers a quorum, n3 takes over the queue and rolls the
    -- tail back.
    common.make_connected_mesh(g.cluster.servers)
    common.wait_for_promote_queue_len(n3, 0)
    n3:exec(function()
        t.assert_equals(box.info.election.state, 'leader')
        t.assert_equals(box.info.synchro.queue.owner, box.info.id)
        box.ctl.wait_rw()
        t.assert_equals(box.space.test:get({2}), nil)
        box.space.test:replace({3})
    end)

    n1:wait_for_vclock_of(n3)
    n2:wait_for_vclock_of(n3)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
    for _, server in ipairs(g.cluster.servers) do
        t.assert_equals(server:exec(function()
            return box.space.test:select()
        end), {{1}, {3}})
    end
end

local function election_term(server)
    return server:exec(function()
        return box.info.election.term
    end)
end

-- The PROMOTE gathers a quorum, n3 takes the queue over, and the others catch
-- up with it.
local function finish_promote(g)
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.make_connected_mesh(g.cluster.servers)
    common.wait_for_promote_queue_len(n3, 0)
    n3:exec(function()
        t.assert_equals(box.info.synchro.queue.owner, box.info.id)
        t.assert_equals(box.info.synchro.queue.len, 0)
    end)
    n1:wait_for_vclock_of(n3)
    n2:wait_for_vclock_of(n3)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
end

-- n3 subscribes straight to n1, which still lives in the old term, and acks
-- its tail. That's a quorum for the tail on n1. But the acks of n3 carry the
-- new term, so n1 freezes the queue and doesn't confirm a transaction which the
-- pending PROMOTE is going to roll back. This is what makes accepting the tail
-- while promoting safe.
g.test_promoter_ack_does_not_let_old_owner_confirm = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]
    local n1_id = n1:get_instance_id()
    local n3_id = n3:get_instance_id()

    common.promote_and_cut_off(n1, n2, n3)
    local tail_lsn = common.spawn_sync_write(n1, 1)
    common.write_pending_promote(n2, n3)
    local term = election_term(n3)
    t.assert_lt(election_term(n1), term)
    local confirmed_lsn = n1:exec(function()
        return box.info.synchro.queue.confirmed_lsn
    end)

    common.server_set_replication(n3, {n1.net_box_uri})
    common.wait_for_row_in_queue(n3, n1, tail_lsn, 1)
    n1:exec(function(n3_id, n1_id, tail_lsn)
        t.helpers.retrying({}, function()
            local downstream = box.info.replication[n3_id].downstream
            t.assert_ge(downstream.vclock[n1_id] or 0, tail_lsn)
        end)
    end, {n3_id, n1_id, tail_lsn})
    -- Give a CONFIRM, if there is one, time to be written.
    n1:exec(function(term, confirmed_lsn)
        require('fiber').sleep(0.2)
        t.assert_equals(box.info.synchro.queue.len, 1)
        t.assert_equals(box.info.synchro.queue.confirmed_lsn, confirmed_lsn)
        t.assert_equals(box.info.election.term, term)
    end, {term, confirmed_lsn})
    t.assert_equals(common.sync_write_result(n1, 1), {status = 'pending'})

    finish_promote(g)
    t.assert_equals(common.sync_write_result(n1, 1),
                    {status = 'error', code = box.error.SYNC_ROLLBACK})
    for _, server in ipairs(g.cluster.servers) do
        t.assert_equals(server:exec(function()
            return box.space.test:get({1})
        end), nil)
    end
end

-- Same setup, but n1's quorum is lowered by hand while n3's PROMOTE is
-- pending, so n1 confirms its tail before anyone can freeze its queue. With
-- the quorum left alone n1 doesn't get here, see the test above.
--
-- n3 ignores the CONFIRM: while a PROMOTE is pending, the CONFIRM may be the
-- one of a PROMOTE, so txn_limbo_filter_confirm() lets it through, and it
-- confirms nothing. The PROMOTE then rolls back the tail n1 has confirmed, and
-- it's n1 which finds out, once it gets the PROMOTE. The test pins this: the
-- instances disagree on the tail, and n1 stops instead of following.
g.test_old_owner_confirm_reaches_promoter = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]
    local n1_id = n1:get_instance_id()

    common.promote_and_cut_off(n1, n2, n3)
    local tail_lsn = common.spawn_sync_write(n1, 1)
    common.write_pending_promote(n2, n3)

    common.server_set_synchro_quorum(n1, 1)
    n1:exec(function()
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 0)
        end)
    end)
    t.assert_equals(common.sync_write_result(n1, 1), {status = 'ok'})

    -- The CONFIRM follows the tail in n1's WAL. The tail stays in n3's queue.
    common.server_set_replication(n3, {n1.net_box_uri})
    common.wait_for_row_in_queue(n3, n1, tail_lsn + 1, 1)
    n3:exec(function(n1_id)
        t.assert_equals(box.info.replication[n1_id].upstream.status, 'follow')
        t.assert_equals(box.info.synchro.queue.owner, n1_id)
    end, {n1_id})
    common.wait_for_promote_queue_len(n3, 1)

    -- The PROMOTE doesn't cover the tail and rolls it back.
    common.server_set_replication(n2, {n3.net_box_uri})
    common.wait_for_promote_queue_len(n3, 0)
    n2:wait_for_vclock_of(n3)
    for _, server in ipairs({n2, n3}) do
        server:exec(function(n3_id)
            t.helpers.retrying({}, function()
                t.assert_equals(box.info.synchro.queue.owner, n3_id)
                t.assert_equals(box.info.synchro.queue.len, 0)
            end)
            t.assert_equals(box.space.test:get({1}), nil)
        end, {n3:get_instance_id()})
    end

    -- n1 keeps the tail and refuses the PROMOTE.
    common.server_set_replication(n1, {n3.net_box_uri})
    t.helpers.retrying({}, function()
        local upstream = upstream_of(n1, n3)
        t.assert_equals(upstream.status, 'stopped')
        t.assert_str_contains(upstream.message, 'Split-Brain discovered: ' ..
                              'got a request with lsn from an already ' ..
                              'processed range')
    end)
    n1:exec(function(n1_id)
        t.assert_equals(box.info.synchro.queue.owner, n1_id)
        t.assert_equals(box.space.test:get({1}), {1})
    end, {n1_id})
end

-- n1 times out and rolls its tail back before n3 subscribes to it. Had n3
-- subscribed first, its ack would have frozen n1's queue, and n1 could never
-- time out. n3 gets both the tail and the ROLLBACK while its PROMOTE is
-- pending, and the PROMOTE stays pending.
g.test_old_owner_rollback_reaches_promoter = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote_and_cut_off(n1, n2, n3)
    local tail_lsn = common.spawn_sync_write(n1, 1)
    common.write_pending_promote(n2, n3)

    n1:exec(function()
        box.cfg{replication_synchro_timeout = 0.01}
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 0)
        end)
        box.cfg{replication_synchro_timeout = 100000}
    end)
    t.assert_equals(common.sync_write_result(n1, 1),
                    {status = 'error', code = box.error.SYNC_QUORUM_TIMEOUT})

    -- The ROLLBACK follows the tail in n1's WAL.
    common.server_set_replication(n3, {n1.net_box_uri})
    common.wait_for_row_in_queue(n3, n1, tail_lsn + 1, 0)
    n3:exec(function(n1_id)
        t.assert_equals(box.info.replication[n1_id].upstream.status, 'follow')
        t.assert_equals(box.space.test:get({1}), nil)
        t.assert_equals(box.info.synchro.queue.owner, n1_id)
    end, {n1:get_instance_id()})
    common.wait_for_promote_queue_len(n3, 1)

    common.server_set_replication(n2, {n3.net_box_uri})
    common.wait_for_promote_queue_len(n3, 0)
    n3:exec(function()
        t.assert_equals(box.info.synchro.queue.owner, box.info.id)
    end)

    finish_promote(g)
end

-- Another instance takes the queue over while n3's PROMOTE is pending with
-- n1's tail in the queue. The instances have to agree on the outcome no matter
-- how far the PROMOTE of n3 got.
g.test_competing_promote_with_tail = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote_and_cut_off(n1, n2, n3)
    local tail_lsn = common.spawn_sync_write(n1, 1)
    common.write_pending_promote(n2, n3)
    common.deliver_tail_through_replica(n1, n2)
    common.wait_for_row_in_queue(n3, n1, tail_lsn, 1)

    common.make_connected_mesh(g.cluster.servers)
    common.promote(n2)
    n2:exec(function()
        box.space.test:replace({2})
    end)

    n1:wait_for_vclock_of(n2)
    n3:wait_for_vclock_of(n2)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
    for _, server in ipairs(g.cluster.servers) do
        server:exec(function(n2_id)
            t.assert_equals(box.info.synchro.queue.owner, n2_id)
            t.assert_equals(box.info.synchro.queue.len, 0)
            t.assert_equals(box.space.test:select(), {{2}})
        end, {n2:get_instance_id()})
    end
    t.assert_equals(common.sync_write_result(n1, 1),
                    {status = 'error', code = box.error.SYNC_ROLLBACK})
end

-- An ack for the pending PROMOTE arrives while n3 is writing the ROLLBACK of
-- the old owner. The limbo can't count it at this moment: the ack either waits
-- for the promote latch or gets dropped by the is_in_rollback check, in which
-- case it has to be seen as new when the relay sends it again. It must not get
-- lost: n3 is read-only until the PROMOTE is applied, so there would be no
-- newer row for n2 to ack, and the PROMOTE would stay pending forever.
g.test_promote_ack_during_guarded_rollback = function(g)
    t.tarantool.skip_if_not_debug()
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]
    local n2_id = n2:get_instance_id()
    local n3_id = n3:get_instance_id()

    common.promote_and_cut_off(n1, n2, n3)
    common.spawn_sync_write(n1, 1)
    common.write_pending_promote(n2, n3)
    local promote_lsn = n3:exec(function()
        return box.info.synchro.promote_queue.items[1].self_lsn
    end)

    n1:exec(function()
        box.cfg{replication_synchro_timeout = 0.01}
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 0)
        end)
        box.cfg{replication_synchro_timeout = 100000}
    end)

    -- n2 gets the PROMOTE and gets stuck on writing it, so its ack is held
    -- back. Subscribing waits for a WAL sync on the master, so n2 has to do
    -- this before n3's WAL gets stuck. Don't wait for the sync with n3, as
    -- n2's own WAL is stuck.
    n2:exec(function(replication)
        box.error.injection.set('ERRINJ_WAL_DELAY_ON_XROW_TYPE',
                                box.iproto.type.RAFT_PROMOTE)
        box.cfg{replication_sync_timeout = 0.01}
        box.cfg{replication = replication}
    end, {{n3.net_box_uri}})
    common.errinj_wait(n2, 'ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP',
                       'expected RAFT_PROMOTE')

    -- n3 gets the tail and gets stuck on writing the ROLLBACK following it.
    n3:exec(function(replication)
        box.error.injection.set('ERRINJ_WAL_DELAY_ON_XROW_TYPE',
                                box.iproto.type.RAFT_ROLLBACK)
        box.cfg{replication_sync_timeout = 0.01}
        box.cfg{replication = replication}
    end, {{n1.net_box_uri}})
    common.errinj_wait(n3, 'ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP',
                       'expected RAFT_ROLLBACK')

    -- n2's ack reaches n3 and doesn't count yet.
    common.remove_wal_delay_on_xrow_type(n2)
    n3:exec(function(n2_id, n3_id, promote_lsn)
        t.helpers.retrying({}, function()
            local downstream = box.info.replication[n2_id].downstream
            t.assert_equals(downstream.vclock[n3_id], promote_lsn)
        end)
        local items = box.info.synchro.promote_queue.items
        t.assert_equals(#items, 1)
        t.assert_equals(items[1].ack_count, 1)
    end, {n2_id, n3_id, promote_lsn})

    -- Once the ROLLBACK is written, the ack counts with no new rows from n3.
    common.remove_wal_delay_on_xrow_type(n3)
    common.wait_for_promote_queue_len(n3, 0)
    n3:exec(function()
        t.assert_equals(box.info.synchro.queue.owner, box.info.id)
        t.assert_equals(box.info.synchro.queue.len, 0)
        t.assert_equals(box.space.test:get({1}), nil)
    end)

    finish_promote(g)
end
