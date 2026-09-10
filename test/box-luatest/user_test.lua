local t = require('luatest')
local server = require('luatest.server')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
    cg.builtin_uids = cg.server:exec(function()
        local uids = {}
        for _, tuple in box.space._user:pairs() do
            table.insert(uids, tuple.id)
        end
        return uids
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

-- The server is shared by every case, so each one takes back
-- what it made. A user or a role left behind would hide a
-- failure to drop or to revoke.
g.after_each(function(cg)
    cg.server:exec(function(builtin_uids)
        if box.space.t ~= nil then
            box.space.t:drop()
        end
        local builtin = {}
        for _, uid in ipairs(builtin_uids) do
            builtin[uid] = true
        end
        local made = {}
        for _, tuple in box.space._user:pairs() do
            if not builtin[tuple.id] then
                table.insert(made, {tuple.id, tuple.type})
            end
        end
        for _, entry in ipairs(made) do
            if entry[2] == 'role' then
                box.schema.role.drop(entry[1])
            else
                box.schema.user.drop(entry[1])
            end
        end
        assert(box.space._user:count() == #builtin_uids)
    end, {cg.builtin_uids})
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


--
-- A grant at the bottom of a chain of roles has to reach the user
-- at the top of it. The rebuild advances one layer of the chain
-- per round, so a long chain takes many rounds to converge.
--
g.test_grant_reaches_the_end_of_a_role_chain = function(cg)
    cg.server:exec(function()
        local t = require('luatest')
        local n = 50
        for i = 1, n do
            box.schema.role.create('chain' .. i)
        end
        for i = 2, n do
            box.schema.role.grant('chain' .. i, 'chain' .. (i - 1))
        end
        box.schema.user.create('chain_user')
        box.schema.user.grant('chain_user', 'chain' .. n)

        local s = box.schema.space.create('t')
        s:create_index('pk')
        s:insert{1}
        box.schema.role.grant('chain1', 'read', 'space', 't')

        box.session.su('chain_user', function()
            t.assert_equals(box.space.t:select(), {{1}})
        end)
    end)
end

--
-- A role that holds another one both directly and through a third
-- one cannot be evaluated until that third one is done, so the
-- rebuild has to defer it to a later round. Which of the two the
-- round reaches first must not change the outcome.
--
g.test_grant_reaches_a_role_held_twice_over = function(cg)
    cg.server:exec(function()
        local t = require('luatest')
        box.schema.role.create('base')
        box.schema.role.create('mid')
        box.schema.role.create('top')
        box.schema.role.grant('mid', 'base')
        box.schema.role.grant('top', 'mid')
        box.schema.role.grant('top', 'base')
        box.schema.user.create('skip_user')
        box.schema.user.grant('skip_user', 'top')

        local s = box.schema.space.create('t')
        s:create_index('pk')
        s:insert{1}
        box.schema.role.grant('base', 'read', 'space', 't')

        box.session.su('skip_user', function()
            t.assert_equals(box.space.t:select(), {{1}})
        end)
    end)
end

--
-- Two users granted the same pair of roles in opposite orders end
-- up with the same rights: the rebuild accumulates the privileges
-- of the roles, and accumulation does not depend on the order the
-- roles are visited in.
--
g.test_grant_order_does_not_change_the_rights = function(cg)
    cg.server:exec(function()
        local t = require('luatest')
        local s = box.schema.space.create('t')
        s:create_index('pk')
        s:insert{1}

        box.schema.role.create('reader')
        box.schema.role.create('writer')
        box.schema.role.grant('reader', 'read', 'space', 't')
        box.schema.role.grant('writer', 'write', 'space', 't')

        for _, u in ipairs({'first', 'second'}) do
            box.schema.user.create(u)
        end
        box.schema.user.grant('first', 'reader')
        box.schema.user.grant('first', 'writer')
        box.schema.user.grant('second', 'writer')
        box.schema.user.grant('second', 'reader')

        box.session.su('first', function()
            t.assert_equals(box.space.t:select{1}, {{1}})
            box.space.t:insert{2}
        end)
        box.session.su('second', function()
            t.assert_equals(box.space.t:select{1}, {{1}})
            box.space.t:insert{3}
        end)
    end)
end

--
-- A role is a bundle of privileges to be granted onwards, not
-- somebody who can act. box.schema.role.grant refuses to hand a
-- role a system privilege, but the refusal is not the schema's:
-- writing the grant into _priv gets past it. Switching to a role
-- has to be refused whatever the role was granted.
--
g.test_cannot_switch_to_a_role = function(cg)
    cg.server:exec(function()
        local t = require('luatest')
        box.schema.role.create('actor')
        local rid = box.space._user.index.name:get('actor')[1]
        -- 'session' and 'usage' on the universe.
        box.space._priv:insert{1, rid, 'universe', 0, 8 + 16}

        -- Looking a role up by name already refuses it; by id
        -- it does not.
        t.assert_error(box.session.su, 'actor')
        t.assert_error(box.session.su, rid)
    end)
end

--
-- A setuid function runs as its owner, so a function owned by a
-- role is a second way into acting as one. The owner is taken
-- from the _func tuple, which can name a role outright.
--
g.test_cannot_run_setuid_as_a_role = function(cg)
    cg.server:exec(function()
        local t = require('luatest')
        box.schema.role.create('owner_role')
        local rid = box.space._user.index.name:get('owner_role')[1]

        box.schema.func.create('whoami', {
            body = 'function() return box.session.effective_user() end',
            setuid = true,
        })
        local tuple = box.space._func.index.name:get('whoami')
        box.space._func:delete{tuple[1]}
        box.space._func:insert(tuple:update{{'=', 2, rid}})

        t.assert_error(box.func.whoami.call, box.func.whoami)
    end)
end
