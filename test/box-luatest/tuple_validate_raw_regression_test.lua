local server = require('luatest.server')
local t = require('luatest')

local g = t.group('validate_metadata_size', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

g.before_each(function(cg)
    cg.server = server:new{box_cfg = {}}
    cg.server:start()
end)

g.after_each(function(cg)
    cg.server:stop()
end)


g.test_multikey_meta_too_big = function(cg)
    cg.server:exec(function(engine)
        box.schema.space.create("test", { engine = engine })
        box.space.test:create_index("primary", {
            parts = { { field = 1, type = "str" } },
            unique = true,
        })

        local tup = { "pk1", {}, "value" }
        for i = 1, 9000 do
          table.insert(tup[2], { i })
        end
        box.space.test:insert(tup)

        local bad_operation = function()
            box.space.test:create_index("broken", {
                parts = { { path = "[*][1]", type = "unsigned", field = 2 } }
            })
        end

        t.assert_error_msg_matches(
            "Can't create tuple: metadata size .+ is too big",
            bad_operation)
    end)
end
