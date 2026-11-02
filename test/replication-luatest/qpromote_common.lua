local checks = require('checks')
local t = require('luatest')
local log = require('log')
local json = require('json')
local cluster = require('luatest.replica_set')
local server = require('luatest.server')

local function server_set_replication(server, replication)
    server:exec(function(replication)
        box.cfg { replication = replication }
    end, { replication })
end

local function server_set_synchro_quorum(server, synchro_quorum)
    server:exec(function(synchro_quorum)
        box.cfg { replication_synchro_quorum = synchro_quorum }
    end, { synchro_quorum })
end

local function is_leader(server)
    return server:exec(function()
        return (box.info.election.state == 'leader')
    end)
end

local function errinj_arm(server, name)
    server:exec(function(name)
        t.assert_not(box.error.injection.get(name))
        box.error.injection.set(name, true)
    end, { name })
end

local function errinj_wait(server, name, extra)
    t.helpers.retrying({timeout = 8}, function(name, server_alias, extra)
        server:exec(function(name, server_alias, extra)
            if not box.error.injection.get(name) then
                error('errinj ' .. name .. ' is not hit yet: ' ..
                      server_alias .. ' ' .. tostring(extra))
            end
        end, name, server_alias, extra)
    end, { name, server.alias, extra })
end

local function start_wal_delay(server)
    errinj_arm(server, 'ERRINJ_WAL_DELAY')
    errinj_wait(server, 'ERRINJ_WAL_DELAY')
end


local function stop_wal_delay(server)
    server:exec(function()
        t.assert(box.error.injection.get('ERRINJ_WAL_DELAY'))
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
    end)
end

local function remove_wal_delay_on_xrow_type(server)
    server:exec(function()
        t.assert(box.error.injection.get('ERRINJ_WAL_DELAY_ON_XROW_TYPE'))
        box.error.injection.set("ERRINJ_WAL_DELAY_ON_XROW_TYPE", -1)

        t.assert(
            box.error.injection.get('ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP')
        )
        box.error.injection.set('ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP', false)
    end)
end

local function promote(server)
    -- We retry promotes. Sometimes promote can timeout
    -- when a node attempts to win elections but doesn't
    -- have good enough vclock for others to vote for
    -- that node
    t.helpers.retrying({}, function()
        local ok, err = pcall(function()
            server:exec(function()
                box.ctl.promote()
            end)
        end)
        if not ok then
            log.info("Promote failed: %s", err)
            error("Promote failed: " .. err)
        end
    end)

    t.helpers.retrying({}, function()
        server:exec(function()
            if box.info.ro then
                error("Box is ro: " .. box.info.ro_reason)
            end
        end)
    end)

    server:exec(function()
        box.ctl.wait_rw()
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.owner, box.info.id,
                "synchro queue owner mismatch")
        end)
    end)
    server:wait_for_election_leader()
end

local function spawn_promote(server)
    return server:exec(function()
        require('fiber').new(box.ctl.promote)
    end)
end

local function spawn_stuck_promote(server)
    if is_leader(server) then
        error('server ' .. server.alias .. ' is already leader, ' ..
              'emitting stuck promote will hang')
    end

    server:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY_ON_XROW_TYPE',
                                box.iproto.type.RAFT_PROMOTE)
    end)
    spawn_promote(server)
    errinj_wait(server,
                'ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP',
                'expected RAFT_PROMOTE')
end

local function spawn_promote_stuck_on_confirm(server)
    if is_leader(server) then
        error('server ' .. server.alias .. ' is already leader, ' ..
              'emitting stuck promote will hang')
    end

    server:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY_ON_XROW_TYPE',
                                box.iproto.type.RAFT_CONFIRM)
    end)
    spawn_promote(server)
    errinj_wait(server,
                'ERRINJ_WAL_DELAY_ON_XROW_TYPE_SLEEP',
                'expected RAFT_CONFIRM')
end

local function make_connected_mesh(servers)
    local replication = {}
    for _, server in ipairs(servers) do
        table.insert(replication, server.net_box_uri)
    end
    for _, server in ipairs(servers) do
        server_set_replication(server, replication)
    end
end

-- use our own wrapper instead of Server:assert_follows_upstream
-- for better error message
local function assert_follows_upstream(source, dest)
    local upstream = source:exec(function(upstream_server_id)
        return box.info.replication[upstream_server_id].upstream
    end, {dest:get_instance_id()})
    local msg = (
        '%s: server does not follow upstream: %s, upstream: %s'
    ):format(
        source.alias,
        dest.alias,
        json.encode(upstream))
    t.assert_equals(upstream.status, 'follow', msg)
