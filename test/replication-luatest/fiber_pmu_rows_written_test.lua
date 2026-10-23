local t = require('luatest')
local server = require('luatest.server')
local replica_set = require('luatest.replica_set')

local g = t.group()

g.before_all(function(cg)
    cg.replica_set = replica_set:new{}
    local box_cfg = {
        replication = {
            server.build_listen_uri('master', cg.replica_set.id),
            server.build_listen_uri('replica', cg.replica_set.id),
        },
        replication_timeout = 0.1,
    }
    cg.master = cg.replica_set:build_and_add_server{
        alias = 'master',
        box_cfg = box_cfg,
    }
    cg.replica = cg.replica_set:build_and_add_server{
        alias = 'replica',
        box_cfg = box_cfg,
    }
    cg.replica_set:start()
    cg.replica_set:wait_for_fullmesh()
    cg.master:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')
    end)
end)

g.after_all(function(cg)
    cg.replica_set:drop()
end)

-- Returns the sum of the rows written by the applier fibers. In a full
-- mesh there is also an applier of the instance itself, which applies
-- nothing.
local function applier_rows_written(srv)
    return srv:exec(function()
        local sum = 0
        for _, f in pairs(require('fiber').info()) do
            if f.name:startswith('applier/') and f.pmu ~= nil then
                sum = sum + f.pmu.rows_written
            end
        end
        return sum
    end)
end

-- Writes rows with the keys after `base` that change 11 rows of the
-- space: 10 inserts and a delete. The delete of a missing row and the
-- update of a missing row write no row.
local function write_rows(srv, base)
    srv:exec(function(base)
        box.begin()
        for i = base + 1, base + 10 do
            box.space.test:insert({i})
        end
        box.commit()
        box.space.test:delete({base + 1})
        box.space.test:delete({base + 100})
        box.space.test:update({base + 100}, {{'=', 1, base + 100}})
    end, {base})
end

-- Check that the applier fiber counts the rows that it applies.
g.test_applier = function(cg)
    cg.replica:exec(function()
        require('fiber').pmu.start()
    end)
    local before = applier_rows_written(cg.replica)
    write_rows(cg.master, 0)
    cg.replica:wait_for_vclock_of(cg.master)
    t.assert_equals(applier_rows_written(cg.replica) - before, 11)
    cg.replica:exec(function()
        require('fiber').pmu.stop()
    end)
end

-- Check that the recovery counts the rows of the snapshot and of the
-- xlog for the fiber that recovers them. The main fiber ends with the
-- script, so a trigger saves its count.
g.test_recovery = function()
    local srv = server:new({
        alias = 'recovery',
        env = {
            TARANTOOL_RUN_BEFORE_BOX_CFG = [[
                local fiber = require('fiber')
                fiber.pmu.start()
                box.ctl.on_recovery_state(function(state)
                    if state == 'wal_recovered' then
                        local pmu = fiber.self().pmu:read()
                        rawset(_G, 'recovered_rows', pmu.rows_written)
                    end
                end)
            ]],
        },
    })
    local function recovered_rows()
        return srv:exec(function()
            return _G.recovered_rows
        end)
    end
    srv:start()
    srv:exec(function()
        box.schema.space.create('test')
        box.space.test:create_index('pk')
    end)
    -- The rows of the system spaces and of the empty space.
    srv:restart()
    local base = recovered_rows()
    t.assert_type(base, 'number')
    write_rows(srv, 0)
    srv:exec(function()
        box.snapshot()
    end)
    write_rows(srv, 100)
    srv:restart()
    -- The second snapshot has the system rows of the first one, the
    -- rows of the DDL from the first xlog and 9 rows of the space. The
    -- xlog has 11 writes.
    t.assert_equals(recovered_rows() - base, 9 + 11)
    srv:drop()
end

-- Check that a fiber counts the rows of a synchronous transaction if it
-- is cancelled while it waits for the quorum: the transaction commits
-- later without the fiber.
g.test_sync_cancel = function()
    local srv = server:new({alias = 'sync'})
    srv:start()
    srv:exec(function()
        local fiber = require('fiber')
        box.ctl.promote()
        box.schema.space.create('sync', {is_sync = true})
        box.space.sync:create_index('pk')
        box.cfg{
            replication_synchro_quorum = 2,
            replication_synchro_timeout = 1000,
        }
        fiber.pmu.start()
        local f = fiber.new(box.space.sync.insert, box.space.sync, {1})
        f:set_joinable(true)
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 1)
        end)
        -- The fiber can still wait for the WAL, which ignores a cancel,
        -- and then wait for the quorum, so cancel it until it ends.
        local ok, err
        t.helpers.retrying({}, function()
            f:cancel()
            ok, err = f:join(0.1)
            t.assert_not_equals(err and err.type, 'TimedOut')
        end)
        t.assert_equals(ok, false)
        t.assert_equals(err.type, 'FiberIsCancelled')
        t.assert_equals(f.pmu:read().rows_written, 1)
        box.cfg{replication_synchro_quorum = 1}
        t.helpers.retrying({}, function()
            t.assert_equals(box.info.synchro.queue.len, 0)
        end)
        t.assert_equals(box.space.sync:get({1}), {1})
        fiber.pmu.stop()
    end)
    srv:drop()
end
