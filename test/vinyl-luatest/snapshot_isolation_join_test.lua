local cluster = require('luatest.replica_set')
local t = require('luatest')

local g = t.group('snapshot_isolation_join')

g.before_all(function()
    g.cluster = cluster:new({})
    g.master = g.cluster:build_and_add_server({alias = 'master'})

    local replica_box_cfg = {
        replication = { g.master.net_box_uri },
        read_only   = true,
    }
    g.replica = g.cluster:build_and_add_server({alias   = 'replica',
                                                box_cfg = replica_box_cfg})

    g.master:start()
    g.master:exec(function()
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('primary')
        for i = 1, 10 do s:insert{i} end
    end)

    g.replica:start()
end)

g.after_all(function()
    g.cluster:drop()
end)

-- A snapshot read view is taken at the tx manager lsn, which is
-- advanced once per committed vinyl write. A remote join applies the
-- master's data in bulk with no per-row LSNs, so on a freshly joined
-- replica the lsn used to stay at zero until the replica committed a
-- write of its own -- and a read-only replica never does. A snapshot
-- read in that state saw none of the joined data.
g.test_snapshot_read_after_join = function()
    g.replica:exec(function()
        local t = require('luatest')
        box.begin({txn_isolation = 'snapshot'})
        local rows = box.space.test:select()
        box.commit()
        t.assert_equals(#rows, 10,
            'a snapshot read on a freshly joined replica sees '
            .. 'the joined data')
    end)
end

-- The same through a plain autocommit read, which now takes the
-- committed read view implicitly.
g.test_autocommit_read_after_join = function()
    g.replica:exec(function()
        local t = require('luatest')
        local rows = box.space.test:select()
        t.assert_equals(#rows, 10,
            'a plain read on a freshly joined replica sees '
            .. 'the joined data')
    end)
end