end

local function ensure_mesh_replication_healthy(servers)
    for _, server1 in ipairs(servers) do
        for _, server2 in ipairs(servers) do
            if server1 ~= server2 then
                local server1_id = server1:get_instance_id()
                local server2_id = server2:get_instance_id()
                -- check for case with anon replicas
                -- just to be on safe side
                t.assert_not_equals(server1_id, server2_id)
                assert_follows_upstream(server1, server2)
            end
        end
    end
end

local function ensure_synchro_state_matches(servers)
    local base_info = nil;

    for _, server in pairs(servers) do
        local info = server:exec(function()
            return box.info.synchro
        end)

        if base_info == nil then
            base_info = info
        else
            t.assert_equals(info, base_info,
                "Synchro queue state is different on different nodes",
                true)
        end
    end
end

local function ensure_data_matches(servers)
    local base_data = nil;

    for _, server in pairs(servers) do
        local data = server:exec(function()
            return box.space.test:select()
        end)

        if base_data == nil then
            base_data = data
        else
            t.assert_equals(data, base_data,
                "Data in space test is different on different nodes",
                true)
        end
    end
end

local function ensure_no_split_brain_in_logs(servers)
    for _, server in pairs(servers) do
        t.assert_not(server:grep_log('ER_SPLIT_BRAIN'))
    end
end

local function ensure_healthy(servers)
    ensure_mesh_replication_healthy(servers)
    ensure_synchro_state_matches(servers)
    ensure_data_matches(servers)
    ensure_no_split_brain_in_logs(servers)
end

local function promote_index(server)
    return server:exec(function()
        return box.info.synchro.promote_queue.index
    end)
end

local function wait_for_promote_queue_len(server, len)
    t.helpers.retrying({}, function()
        local actual_len = server:exec(function()
            return #box.info.synchro.promote_queue.items
        end)

        t.assert_equals(actual_len, len, server.alias)
    end)
end

-- Write to the synchronous space in a fiber, so that a transaction waiting
-- for a quorum doesn't block the test, and wait until it reaches WAL. The
-- outcome is kept in _G.sync_writes[key]. Returns the LSN of the transaction.
local function spawn_sync_write(server, key)
    return server:exec(function(key)
        local lsn = box.info.lsn
        rawset(_G, 'sync_writes', rawget(_G, 'sync_writes') or {})
        _G.sync_writes[key] = {status = 'pending'}
        require('fiber').new(function()
            local ok, err = pcall(box.space.test.replace, box.space.test, {key})
            _G.sync_writes[key] = ok and {status = 'ok'} or
                                  {status = 'error', code = err.code}
        end)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.lsn, lsn + 1)
        end)
        return box.info.lsn
    end, {key})
end

local function sync_write_result(server, key)
    return server:exec(function(key)
        return _G.sync_writes[key]
    end, {key})
end

-- n1 takes the queue over and gets cut off from n2 and n3, which keep
-- following each other.
local function promote_and_cut_off(n1, n2, n3)
    promote(n1)
    n2:wait_for_vclock_of(n1)
    n3:wait_for_vclock_of(n1)
    server_set_replication(n1, {})
    make_connected_mesh({n2, n3})
end

-- n3 wins the elections with n2's vote. n2 stops following n3 before the
-- PROMOTE is written, so the PROMOTE waits for a quorum with n3's own ack only.
local function write_pending_promote(n2, n3)
    spawn_stuck_promote(n3)
    server_set_replication(n2, {})
    remove_wal_delay_on_xrow_type(n3)
    wait_for_promote_queue_len(n3, 1)
end

-- Wait until server has got the row of source with the given LSN and has
-- queue_len transactions in the limbo.
local function wait_for_row_in_queue(server, source, lsn, queue_len)
    local source_id = source:get_instance_id()
    t.helpers.retrying({}, function()
        t.assert_equals(server:exec(function(id)
            return {box.info.vclock[id], box.info.synchro.queue.len}
        end, {source_id}), {lsn, queue_len})
    end)
end

-- n1's tail gets to n3 through n2, while n3's PROMOTE is pending. n1 learns
-- the new term first, so that it doesn't confirm the tail once n2 acks it.
local function deliver_tail_through_replica(n1, n2)
    server_set_replication(n1, {n2.net_box_uri})
    t.helpers.retrying({}, function()
        t.assert_equals(n1:exec(function()
            return box.info.election.term
        end), n2:exec(function()
            return box.info.election.term
        end))
    end)
    server_set_replication(n2, {n1.net_box_uri})
end

