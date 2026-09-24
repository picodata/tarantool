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
