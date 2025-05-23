local cluster = require('luatest.replica_set')
local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

local function set_cluster_uuid(uuid_str)
    local ffi = require('ffi')
    ffi.cdef([[
        int tt_uuid_from_string(const char *in, struct tt_uuid *uu);
        int iproto_set_cluster_uuid(const struct tt_uuid *cluster_uuid);
    ]])
    local test_uuid = ffi.new("struct tt_uuid")
    local rc = ffi.C.tt_uuid_from_string(uuid_str, test_uuid)
    t.assert_equals(rc, 0, "tt_uuid_from_string should succeed")
    local res = ffi.C.iproto_set_cluster_uuid(test_uuid)
    t.assert_equals(res, 0, "iproto_set_cluster_uuid should succeed")
end

g.before_all(function(cg)
    cg.cluster = cluster:new({alias = 'cluster_uuid'})
end)

g.after_all(function(cg)
    cg.cluster:stop()
end)

g.test_cluster_uuid_mismatch = function(cg)
    local first_uuid = '11111111-1111-1111-1111-111111111111'
    local second_uuid = '22222222-2222-2222-2222-222222222222'

    local first_uri = server.build_listen_uri('first', cg.cluster.id)
    local second_uri = server.build_listen_uri('second', cg.cluster.id)

    -- build first
    local first_box_cfg = {
        listen = first_uri,
        replication_timeout = 1,
        replication_connect_timeout = 1,
        replicaset_uuid = 'deadbeef-3333-3333-3333-333333333333',
    }
    cg.first = cg.cluster:build_server({
        alias = 'first',
        box_cfg = first_box_cfg
    })
    cg.cluster:add_server(cg.first)
    cg.first:start()
    cg.first:exec(set_cluster_uuid, {first_uuid})

    -- build second
    local second_box_cfg = {
        listen = second_uri,
        replication_timeout = 1,
        replication_connect_timeout = 1,
        replicaset_uuid = 'deadbeef-3333-3333-3333-333333333333',
    }
    cg.second = cg.cluster:build_server({
        alias = 'second',
        box_cfg = second_box_cfg
    })
    cg.cluster:add_server(cg.second)
    cg.second:start()
    cg.second:exec(set_cluster_uuid, {second_uuid})

    cg.first:exec(function(nodes)
        box.cfg{replication = nodes}
    end, {{first_uri, second_uri}})

    cg.second:exec(function(nodes)
        box.cfg{replication = nodes}
    end, {{first_uri, second_uri}})

    local found
    found = cg.first:grep_log(
        'ER_PICO_CLUSTER_UUID_MISMATCH: Picodata cluster UUID mismatch')
    t.assert(found, "cannot find ER_PICO_CLUSTER_UUID_MISMATCH error in logs")
    found = cg.second:grep_log(
        'ER_PICO_CLUSTER_UUID_MISMATCH: Picodata cluster UUID mismatch')
    t.assert(found, "cannot find ER_PICO_CLUSTER_UUID_MISMATCH error in logs")

    local applier_fiber_cnt
    applier_fiber_cnt = cg.first:exec(function()
        return box.error.injection.get('ERRINJ_APPLIER_FIBER_COUNT')
    end)
    t.assert_equals(applier_fiber_cnt, 0)
    applier_fiber_cnt = cg.second:exec(function()
        return box.error.injection.get('ERRINJ_APPLIER_FIBER_COUNT')
    end)
    t.assert_equals(applier_fiber_cnt, 0)
end
