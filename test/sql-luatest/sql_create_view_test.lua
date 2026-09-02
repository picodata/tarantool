local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (a INT PRIMARY KEY, b INT, c STRING);]])
        box.execute([[INSERT INTO t VALUES (1, 2, 'x');]])
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

-- sql_create_view() copied the text of the statement into the definition of
-- the parser template space, which lives on the parser region and is never
-- passed to space_def_delete(). The copy is only needed until
-- vdbe_emit_space_create() has serialized the definition.
--
-- Creating and dropping a view also compiles the stored text of the view
-- with a parse-only parser, which used to store a duplicate of the SELECT
-- tree and lose the original one along with the column aliases.
g.test_create_and_drop_view = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res = box.execute(
                [[CREATE VIEW v (x, y, z) AS SELECT a, b, c FROM t;]])
            t.assert_equals(res.row_count, 1)
            res = box.execute([[DROP VIEW v;]])
            t.assert_equals(res.row_count, 1)
        end
    end)
end

-- Every SELECT from a view compiles the stored text of the view once more.
g.test_select_from_view = function()
    g.server:exec(function()
        box.execute([[CREATE VIEW vs (x, y, z) AS SELECT a, b, c FROM t;]])
        for _ = 1, 20 do
            local res = box.execute([[SELECT x, y, z FROM vs WHERE x > 0;]])
            t.assert_equals(res.rows, {{1, 2, 'x'}})
        end
    end)
end

-- DML on a view compiles the stored text of the view before reporting that
-- the space is not writable. The SELECT tree is owned by the caller of
-- sql_view_compile() now, so this is a use-after-free guard as well.
g.test_dml_on_view = function()
    g.server:exec(function()
        box.execute([[CREATE VIEW vd (x, y, z) AS SELECT a, b, c FROM t;]])
        local stmts = {
            [[INSERT INTO vd VALUES (2, 3, 'y');]],
            [[UPDATE vd SET y = 3;]],
            [[DELETE FROM vd WHERE x > 0;]],
        }
        for _ = 1, 20 do
            for _, sql in ipairs(stmts) do
                local res, err = box.execute(sql)
                t.assert_equals(res, nil)
                t.assert_equals(err.message,
                                "Can't modify space 'VD': space is a view")
            end
        end
    end)
end
