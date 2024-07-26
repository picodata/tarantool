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

g.test_replication = function()
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

    -- write something on master
    g.rs:get_server('master'):exec(function()
        box.schema.space.create('test'):create_index('pk')

        box.space.test:insert({ 1, "1" })
        box.space.test:insert({ 2, "2" })
        box.space.test:update(2, { { '=', 2, '3' } })
        box.space.test:delete(1)
    end)

    local function check_vclock_synchronized()
        local function get_vclock(node_name)
                return g.rs:get_server(node_name)
                    :exec(function() return box.info.vclock end)
        end
        local master_vclock = get_vclock("master")
        local replica_vclock = get_vclock("replica")

        t.assert_equals(
            master_vclock,
            replica_vclock,
            'Vclocks are not synchronized'
        )
    end
    t.helpers.retrying({timeout = 2, delay = 0.1}, check_vclock_synchronized)
end

g.test_anon_replication = function()
    g.rs:build_and_add_server({ alias = 'master', box_cfg = {
        replication_timeout = 10,
        replication_connect_timeout = 20,
        listen = {{
                      uri = '0.0.0.0:3361',
                      params = {
                          transport = 'ssl',
                          ssl_key_file = certs_file('self-sign-key.pem'),
                          ssl_cert_file = certs_file('self-sign-cert.pem'),
                      }
                  }, {uri = '0.0.0.0:3362'}}
    }, net_box_uri = '0.0.0.0:3362',
    })

    g.rs:build_and_add_server({ alias = 'replica', box_cfg = {
        replication_timeout = 10,
        replication_connect_timeout = 20,
        replication = {
            {
                uri = 'guest@0.0.0.0:3361',
                params = {
                    transport = 'ssl',
                }
            },
        },
        listen = {uri = '0.0.0.0:3363'},
        read_only = true,
        replication_anon=true,
    }, net_box_uri = '0.0.0.0:3363',
    })
    g.rs:start()

    -- write something on master
    g.rs:get_server('master'):exec(function()
        box.schema.space.create('test'):create_index('pk')

        box.space.test:insert({ 1, "1" })
        box.space.test:insert({ 2, "2" })
        box.space.test:update(2, { { '=', 2, '3' } })
        box.space.test:delete(1)
    end)

    local function check_vclock_synchronized()
        local function get_vclock(node_name)
                return g.rs:get_server(node_name)
                    :exec(function() return box.info.vclock end)
        end
        local master_vclock = get_vclock("master")
        local replica_vclock = get_vclock("replica")

        t.assert_equals(
            master_vclock,
            replica_vclock,
            'Vclocks are not synchronized'
        )
    end
    t.helpers.retrying(
        {timeout = 2, delay = 0.1},
        check_vclock_synchronized
    )
end

g.test_plain_replication_to_ssl_master = function()
    g.rs:build_and_add_server({ alias = 'master', box_cfg = {
        replication_timeout = 0.1,
        replication_connect_timeout = 10,
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
        replication = 'guest@0.0.0.0:3300',
        listen = {uri = '0.0.0.0:3303'},
        read_only = true,
    }, net_box_uri = '0.0.0.0:3303',
    })
    g.rs:start({wait_until_ready = false})

    fiber.sleep(2)

    t.assert_error_msg_content_equals(
            "net_box is not connected",
            function()
                g.rs:get_server('replica'):exec(function()
                    return box.info.lsn
                end)
            end
    )
end
