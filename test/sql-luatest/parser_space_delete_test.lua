local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (a INT PRIMARY KEY, b INT UNIQUE,
                                      c INT UNIQUE);]])
    end)
end)

-- Server:stop() fails on any LeakSanitizer report in the instance stderr.
-- Until the instance shutdown is complete (see the lj_BC_FUNCC comment in
-- asan/lsan.supp), an ASAN build running with the SQL LSan profile reports
-- unrelated leaks as well, so only the SQL ones are checked here.
g.after_all(function()
    local ok, err = pcall(g.server.stop, g.server)
    if ok then
        return
    end
    err = tostring(err)
    if not err:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    g.server:save_artifacts()
    t.assert_not_str_contains(err, 'src/box/sql/', false,
                              'LSan reported a leak in SQL')
end)

-- parser_space_delete() decided that the request is ALTER TABLE ADD COLUMN
-- whenever a space with the name of the parser template space existed, and
-- kept the index definitions of that space. For CREATE TABLE of an already
-- existing name the definitions are built by the parser, so they leaked.
g.test_create_table_if_not_exists = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res = box.execute(
                [[CREATE TABLE IF NOT EXISTS t (x INT PRIMARY KEY,
                                                y INT UNIQUE);]])
            t.assert_equals(res.row_count, 0)
        end
    end)
end

g.test_create_table_duplicate_name = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res, err = box.execute(
                [[CREATE TABLE t (x INT PRIMARY KEY, y INT UNIQUE,
                                  z INT UNIQUE);]])
            t.assert_equals(res, nil)
            t.assert_equals(err.message, "Space 'T' already exists")
        end
    end)
end

-- ALTER TABLE ADD COLUMN builds a shallow space copy that shares the index
-- definitions of the altered space, so they must stay untouched. This is a
-- guard rather than a reproducer: under ASAN a wrong condition in
-- parser_space_delete() shows up here as a double free, not as a leak.
g.test_alter_table_add_column = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE a (i INT PRIMARY KEY, j INT UNIQUE,
                                      k INT UNIQUE);]])
        for n = 1, 20 do
            local res = box.execute(
                ('ALTER TABLE a ADD COLUMN c%d INT;'):format(n))
            t.assert_not_equals(res, nil)
        end
    end)
end
