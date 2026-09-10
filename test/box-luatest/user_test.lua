local t = require('luatest')
local server = require('luatest.server')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

--
-- Granting a role that is already granted reaches the schema
-- cache as an update of the existing _priv tuple, and is applied
-- as another grant. The grantee must not end up holding the role
-- twice, or the revoke below would leave half of the grant in
-- place and the user could no longer be dropped.
--
g.test_regrant_of_a_granted_role = function(cg)
    cg.server:exec(function()
        box.schema.user.create('u')
        box.schema.role.create('r')
        box.schema.user.grant('u', 'r')

        local uid = box.space._user.index.name:get('u')[1]
        local rid = box.space._user.index.name:get('r')[1]
        box.space._priv:replace(box.space._priv:get{uid, 'role', rid})

        box.schema.user.revoke('u', 'r')
        box.schema.user.drop('u')
        box.schema.role.drop('r')
    end)
end
