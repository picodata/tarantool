local t = require('luatest')

local common = require('test.replication-luatest.qpromote_common')

local g = common.make_test_group({nodes = 3, quorum = 2})

-- A synchronous transaction of a deposed leader reaches a replica that has
-- already applied the new leader's PROMOTE. applier_synchro_filter_tx()
-- turns it into a NOP, which must be applied as a plain transaction.
--
-- The applier takes the synchro flags of a transaction from its last row.
-- If the NOP kept WAIT_SYNC and WAIT_ACK of the original row, it would try
-- to enter the queue owned by the new leader, fail with
-- ER_SYNC_QUEUE_FOREIGN and stop the applier.
--
-- n1 is the old leader, n2 is the new one, n3 gets n1's row last.
g.test_stale_sync_txn_is_nopified = function(g)
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    common.promote(n1)
    n2:wait_for_vclock_of(n1)
    n3:wait_for_vclock_of(n1)

    -- n1 is cut off and writes a sync transaction nobody else has.
    common.server_set_replication(n1, {})
    common.make_connected_mesh({n2, n3})
    local stale_lsn = n1:exec(function()
        local lsn = box.info.lsn
        require('fiber').new(function()
            box.space.test:replace({1})
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.lsn, lsn + 1)
        end)
        return box.info.lsn
    end)

    -- n2 takes the queue over in a newer term.
    common.promote(n2)
    n3:wait_for_vclock_of(n2)

    -- n3 now fetches the stale row from n1.
    common.server_set_replication(n3, {n2.net_box_uri, n1.net_box_uri})
    local n1_id = n1:get_instance_id()
    t.helpers.retrying({timeout = 10}, function()
        local lsn, status, msg = n3:exec(function(id)
            local u = box.info.replication[id].upstream
            return box.info.vclock[id], u and u.status, u and u.message
        end, {n1_id})
        t.assert_equals(lsn, stale_lsn,
                        ('upstream %s: %s'):format(status, msg))
    end)
    n3:exec(function(id)
        t.assert_equals(box.info.replication[id].upstream.status, 'follow')
        t.assert_equals(box.info.synchro.queue.len, 0)
        t.assert_equals(box.space.test:get({1}), nil)
    end, {n1_id})

    -- n1 learns about the PROMOTE and rolls its transaction back.
    common.make_connected_mesh(g.cluster.servers)
    n1:wait_for_vclock_of(n2)
    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
end
