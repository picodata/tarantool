local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

local function certs_file(name)
    return require('fio').abspath('./test/ssl-luatest/certs') .. "/" .. name
end

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

g.test_ssl_self_signed_works = function()
    g.server:exec(function()
        t.assert_error_msg_content_equals(
                "ssl_key_file and ssl_cert_file parameters are mandatory for a server",
                function()
                    box.cfg {
                        listen = {
                            uri = 'localhost:0',
                            params = { transport = 'ssl' }
                        }
                    }
                end)
    end)

    local listen = g.server:exec(function(key, cert)
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
        return box.cfg.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    t.assert_not_equals(listen, nil)
end

g.test_ssl_password_for_key = function()
    local listen = g.server:exec(function(key, cert)
        t.assert_error_msg_matches(
                "Unable to set private key file: .*bad decrypt",
                function()
                    box.cfg {
                        listen = {
                            uri = 'localhost:0',
                            params = {
                                transport = 'ssl',
                                ssl_key_file = key,
                                ssl_cert_file = cert,
                                ssl_password = 'wrong-password',
                            }
                        }
                    }
                end
        )

        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_password = 'foobar',
                }
            }
        }

        return box.cfg.listen
    end, {
        certs_file('self-sign-pw-key.key'),
        certs_file('self-sign-pw-cert.crt'),
    })
    t.assert_not_equals(listen, nil)
end

g.test_ssl_password_file_for_key = function()
    -- server
    local srv_uri = g.server:exec(function(key, cert, pw_file, wrong_pw_file)
        t.assert_error_msg_matches(
                "Unable to set private key file: .*bad decrypt",
                function()
                    box.cfg {
                        listen = {
                            uri = 'localhost:0',
                            params = {
                                transport = 'ssl',
                                ssl_key_file = key,
                                ssl_cert_file = cert,
                                ssl_password_file = wrong_pw_file,
                            }
                        }
                    }
                end)

        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_password_file = pw_file,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, {
        certs_file('self-sign-pw-key.key'),
        certs_file('self-sign-pw-cert.crt'),
        certs_file('pw.txt'),
        certs_file('pw-wrong.txt'),
    })

    -- check client as well
    local client_connection = g.client:exec(
            function(srv_uri, key, cert, pw_file, wrong_pw_file)
                t.assert_error_msg_matches(
                        "Unable to set private key file: .*bad decrypt",
                        function()
                            require('net.box').connect({
                                uri = srv_uri,
                                params = {
                                    transport = 'ssl',
                                    ssl_key_file = key,
                                    ssl_cert_file = cert,
                                    ssl_password_file = wrong_pw_file,
                                }
                            })
                        end)

                local connection = require('net.box').connect({
                    uri = srv_uri,
                    params = {
                        transport = 'ssl',
                        ssl_key_file = key,
                        ssl_cert_file = cert,
                        ssl_password_file = pw_file,
                    }
                })
                return connection
            end, {
                srv_uri,
                certs_file('self-sign-pw-key.key'),
                certs_file('self-sign-pw-cert.crt'),
                certs_file('pw.txt'),
                certs_file('pw-wrong.txt'),
            })
    t.assert_equals(client_connection.error, nil)
end

g.test_ssl_password_and_ssl_password_file_for_key = function()
    local srv_uri = g.server:exec(function(key, cert, pw_file, wrong_pw_file)
        t.assert_error_msg_matches(
                "Unable to set private key file: .*bad decrypt",
                function()
                    box.cfg {
                        listen = {
                            uri = 'localhost:0',
                            params = {
                                transport = 'ssl',
                                ssl_key_file = key,
                                ssl_cert_file = cert,
                                ssl_password = 'foobar1',
                                ssl_password_file = wrong_pw_file,
                            }
                        }
                    }
                end)

        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_password = 'foobar1',
                    ssl_password_file = pw_file,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)

        return box.info.listen
    end, {
        certs_file('self-sign-pw-key.key'),
        certs_file('self-sign-pw-cert.crt'),
        certs_file('pw.txt'),
        certs_file('pw-wrong.txt'),
    })

    -- check client as well
    local client_connection = g.client:exec(
            function(srv_uri, key, cert, pw_file, wrong_pw_file)
                t.assert_error_msg_matches(
                        "Unable to set private key file: .*bad decrypt",
                        function()
                            require('net.box').connect({
                                uri = srv_uri,
                                params = {
                                    transport = 'ssl',
                                    ssl_key_file = key,
                                    ssl_cert_file = cert,
                                    ssl_password = 'foobar1',
                                    ssl_password_file = wrong_pw_file,
                                }
                            })
                        end)

                local connection = require('net.box').connect({
                    uri = srv_uri,
                    params = {
                        transport = 'ssl',
                        ssl_key_file = key,
                        ssl_cert_file = cert,
                        ssl_password = 'foobar1',
                        ssl_password_file = pw_file,
                    }
                })
                return connection
            end, {
                srv_uri,
                certs_file('self-sign-pw-key.key'),
                certs_file('self-sign-pw-cert.crt'),
                certs_file('pw.txt'),
                certs_file('pw-wrong.txt'),
            })
    t.assert_equals(client_connection.error, nil)
