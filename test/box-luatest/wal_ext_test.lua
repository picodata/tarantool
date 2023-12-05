local server = require('luatest.server')
local t = require('luatest')
local replica_set = require('luatest.replica_set')

local g = t.group()

g.test_new_old_extension_wal_format = function()
    g.server = server:new({ alias = 'master' })
    g.server:start()

    g.server:exec(function()
        local fio = require('fio')
        local xlog = require('xlog').pairs

        local function read_xlog(file)
            local val = {}
            for _, v in xlog(file) do
                table.insert(val, v)
            end
            return val
        end

        box.cfg({})

        -- enable new_old extension
        box.cfg { wal_ext = { new_old = true } }
        box.schema.space.create('test'):create_index('pk')

        -- generate a new xlog
        box.snapshot()
        local lsn = box.info.lsn

        box.space.test:insert({ 1, "1" })
        box.space.test:insert({ 2, "2" })
        box.space.test:update(2, { { '=', 2, '3' } })
        box.space.test:delete(1)

        -- open a new xlog
        box.snapshot()

        -- read a previous one xlog, assert new and old tuple information
        local log_path = fio.pathjoin(
                box.cfg.wal_dir,
                string.format('%020d.xlog', lsn)
        )
        local data = read_xlog(log_path)
        t.assert(data[1].HEADER.type == 'INSERT'
                and table.equals(data[1].BODY.new_tuple:totable(), { 1, "1" })
                and data[1].BODY.old_tuple == nil
        )
        t.assert(data[2].HEADER.type == 'INSERT'
                and table.equals(data[2].BODY.new_tuple:totable(), { 2, "2" })
                and data[2].BODY.old_tuple == nil
        )
        t.assert(data[3].HEADER.type == 'UPDATE'
                and table.equals(data[3].BODY.new_tuple:totable(), { 2, "3" })
                and table.equals(data[3].BODY.old_tuple:totable(), { 2, "2" })
        )
        t.assert(data[4].HEADER.type == 'DELETE'
                and data[4].BODY.new_tuple == nil
                and table.equals(data[4].BODY.old_tuple:totable(), { 1, "1" })
        )

        -- disable new_old wal extension
        box.cfg { wal_ext = { new_old = false } }

        local lsn = box.info.lsn

        -- drop space cache
        box.space.test:alter({})

        box.space.test:insert({ 3, "3" })
        box.space.test:update(3, { { '=', 2, '4' } })
        box.space.test:delete(3)

        -- open a new xlog
        box.snapshot()

        -- read a previous one xlog, assert new and old tuple information
        -- doesn't exists
        local log_path = fio.pathjoin(
                box.cfg.wal_dir,
                string.format('%020d.xlog', lsn)
        )
        local data = read_xlog(log_path)
        t.assert(data[2].HEADER.type == 'INSERT'
                and data[2].BODY.new_tuple == nil
                and data[2].BODY.old_tuple == nil
        )
        t.assert(data[3].HEADER.type == 'UPDATE'
                and data[3].BODY.new_tuple == nil
                and data[3].BODY.old_tuple == nil
        )
        t.assert(data[4].HEADER.type == 'DELETE'
                and data[4].BODY.new_tuple == nil
                and data[4].BODY.old_tuple == nil
        )

        box.space.test:drop()
    end)

    g.server:stop()
end

g.test_new_old_extension_replicated = function()
    g.rs = replica_set:new()
    g.box_cfg = {
        replication_timeout = 0.1,
        replication_connect_timeout = 10,
        replication_sync_lag = 0.01,
        replication_connect_quorum = 3,
        replication = {
            server.build_listen_uri('master', g.rs.id),
            server.build_listen_uri('replica', g.rs.id),
        }
    }

    g.rs:build_and_add_server({ alias = 'master', box_cfg = g.box_cfg })
    g.rs:build_and_add_server({ alias = 'replica', box_cfg = g.box_cfg })
    g.rs:start()

    local lsn = g.rs:get_server('master'):exec(function()
        local lsn = box.info.lsn

        -- enable new_old extension
        box.cfg { wal_ext = { new_old = true } }
        box.schema.space.create('test'):create_index('pk')

        box.space.test:insert({ 1, "1" })
        box.space.test:insert({ 2, "2" })
        box.space.test:update(2, { { '=', 2, '3' } })
        box.space.test:delete(1)

        return lsn
    end)

    -- wait until data has been replicated
    require('fiber').sleep(2)

    g.rs:get_server('replica'):exec(function(lsn)
        local fio = require('fio')
        local xlog = require('xlog').pairs

        local function read_xlog(file)
            local val = {}
            for _, v in xlog(file) do
                table.insert(val, v)
            end
            return val
        end

        -- read a previous one xlog, assert new and old tuple information
        local log_path = fio.pathjoin(
                box.cfg.wal_dir,
                string.format('%020d.xlog', lsn)
        )

        local data = read_xlog(log_path)
        local xlogs_cnt = #data

        local i = xlogs_cnt - 3
        t.assert(data[i].HEADER.type == 'INSERT'
                and table.equals(data[i].BODY.new_tuple:totable(), { 1, "1" })
                and data[i].BODY.old_tuple == nil
        )
        local i = xlogs_cnt - 2
        t.assert(data[i].HEADER.type == 'INSERT'
                and table.equals(data[i].BODY.new_tuple:totable(), { 2, "2" })
                and data[i].BODY.old_tuple == nil
        )
        local i = xlogs_cnt - 1
        t.assert(data[i].HEADER.type == 'UPDATE'
                and table.equals(data[i].BODY.new_tuple:totable(), { 2, "3" })
                and table.equals(data[i].BODY.old_tuple:totable(), { 2, "2" })
        )
        local i = xlogs_cnt
        t.assert(data[i].HEADER.type == 'DELETE'
                and data[i].BODY.new_tuple == nil
                and table.equals(data[i].BODY.old_tuple:totable(), { 1, "1" })
        )
    end, { lsn })

    g.rs:stop()
end
