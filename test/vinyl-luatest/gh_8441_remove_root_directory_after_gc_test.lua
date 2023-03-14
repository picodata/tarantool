local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new({alias = 'master'})
    cg.server:start()
    cg.server:exec(function()
        box.schema.space.create("test", {
            format = {
                { "id", "unsigned", is_nullable = false },
                { "a", "unsigned", is_nullable = false }
            },
            engine = "vinyl",
            if_not_exists = true
        })
        box.space.test:create_index("id", {
            type = "TREE",
            unique = true,
            if_not_exists = true,
            parts = { { field = "id", type = "unsigned" } },
        })
        box.space.test:create_index("a", {
            type = "TREE",
            unique = false,
            if_not_exists = true,
            parts = { { field = "a", type = "unsigned" } },
        })
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.test_root_directory_is_removed_after_gc = function(cg)
    cg.server:exec(function()
        local fio = require('fio')

        -- Make each snapshot trigger garbage collection.
        box.cfg{checkpoint_count = 1}

        local space_id = box.space.test.id

        -- Populate runs with data.
        for i=1,10000 do box.space.test:insert({i, i}) end

        -- Flush runs to disk.
        box.snapshot()

        box.space.test:drop()

        -- Remove run files and LSM root.
        box.snapshot()

        -- Check that all LSM directories are removed.
        local expected_err_msg = "No such file or directory"

        local r, e = fio.listdir(fio.pathjoin(box.cfg.vinyl_dir, space_id, 0))
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), expected_err_msg)

        r, e = fio.listdir(fio.pathjoin(box.cfg.vinyl_dir, space_id, 1))
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), expected_err_msg)

        r, e = fio.listdir(fio.pathjoin(box.cfg.vinyl_dir, space_id))
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), expected_err_msg)
    end)
end
