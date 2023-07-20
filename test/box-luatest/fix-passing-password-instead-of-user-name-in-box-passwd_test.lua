local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_box_password_without_username_argument = function()
    t.assert(g.server:exec(function()
        box.cfg{auth_type='md5'}
        local user = 'admin'
        local pass = 'dwsadwaeaDSdawDsa321_#!$'
        box.session.su(user)
        local hash = box.space._user:select(1)[1][5]['md5']
        t.assert_not_equals (hash, box.schema.user.password(pass, user))
        box.schema.user.passwd(pass)
        hash = box.space._user:select(1)[1][5]['md5']
        t.assert_equals(hash, box.schema.user.password(pass, user))
        return true
    end))
end
