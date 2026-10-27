local t = require('luatest')
local replica_set = require('luatest.replica_set')
local server = require('luatest.server')

local g = t.group()

local function certs_file(name)
    return require('fio').abspath('./test/ssl-luatest/certs') .. "/" .. name
end

g.before_each(function()
    g.rs = replica_set:new()
end)

g.after_each(function()
    local stop_err
    for _, server in ipairs(g.rs.servers) do
        if server.process ~= nil then
            -- A stopped process doesn't handle SIGTERM until it's resumed.
            server.process:kill('CONT', {quiet = true})
        end
        local ok, err = pcall(server.stop, server)
        if not ok then
            -- With the IPROTO thread blocked the server ignores SIGTERM.
            -- Kill it, or it outlives the test.
            server.process:kill('KILL', {quiet = true})
            server.process = nil
            stop_err = stop_err or err
        end
    end
    if stop_err ~= nil then
        error(stop_err)
    end
end)

-- Closing an SSL connection used to wait for the peer's close_notify in a
-- cbus handler of the IPROTO thread. While the peer kept silent, the thread
-- delivered no tx -> net messages, so no IPROTO request got a response.
g.test_ssl_shutdown_does_not_block_iproto = function()
    local ssl_uri = server.build_listen_uri('master_ssl', g.rs.id)
    g.rs:build_and_add_server({alias = 'master', box_cfg = {
        replication_timeout = 0.1,
        listen = {{
            uri = ssl_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = certs_file('self-sign-key.pem'),
                ssl_cert_file = certs_file('self-sign-cert.pem'),
            }
        }, server.build_listen_uri('master', g.rs.id)},
    }})
    g.rs:build_and_add_server({alias = 'replica', box_cfg = {
        replication_timeout = 0.1,
        replication = {{uri = ssl_uri, params = {transport = 'ssl'}}},
        read_only = true,
    }})
    g.rs:start()

    local master = g.rs:get_server('master')
    local replica = g.rs:get_server('replica')
    local replica_id = replica:get_instance_id()
    local function downstream_status()
        local ok, res = pcall(master.eval, master,
            'return box.info.replication[...].downstream.status',
            {replica_id}, {timeout = 1})
        t.assert(ok, 'IPROTO thread is blocked: ' .. tostring(res))
        return res
    end
    t.helpers.retrying({}, function()
        t.assert_equals(downstream_status(), 'follow')
    end)

    -- The frozen replica sends neither acks nor close_notify, so the relay
    -- times out and the master closes the SSL connection.
    replica.process:kill('STOP')
    t.helpers.retrying({timeout = 10}, function()
        t.assert_equals(downstream_status(), 'stopped')
    end)
    t.assert(master.net_box:ping({timeout = 1}), 'IPROTO thread is blocked')
end
