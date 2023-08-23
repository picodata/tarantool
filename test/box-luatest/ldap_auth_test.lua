-- NOTE: this test expects to see `glauth` in $PATH!
-- It's an LDAP server we use for this test.
-- You can have it downloaded by CMake during project configuration:
--
-- ```shell
-- cmake -DENABLE_GLAUTH_DOWNLOAD=ON
-- ```
--
-- Although we could enable this test depending on the ability
-- to execute `glauth`, we'd like to run it unconditionally,
-- otherwise there's a non-zero chance of LDAP breaking silently.

local net = require('net.box')
local server = require('luatest.server')
local t = require('luatest')
local urilib = require('uri')
local fio = require('fio')
local popen = require('popen')
local socket = require('socket')
local fiber = require('fiber')

-- GLAuth (A lightweight LDAP server for development, home use, or CI)
-- https://github.com/glauth/glauth/releases/download/v2.2.0/glauth-linux-amd64
local glauth = nil
local glauth_tmp = fio.tempdir()

local g = t.group()

g.before_all(function(cg)
    -- NB: configure magic LDAP environment variables.
    local env = {
        TT_LDAP_URL = 'ldap://127.0.0.1:1389',
        TT_LDAP_DN_FMT = 'cn=$USER,dc=example,dc=org'
    }

    cg.server = server:new({alias = 'master', env = env})
    cg.server:start()
    cg.server:exec(function()
        box.cfg{auth_type = 'ldap'}
        box.schema.user.create('mickey', {password = ''})
        box.session.su('admin', box.schema.user.grant, 'mickey', 'super')
    end)

    local config_path = fio.pathjoin(glauth_tmp, 'ldap.cfg')
    local config = fio.open(config_path, {'O_CREAT', 'O_RDWR'},
                            tonumber('644', 8))
    local password = -- sha256 of `dogood`
        "6478579e37aff45f013e14eeb30b3cc56c72ccdc310123bcdf53e0333e3f416a"
    config:write(string.format([=[
        [ldap]
          enabled = true
          listen = "127.0.0.1:1389"

        [ldaps]
          enabled = false

        [backend]
          datastore = "config"
          baseDN = "dc=example,dc=org"

        [[users]]
          name = "mickey"
          uidnumber = 5001
          primarygroup = 5501
          passsha256 = "%s"
            [[users.capabilities]]
            action = "search"
            object = "*"

        [[groups]]
          name = "cartoons"
          gidnumber = 5501
    ]=], password))
    config:close()

    -- I'd gladly use popen.new, but it doesn't resolve path...
    glauth = popen.shell('glauth -c ' .. config_path)
    t.assert_not_equals(glauth, nil)

    -- Wait for GLAuth startup
    local sock = nil
    for _=1,40 do
        sock = socket.tcp_connect('127.0.0.1', 1389)
        if sock == nil and glauth.status.state == popen.state.ALIVE then
            fiber.sleep(0.1)
        else break end
    end
    t.assert_not_equals(sock, nil)
    sock:close()
end)

g.after_all(function(cg)
    cg.server:drop()
    glauth:close()
    fio.rmtree(glauth_tmp)
end)

g.test_net_box = function(cg)
    local parsed_uri = urilib.parse(cg.server.net_box_uri)
    parsed_uri.login = 'mickey'
    parsed_uri.password = 'dogood'
    parsed_uri.params = parsed_uri.params or {}
    parsed_uri.params.auth_type = {'ldap'}

    -- Good
    local uri = urilib.format(parsed_uri, true)
    local conn = net.connect(cg.server.net_box_uri, uri)
    t.assert_equals(conn.error, nil)
    t.assert_equals(conn.state, 'active')
    conn:close()

    -- Good
    conn = net.connect(cg.server.net_box_uri, {
        user = 'mickey',
        password = 'dogood',
        auth_type = 'ldap',
    })
    t.assert_equals(conn.error, nil)
    t.assert_equals(conn.state, 'active')
    conn:close()

    -- Bad password
    conn = net.connect(cg.server.net_box_uri, {
        user = 'mickey',
        password = 'wrong_password',
        auth_type = 'ldap',
    })
    t.assert_equals(
        conn.error,
        "User not found or supplied credentials are invalid"
    )
    conn:close()

    -- Bad auth type
    conn = net.connect(cg.server.net_box_uri, {
        user = 'mickey',
        password = 'dogood',
        auth_type = 'md5',
    })
    t.assert_equals(
        conn.error,
        "User not found or supplied credentials are invalid"
    )
    conn:close()
end
