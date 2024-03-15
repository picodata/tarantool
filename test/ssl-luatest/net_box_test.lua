local server = require('luatest.server')
local t = require('luatest')
local fiber = require('fiber')
local g = t.group()

g.before_each(function()
    g.server = server:new({ alias = 'server' })
    g.server:start()
    g.client = server:new({ alias = 'client' })
    g.client:start()
end)

g.after_each(function()
    g.server:stop()
    g.client:stop()
end)

local function certs_file(name)
    return require('fio').abspath('./test/ssl-luatest/certs') .. "/" .. name
end

g.test_net_box_works = function()
    local srv_uri = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    local eval_result = g.client:exec(function(srv_uri)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
            }
        })
        t.assert_equals(connection.error, nil)

        return connection:eval('return 21 * 2')
    end, { srv_uri })

    t.assert_equals(eval_result, 42)
end

g.test_client_close_connection = function()
    local state_and_uri = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        rawset(_G, 'client_connected', false)
        rawset(_G, 'client_disconnected', false)
        box.session.on_connect(function()
            _G['client_connected'] = true
        end)
        box.session.on_disconnect(function()
            _G['client_disconnected'] = true
        end)

        return {
            box.info.listen,
            {
                _G['client_connected'],
                _G['client_disconnected'],
            },
        }
    end, {
        certs_file('self-sign-key.pem'),
        certs_file('self-sign-cert.pem'),
    })

    local srv_uri = state_and_uri[1]
    local state = state_and_uri[2]

    t.assert_equals(state, { false, false })

    g.client:exec(function(srv_uri)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
            }
        })
        t.assert_equals(connection.error, nil)
        t.assert_equals(connection:eval('return 21 * 2'), 42)

        connection:close()
    end, { srv_uri })

    fiber.sleep(1)
    local state = g.server:exec(function()
        return { _G['client_connected'], _G['client_disconnected'] }
    end)
    t.assert_equals(state, { true, true })
end

g.test_server_drop_connection = function()
    local srv_uri = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    g.client:exec(function(srv_uri)
        local conn = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
            }
        })
        rawset(_G, 'connection', conn)
        t.assert_equals(_G['connection'].error, nil)
        t.assert_equals(_G['connection']:eval('return 21 * 2'), 42)
    end, { srv_uri })

    g.server:stop()

    g.client:exec(function()
        t.assert_error_msg_content_equals(
                "Peer closed",
                function()
                    _G['connection']:eval('return 21 * 2')
                end
        )
    end)
end

g.test_client_reconnect = function()
    local srv_uri = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    g.client:exec(function(srv_uri)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
            }
        })
        t.assert_equals(connection.error, nil)
        t.assert_equals(connection:eval('return 21 * 2'), 42)
    end, { srv_uri })

    g.client:stop()
    g.client = server:new({ alias = 'client' })
    g.client:start()

    g.client:exec(function(srv_uri)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
            }
        })

        t.assert_equals(connection.error, nil)
        t.assert_equals(connection:eval('return 21 * 2'), 42)
    end, { srv_uri })
end

g.test_ssl_and_plain_transports_in_single_server = function()
    local srv_uris = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                {
                    uri = 'localhost:0',
                    params = {
                        transport = 'ssl',
                        ssl_key_file = key,
                        ssl_cert_file = cert,
                    }
                },
                {
                    uri = 'localhost:0'
                }
            }}
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    g.client:exec(function(srv_uris)
        local secure_connection = require('net.box').connect({
            uri = srv_uris[1],
            params = {
                transport = 'ssl',
            }
        })
        t.assert_equals(secure_connection.error, nil)
        t.assert_equals(secure_connection:eval('return 21 * 2'), 42)

        local connection = require('net.box').connect({
            uri = srv_uris[2],
        })
        t.assert_equals(connection.error, nil)
        t.assert_equals(connection:eval('return 21 * 2'), 42)
    end, { srv_uris })
end

g.test_client_wrong_connection = function()
    local srv_uri = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)
        return box.info.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    g.client:exec(function(srv_uri)
        t.assert_error_msg_content_equals(
                "Unable to set cipher list: UNKNOWN-CIPHER-LIST",
                function()
                    require('net.box').connect({
                        uri = srv_uri,
                        params = {
                            transport = 'ssl',
                            ssl_ciphers = 'UNKNOWN-CIPHER-LIST',
                        }
                    })
                end
        )
    end, { srv_uri })
end

g.test_client_reconnect_after = function()
    fiber.create(function()
        fiber.sleep(2)

        g.server:exec(function(key, cert)
            box.cfg {
                listen = {
                    uri = 'localhost:3300',
                    params = {
                        transport = 'ssl',
                        ssl_key_file = key,
                        ssl_cert_file = cert,
                    }
                }
            }
            t.assert_not_equals(box.cfg.listen, nil)
        end, {
            certs_file('self-sign-key.pem'),
            certs_file('self-sign-cert.pem'),
        })
    end)

    g.client:exec(function()
        local connection = require('net.box').connect({
            uri = 'localhost:3300',
            params = {
                transport = 'ssl',
            }
        }, { reconnect_after = 1 })
        t.assert_equals(connection.error, nil)
    end)
end
