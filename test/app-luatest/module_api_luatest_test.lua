local t = require('luatest')
local server = require('luatest.server')

local g = t.group()

g.before_all(function()
    g.server = server:new()
    g.server:start()

    g.user_name = "test_box_access_check_ddl_user"
    g.another_user_name = "test_box_access_check_ddl_user2"
    g.space_name = "test_box_access_check_ddl_space"
    g.role_name = "test_box_access_check_ddl_test_role"
    g.server:exec(function(user_name, space_name, role_name, another_user_name)
        box.schema.user.create(user_name, {password = 'foobar'})
        box.schema.user.create(another_user_name, {password = 'foobar'})
        box.schema.space.create(space_name)
        box.schema.role.create(role_name)
        local lua_code = [[function(a, b) return a + b end]]
        box.schema.func.create('sum', {body = lua_code})
    end, {g.user_name, g.space_name, g.role_name, g.another_user_name})
end)

g.after_all(function()
    g.server:exec(function(user_name)
        box.schema.user.drop(user_name)
    end, {g.user_name})
end)

g.test_box_access_check_ddl = function()
    g.server:exec(function(user_name, space_name, role_name, another_user_name)
        local function test_access(
            user_name, object_name, object_id, object_type,
            access, expected_ret, expected_msg
        )
            box.error.clear()

            box.session.su(user_name, function()
                local ffi = require('ffi')
                local r = ffi.C.box_access_check_ddl(
                    object_name,
                    object_id,
                    1 --[[admin]],
                    object_type,
                    access)
                local e = tostring(box.error.last())
                t.assert_equals(r, expected_ret, "Error: " .. e)
                if expected_msg ~= nil then
                    t.assert_str_matches(e, expected_msg)
                end
            end)
        end

        local function expected_msg(priv, obj)
            return priv .. " access to " .. obj .. ".+ is denied for user .+"
        end
        local ffi = require('ffi')
        ffi.cdef([[
            enum box_schema_object_type {
                BOX_SC_UNKNOWN = 0,
                BOX_SC_UNIVERSE = 1,
                BOX_SC_SPACE = 2,
                BOX_SC_FUNCTION = 3,
                BOX_SC_USER = 4,
                BOX_SC_ROLE = 5,
                BOX_SC_SEQUENCE = 6,
                BOX_SC_COLLATION = 7,
                /*
                 * All object types are supposed to be above this point,
                 * all entity types - below.
                 */
                schema_object_type_MAX = 8,
                BOX_SC_ENTITY_SPACE,
                BOX_SC_ENTITY_FUNCTION,
                BOX_SC_ENTITY_USER,
                BOX_SC_ENTITY_ROLE,
                BOX_SC_ENTITY_SEQUENCE,
                BOX_SC_ENTITY_COLLATION,
                schema_entity_type_MAX = 15
            };

            int box_access_check_ddl(
                const char *name, uint32_t object_id, uint32_t owner_uid,
                enum box_schema_object_type object_type, uint16_t access);
        ]])

        local priv_to_name = {}
        -- permissions granted on all entities of type globally
        priv_to_name[box.priv.C] = "Create"
        priv_to_name[box.priv.D] = "Drop"
        -- permissions granted globally or on particular entity
        priv_to_name[box.priv.R] = "Read"
        priv_to_name[box.priv.W] = "Write"
        priv_to_name[box.priv.A] = "Alter"
        priv_to_name[box.priv.X] = "Execute"

        -- space CREATE (global permission, without particular entity)
        test_access(
            user_name,
            "space_to_be_created",
            42,
            2, -- BOX_SC_SPACE
            box.priv.C,
            -1,
            expected_msg(priv_to_name[box.priv.C], 'space')
        )

        box.session.su('admin', function()
            box.schema.user.grant(
                user_name,
                string.lower(priv_to_name[box.priv.C]),
                "space")
        end)

        test_access(
            user_name,
            "space_to_be_created",
            42,
            2, -- BOX_SC_SPACE
            box.priv.C,
            0,
            nil
        )

        -- space (particular entity) read write alter drop
        for _, priv in ipairs(
            {box.priv.R, box.priv.W, box.priv.A, box.priv.D}
        ) do
            test_access(
                user_name,
                space_name,
                box.space[space_name].id,
                2, -- BOX_SC_SPACE
                priv,
                -1,
                expected_msg(priv_to_name[priv], 'space')
            )

            box.session.su('admin', function()
                box.schema.user.grant(
                    user_name,
                    string.lower(priv_to_name[priv]),
                    "space",
                    box.space[space_name].id)
            end)

            test_access(
                user_name,
                space_name,
                box.space[space_name].id,
                2, -- BOX_SC_SPACE
                priv,
                0,
                nil
            )
        end

        -- user - create (global permission, without particular entity)
        test_access(
            user_name,
            "user_to_be_created",
            42,
            4, -- BOX_SC_USER
            box.priv.C,
            -1,
            expected_msg(priv_to_name[box.priv.C], 'user')
        )

        box.session.su('admin', function()
            box.schema.user.grant(
                user_name,
                string.lower(priv_to_name[box.priv.C]),
                "user")
        end)

        test_access(
            user_name,
            "user_to_be_created",
            42,
            4, -- BOX_SC_USER
            box.priv.C,
            0,
            nil
        )

        -- user (particular entity) alter drop
        local another_user_id = box.space._user.index.name:select(
            {another_user_name}
        )[1][1];
        for _, priv in ipairs({box.priv.A, box.priv.D}) do
            test_access(
                user_name,
                another_user_name,
                another_user_id,
                4, -- BOX_SC_USER
                priv,
                -1,
                expected_msg(priv_to_name[priv], 'user')
            )

            box.session.su('admin', function()
                box.schema.user.grant(
                    user_name,
                    string.lower(priv_to_name[priv]),
                    "user",
                    another_user_id)
            end)

            test_access(
                user_name,
                another_user_name,
                another_user_id,
                4, -- BOX_SC_USER
                priv,
                0,
                nil
            )
        end

        -- role - create (global permission, without particular entity)
        test_access(
            user_name,
            role_name,
            42, -- no entity id
            5, -- BOX_SC_ROLE
            box.priv.C,
            -1,
            expected_msg(priv_to_name[box.priv.C], 'role')
        )

        box.session.su('admin', function()
            box.schema.user.grant(
                user_name,
                string.lower(priv_to_name[box.priv.C]),
                "role")
        end)

        test_access(
            user_name,
            role_name,
            0,
            5, -- BOX_SC_ROLE
            box.priv.C,
            0,
            nil
        )

        -- role - drop (particular entity)
        local role_id = box.space._user.index.name:select({role_name})[1][1];
        test_access(
            user_name,
            role_name,
            role_id,
            5, -- BOX_SC_ROLE
            box.priv.D,
            -1,
            expected_msg(priv_to_name[box.priv.D], 'role')
        )

        box.session.su('admin', function()
            box.schema.user.grant(
                user_name,
                string.lower(priv_to_name[box.priv.D]),
                "role",
                role_id)
        end)

        test_access(
            user_name,
            role_name,
            role_id,
            5, -- BOX_SC_ROLE
            box.priv.D,
            0,
            nil
        )

        -- function - create (global permission, without particular entity)
        test_access(
            user_name,
            role_name,
            0, -- no entity id
            3, -- BOX_SC_FUNCTION
            box.priv.C,
            -1,
            expected_msg(priv_to_name[box.priv.C], 'function')
        )

        box.session.su('admin', function()
            box.schema.user.grant(
                user_name,
                string.lower(priv_to_name[box.priv.C]),
                "function")
        end)

        test_access(
            user_name,
            role_name,
            0,
            3, -- BOX_SC_FUNCTION
            box.priv.C,
            0,
            nil
        )

        -- function - execute, drop (particular entity)
        local func_id = box.func.sum.id;
        for _, priv in ipairs({box.priv.X, box.priv.D}) do
            test_access(
                user_name,
                'sum',
                func_id,
                3, -- BOX_SC_FUNCTION
                priv,
                -1,
                expected_msg(priv_to_name[priv], "function")
            )

            box.session.su('admin', function()
                box.schema.user.grant(
                    user_name,
                    string.lower(priv_to_name[priv]),
                    "function",
                    "sum")
            end)

            test_access(
                user_name,
                'sum',
                func_id,
                3, -- BOX_SC_FUNCTION
                priv,
                0,
                nil
            )
        end

    end, {g.user_name, g.space_name, g.role_name, g.another_user_name})
end
