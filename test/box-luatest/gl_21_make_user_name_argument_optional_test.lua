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
        box.cfg{auth_type='chap-sha1'}
        t.assert_equals(box.schema.user.password("", ""),
                        'vhvewKp0tNyweZQ+cFKAlsyphfg=')
        t.assert_equals(box.schema.user.password("qwerty", box.session.user()),
                        'qhQg8YLoi55fh09vvnRZKR6PRgE=')
        t.assert_equals(box.schema.user.password("qwerty"),
                        box.schema.user.password("qwerty", box.session.user()))
        --- chap-sha1 doesn't use username arugment for hashing
        --- so the passwords must be equal
        t.assert_equals(box.schema.user.password("qwerty"),
                        box.schema.user.password("qwerty", "???"))
        return true
    end))
end
