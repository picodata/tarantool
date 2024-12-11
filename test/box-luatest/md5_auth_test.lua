local net = require('net.box')
local server = require('luatest.server')
local t = require('luatest')
local urilib = require('uri')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
    cg.server:exec(function()
        box.cfg{auth_type = 'md5'}
        box.schema.user.create('test', {password = 'secret'})
        box.session.su('admin', box.schema.user.grant, 'test', 'super')
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_box_cfg = function(cg)
    cg.server:exec(function()
        t.assert_equals(box.cfg.auth_type, 'md5')
        t.assert_error_msg_equals(
            "Incorrect value for option 'auth_type': should be of type string",
            box.cfg, {auth_type = 42})
        t.assert_error_msg_equals(
            "Incorrect value for option 'auth_type': md55",
            box.cfg, {auth_type = 'md55'})
    end)
end

g.test_net_box = function(cg)
    local parsed_uri = urilib.parse(cg.server.net_box_uri)
    parsed_uri.login = 'test'
    parsed_uri.password = 'secret'
    parsed_uri.params = parsed_uri.params or {}
    parsed_uri.params.auth_type = {'md6'}
    local uri = urilib.format(parsed_uri, true)
    t.assert_error_msg_equals(
        "Unknown authentication method 'md6'",
        net.connect, uri)
    parsed_uri.params.auth_type = {'md5'}
    uri = urilib.format(parsed_uri, true)
    local conn = net.connect(cg.server.net_box_uri, uri)
    t.assert_equals(conn.error, nil)
    conn:close()
    t.assert_error_msg_equals(
        "Unknown authentication method 'md6'",
        net.connect, uri, {auth_type = 'md6'})
    t.assert_error_msg_equals(
        "Unknown authentication method 'md6'",
        net.connect, cg.server.net_box_uri, {
            user = 'test',
            password = 'secret',
            auth_type = 'md6',
        })
    conn = net.connect(cg.server.net_box_uri, {
        user = 'test',
        password = 'secret',
        auth_type = 'md5',
    })
    t.assert_equals(conn.error, nil)
    conn:close()
    conn = net.connect(cg.server.net_box_uri, {
        user = 'test',
        password = 'not-secret',
        auth_type = 'md5',
    })
    t.assert_not_equals(conn.error, nil)
end

g.before_test('test_replication', function(cg)
    cg.replica = server:new({
        alias = 'replica',
        box_cfg = {
            replication = server.build_listen_uri('master', cg.server.id),
        },
    })
    cg.replica:start()
end)

g.after_test('test_replication', function(cg)
    cg.replica:drop()
end)

g.test_replication = function(cg)
    cg.replica:exec(function(uri)
        local urilib = require('uri')
        local parsed_uri = urilib.parse(uri)
        parsed_uri.login = 'test'
        parsed_uri.password = 'secret'
        parsed_uri.params = parsed_uri.params or {}
        parsed_uri.params.auth_type = {'md6'}
        uri = urilib.format(parsed_uri, true)
        box.cfg({replication = {}})
        t.assert_error_msg_matches(
            "Incorrect value for option 'replication': " ..
            "bad URI '.*%?auth_type=md6': " ..
            "unknown authentication method",
            box.cfg, {replication = uri})
        parsed_uri.params.auth_type = {'md5'}
        uri = urilib.format(parsed_uri, true)
        box.cfg({replication = uri})
    end, {server.build_listen_uri('master')})
end