local function make_test_group(opts)
    checks({ skip_start = '?boolean', nodes = "number", quorum = "number"})

    t.assert_ge(opts.nodes, 2, "can't be less than 2 nodes")

    local g = t.group('qpromote')

    g.before_each(function(g)
        g.cluster = cluster:new({})
        g.servers = {}

        local replication = {}
        for i = 1, opts.nodes do
            replication[i] =
                server.build_listen_uri('server_' .. i, g.cluster.id)
        end

        local box_cfg = {
            replication_synchro_timeout = 100000,
            replication_synchro_quorum  = opts.quorum,
            replication_connect_quorum  = opts.quorum,
            replication_timeout         = 0.1,
            election_timeout            = 5,
            election_fencing_mode       = 'off',
            bootstrap_strategy          = 'legacy',
            replication                 = replication,
        }

        for i = 1, opts.nodes do
            -- This is needed to make bootstrap deterministic
            -- This ensures first node is always elected as leader
            if i == 1 then
                box_cfg['election_mode'] = 'manual'
            else
                box_cfg['election_mode'] = 'voter'
            end

            g.cluster:build_and_add_server({
                alias = 'server_' .. i, box_cfg = box_cfg
            })
        end

        if opts and opts.skip_start then
            return g
        end

        g.cluster:start()
        g.cluster:wait_for_fullmesh()

        g.cluster.servers[1]:exec(function()
            t.assert_equals(box.info.election.state, 'leader')
            t.assert_not(box.info.ro)
        end)

        g.cluster:get_leader():exec(function()
            local s = box.schema.create_space('test', { is_sync = true })
            s:create_index('pk')
            -- Local space used as a WAL barrier (see
            -- range_insert_spawn in qpromote_commit_and_rollback_test).
            local b = box.schema.create_space('wal_barrier',
                                              { is_local = true })
            b:create_index('pk')
        end)

        -- For clarity in the test code, at the beginning of the test in
        -- many cases first node is promoted. In order for this promote
        -- to not be a noop first node must not be the leader at this point.
        -- So we set manual election mode everywhere, and promote second node.
        -- For convenience we try to be as deterministic as possible for ease of
        -- debugging. This is why we dont just promote random instance if first
        -- node happens to be the leader during bootstrap. This way term/promote
        -- index can differ from run to run which makes debugging harder by
        -- harming reproducibility
        for _, server in ipairs(g.cluster.servers) do
            server:exec(function()
                box.cfg { election_mode = 'manual' }
            end)
            -- preserve this in server object, so it gets picked up
            -- in case server is restarted
            server.box_cfg.election_mode = 'manual'
        end

        promote(g.cluster.servers[2])
        g.cluster.servers[2]:exec(function()
            t.assert_equals(box.info.election.state, 'leader')
            t.assert_not(box.info.ro)
        end)

        t.assert_equals(g.cluster:get_leader(), g.cluster.servers[2])

        t.helpers.retrying({timeout = 60}, function()
            ensure_synchro_state_matches(g.cluster.servers)
            ensure_mesh_replication_healthy(g.cluster.servers)
        end)
    end)

    g.after_each(function(g)
        g.cluster:drop()
    end)

    return g
end

local common = {
    make_test_group = make_test_group,
    server_set_replication = server_set_replication,
    server_set_synchro_quorum = server_set_synchro_quorum,
    is_leader = is_leader,
    errinj_arm = errinj_arm,
    errinj_wait = errinj_wait,
    start_wal_delay = start_wal_delay,
    stop_wal_delay = stop_wal_delay,
    remove_wal_delay_on_xrow_type = remove_wal_delay_on_xrow_type,
    promote = promote,
    spawn_promote = spawn_promote,
    spawn_stuck_promote = spawn_stuck_promote,
    spawn_promote_stuck_on_confirm = spawn_promote_stuck_on_confirm,
    make_connected_mesh = make_connected_mesh,
    ensure_mesh_replication_healthy = ensure_mesh_replication_healthy,
    ensure_synchro_state_matches = ensure_synchro_state_matches,
    ensure_data_matches = ensure_data_matches,
    ensure_no_split_brain_in_logs = ensure_no_split_brain_in_logs,
    ensure_healthy = ensure_healthy,
    promote_index = promote_index,
    wait_for_promote_queue_len = wait_for_promote_queue_len,
    spawn_sync_write = spawn_sync_write,
    sync_write_result = sync_write_result,
    promote_and_cut_off = promote_and_cut_off,
    write_pending_promote = write_pending_promote,
    wait_for_row_in_queue = wait_for_row_in_queue,
    deliver_tail_through_replica = deliver_tail_through_replica,
}

return common
