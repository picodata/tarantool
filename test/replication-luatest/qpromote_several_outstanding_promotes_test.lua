local t = require('luatest')
local common = require('test.replication-luatest.qpromote_common')

local g = common.make_test_group({nodes=5, quorum=3})

-- The idea here is that in a cluster of 5 nodes we can have 2 nodes
-- being unresponsive and cluster still should continue. In this case two
-- nodes become unresponsive by emitting promotes that get stuck.
g.test_two_stuck_outstanding_promotes = function(g)
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    -- Both n1 and n2 have hard time pushing out their promotes.
    common.spawn_stuck_promote(n1)
    common.spawn_stuck_promote(n2)

    common.promote(n3)

    n3:exec(function()
        box.space.test:replace({ 1 })
    end)

    common.remove_wal_delay_on_xrow_type(n1)
    common.remove_wal_delay_on_xrow_type(n2)

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n3)

        t.assert_equals(server:exec(function()
            return box.space.test:get { 1 }
        end), { 1 })
    end

    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)

    common.promote(n1)
    n1:exec(function()
        box.space.test:replace({ 2 })
    end)

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n1)
        t.assert_equals(server:exec(function()
            return box.space.test:get { 2 }
        end), { 2 })
    end

    common.ensure_healthy(g.cluster.servers)
end

-- Variation of the previous test, but here nodes get stuck on confirm request
g.test_two_stuck_outstanding_confirms = function(g)
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    -- Both n1 and n2 have hard time pushing out their confirms.
    common.spawn_promote_stuck_on_confirm(n1)
    common.spawn_promote_stuck_on_confirm(n2)

    common.promote(n3)

    n3:exec(function()
        box.space.test:replace({ 1 })
    end)

    common.remove_wal_delay_on_xrow_type(n1)
    common.remove_wal_delay_on_xrow_type(n2)

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n3)

        t.assert_equals(server:exec(function()
            return box.space.test:get { 1 }
        end), { 1 })
    end

    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)

    common.promote(n1)
    n1:exec(function()
        box.space.test:replace({ 2 })
    end)

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n1)
        t.assert_equals(server:exec(function()
            return box.space.test:get { 2 }
        end), { 2 })
    end

    common.ensure_healthy(g.cluster.servers)
end

-- Test that the async CONFIRM worker doesn't crash after a promote from a
-- node with a high vclock component.
--
-- The bug scenario:
-- 1. n3 is leader and writes many synchro entries, bumping its vclock
--    component to ~100+
-- 2. n2 promotes, becoming leader. confirmed_lsn = volatile_confirmed_lsn =
--    n2's promote self_lsn (low, ~5, because n2 hasn't written much)
-- 3. Block the async CONFIRM worker on n2
-- 4. n3 promotes again. Its self_lsn is ~104 (high vclock component).
--    txn_limbo_apply_promote on n2 sets confirmed_lsn = 104
-- 5. Without the fix: volatile_confirmed_lsn stays at ~5. Worker resumes,
--    assert(volatile_confirmed_lsn >= confirmed_lsn) fires: 5 >= 104 → crash
-- 6. With the fix: volatile_confirmed_lsn = confirmed_lsn = 104, passes
g.test_worker_resumes_after_promote = function(g)
    local n2 = g.cluster.servers[2]
    local n3 = g.cluster.servers[3]

    -- Promote n3 and have it write many entries to bump its vclock component.
    common.promote(n3)
    local nwrites = 100
    n3:exec(function(n)
        for i = 1, n do
            box.space.test:replace({i})
        end
    end, {nwrites})

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n3)
    end

    -- Promote n2. After this, n2's volatile_confirmed_lsn and confirmed_lsn
    -- are both set to n2's promote self_lsn — a low value, because n2's own
    -- vclock component has barely been incremented.
    common.promote(n2)

    -- Block the async CONFIRM worker on n2.
    n2:exec(function()
        box.error.injection.set('ERRINJ_TXN_LIMBO_WORKER_DELAY', true)
    end)

    -- Promote n3 again. n3's promote self_lsn is now ~104 (100 data entries +
    -- a few synchro entries from the earlier promote). On n2,
    -- txn_limbo_apply_promote sets confirmed_lsn = ~104, but WITHOUT the fix,
    -- volatile_confirmed_lsn stays at ~5 (from n2's promote).
    common.promote(n3)

    -- Unblock the worker on n2. Without the fix, the worker wakes up and
    -- assert(volatile_confirmed_lsn >= confirmed_lsn) fires: ~5 >= ~104.
    -- n2 crashes. With the fix, both are ~104, assertion passes.
    n2:exec(function()
        box.error.injection.set('ERRINJ_TXN_LIMBO_WORKER_DELAY', false)
    end)

    -- If n2 crashed, this exec will fail.
    n2:exec(function() end)

    -- Verify n3 can write as the new leader.
    n3:exec(function()
        box.space.test:replace({200})
    end)

    for _, server in ipairs(g.cluster.servers) do
        server:wait_for_vclock_of(n3)
        t.assert_equals(server:exec(function()
            return box.space.test:get{200}
        end), {200})
    end

    t.helpers.retrying({}, function()
        common.ensure_healthy(g.cluster.servers)
    end)
end

g.test_two_dependent_promotes = function (g)
    local n1 = g.cluster.servers[1]
    local n2 = g.cluster.servers[2]

    -- emit promote without confirming it
    common.spawn_promote_stuck_on_confirm(n1)

    -- wait until everybody has this pending promote
    for _, server in ipairs(g.cluster.servers) do
        common.wait_for_promote_queue_len(server, 1)
    end

    -- n2's promote is logicaly dependent on n1's promote
    common.promote(n2)

    common.remove_wal_delay_on_xrow_type(n1)

    common.ensure_healthy(g.cluster.servers)
end
