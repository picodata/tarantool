local t = require('luatest')
local replica_set = require('luatest.replica_set')
local fiber = require('fiber')

local g = t.group()

local function certs_file(name)
    return require('fio').abspath('./test/ssl-luatest/certs') .. "/" .. name
end

g.before_each(function()
    g.rs = replica_set:new()
end)

g.after_each(function()
    g.rs:stop()
end)

g.test_tls_replication_hang_in_relay = function()
    t.tarantool.skip_if_not_debug()
    g.rs:build_and_add_server({ alias = 'master', box_cfg = {
        replication_timeout = 0.1,
        replication_connect_timeout = 10,
        replication = {
            {
                uri = 'guest@0.0.0.0:3300',
                params = {
                    transport = 'ssl',
                }
            },
            {
                uri = 'guest@0.0.0.0:3301',
                params = {
                    transport = 'ssl',
                }
            },
        },
        listen = {{
            uri = '0.0.0.0:3300',
            params = {
                transport = 'ssl',
                ssl_key_file = certs_file('self-sign-key.pem'),
                ssl_cert_file = certs_file('self-sign-cert.pem'),
            }
        }, {uri = '0.0.0.0:3302'}}
    }, net_box_uri = '0.0.0.0:3302',
    })

    g.rs:build_and_add_server({ alias = 'replica', box_cfg = {
        replication_timeout = 0.1,
        replication_connect_timeout = 10,
        replication = {
            {
                uri = 'guest@0.0.0.0:3300',
                params = {
                    transport = 'ssl',
                }
            },
            {
                uri = 'guest@0.0.0.0:3301',
                params = {
                    transport = 'ssl',
                }
            },
        },
        listen = {{
            uri = '0.0.0.0:3301',
            params = {
                transport = 'ssl',
                ssl_key_file = certs_file('self-sign-key.pem'),
                ssl_cert_file = certs_file('self-sign-cert.pem'),
            }
        }, {uri = '0.0.0.0:3303'}},
        read_only = true,
    }, net_box_uri = '0.0.0.0:3303',
    })

    g.rs:start()
    g.rs:get_server('master'):exec(function()
        box.error.injection.set(
            'ERRINJ_RELAY_FAIL_BEFORE_SUBSCRIBE_LOOP',
            true
        )
    end)
    g.rs:get_server('replica'):stop()
    g.rs:get_server('replica'):start()
    -- if we have the bug we are hanging here (infinite loop)
    g.rs:get_server('master'):exec(function()
        fiber.sleep(box.cfg.replication_timeout * 30)
    end)
    g.rs:get_server('master'):exec(function()
        box.error.injection.set(
            'ERRINJ_RELAY_FAIL_BEFORE_SUBSCRIBE_LOOP',
            false
        )
    end)
    g.rs:get_server('master'):exec(function()
        fiber.sleep(box.cfg.replication_timeout * 30)
    end)
    -- if we do not have the bug we are finishing successfully
end