end

g.test_server_verify_client = function()
    local srv_uri = g.server:exec(function(key, cert, ca)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_ca_file = ca,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)
        return box.info.listen
    end, {
        certs_file('ca-sign-key.key'),
        certs_file('ca-sign-cert.crt'),
        certs_file('ca.pem'),
    })

    local client_connection = g.client:exec(function(srv_uri, key, cert)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = key,
                ssl_cert_file = cert,
            }
        })
        return connection
    end, {
        srv_uri,
        certs_file('client/ca-sign-key.key'),
        certs_file('client/ca-sign-cert.crt'),
    })
    t.assert_equals(client_connection.error, nil)

    client_connection = g.client:exec(function(srv_uri)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = { transport = 'ssl' },
        })
        return connection
    end, { srv_uri })
    t.assert_str_matches(client_connection.error,
        'Init session error: .* alert handshake failure')

    client_connection = g.client:exec(function(srv_uri, key, cert)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = key,
                ssl_cert_file = cert,
            }
        })
        return connection
    end, {
        srv_uri,
        certs_file('client/self-sign-key.pem'),
        certs_file('client/self-sign-cert.pem'),
    })
    t.assert_str_matches(client_connection.error,
        'Init session error: .*tlsv1 alert unknown ca')
end

g.test_client_verify_server = function()
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
    end, { certs_file('ca-sign-key.key'), certs_file('ca-sign-cert.crt') })

    local client_connection = g.client:exec(function(srv_uri, key, cert, ca)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = key,
                ssl_cert_file = cert,
                ssl_ca_file = ca,
            }
        })
        return connection
    end, {
        srv_uri,
        certs_file('client/ca-sign-key.key'),
        certs_file('client/ca-sign-cert.crt'),
        certs_file('ca.pem'),
    })
    t.assert_equals(client_connection.error, nil)

    g.server:stop()
    g.server:start()

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

    local client_connection = g.client:exec(function(srv_uri, key, cert, ca)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = key,
                ssl_cert_file = cert,
                ssl_ca_file = ca,
            }
        })
        return connection
    end, {
        srv_uri,
        certs_file('client/ca-sign-key.key'),
        certs_file('client/ca-sign-cert.crt'),
        certs_file('ca.pem'),
    })
    t.assert_str_matches(client_connection.error,
        'Init session error: .*certificate verify failed')
end

g.test_server_client_verify_both = function()
    local srv_uri = g.server:exec(function(key, cert, ca)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_ca_file = ca,
                }
            }
        }
        t.assert_not_equals(box.cfg.listen, nil)
        return box.info.listen
    end, {
        certs_file('ca-sign-key.key'),
        certs_file('ca-sign-cert.crt'),
        certs_file('ca.pem'),
    })

    local client_connection = g.client:exec(function(srv_uri, key, cert, ca)
        local connection = require('net.box').connect({
            uri = srv_uri,
            params = {
                transport = 'ssl',
                ssl_key_file = key,
                ssl_cert_file = cert,
                ssl_ca_file = ca,
            }
        })
        return connection
    end, {
        srv_uri,
        certs_file('client/ca-sign-key.key'),
        certs_file('client/ca-sign-cert.crt'),
        certs_file('ca.pem'),
    })

    t.assert_equals(client_connection.error, nil)
end

g.test_set_cipher_list = function()
    g.server:exec(function(key, cert)
        t.assert_error_msg_content_equals(
                "Unable to set cipher list: UNKNOWN-CIPHER-LIST",
                function()
                    box.cfg {
                        listen = {
                            uri = 'localhost:0',
                            params = {
                                transport = 'ssl',
                                ssl_key_file = key,
                                ssl_cert_file = cert,
                                ssl_ciphers = 'UNKNOWN-CIPHER-LIST',
                            }
                        }
                    }
                end)
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    local listen = g.server:exec(function(key, cert)
        box.cfg {
            listen = {
                uri = 'localhost:0',
                params = {
                    transport = 'ssl',
                    ssl_key_file = key,
                    ssl_cert_file = cert,
                    ssl_ciphers = 'ECDHE-ECDSA-AES256-GCM-SHA384',
                }
            }
        }

        return box.cfg.listen
    end, { certs_file('self-sign-key.pem'), certs_file('self-sign-cert.pem') })

    t.assert_not_equals(listen, nil)
end

g.test_server_use_wrong_key = function()
    g.server:exec(function(key, cert)
        t.assert_error_msg_matches(
                "Unable to set private key file: .*key values mismatch",
                function()
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
                end)
    end, {
        certs_file('self-sign-wrong-key.pem'),
        certs_file('self-sign-cert.pem'),
    })
end

g.test_client_use_wrong_key = function()
    g.client:exec(function(key, cert)
        t.assert_error_msg_matches(
                "Unable to set private key file: .*key values mismatch",
                function()
                    require('net.box').connect({
                        uri = 'localhost:0',
                        params = {
                            transport = 'ssl',
                            ssl_key_file = key,
                            ssl_cert_file = cert,
                        }
                    })
                end)
    end, {
        certs_file('self-sign-wrong-key.pem'),
        certs_file('self-sign-cert.pem'),
    })
end
