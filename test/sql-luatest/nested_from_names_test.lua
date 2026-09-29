local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'nested-from-names'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE "t.1"("x.y" INTEGER PRIMARY KEY,
                                         y INTEGER);]])
        box.execute([[CREATE TABLE t2(p INTEGER PRIMARY KEY);]])
        box.execute([[INSERT INTO "t.1" VALUES (1, 10);]])
        box.execute([[INSERT INTO t2 VALUES (2), (3);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The columns of a parenthesized join are matched by their "table.column"
-- names, and both parts of such a name may contain dots.
g.test_dotted_names = function()
    g.server:exec(function()
        -- The alias keeps the join from being flattened.
        local from = [[FROM (("t.1" CROSS JOIN t2) AS s CROSS JOIN t2 AS u)]]

        local sql = [[SELECT "x.y", "t.1"."x.y", "t.1".y ]]..from..
                    [[ ORDER BY s.p, u.p;]]
        local result = box.execute(sql)
        t.assert_equals(result.rows,
                        {{1, 1, 10}, {1, 1, 10}, {1, 1, 10}, {1, 1, 10}})

        sql = [[SELECT "t.1".* ]]..from..[[ ORDER BY s.p, u.p;]]
        result = box.execute(sql)
        t.assert_equals(result.metadata, {
            {name = 'x.y', type = 'integer'},
            {name = 'Y', type = 'integer'},
        })
        t.assert_equals(#result.rows, 4)

        -- The table name is not split at the dot.
        local _, err = box.execute([[SELECT "1"."x.y" ]]..from..[[;]])
        t.assert_equals(err.message,
                        "Field 'x.y' was not found in space '1' format")
        _, err = box.execute([[SELECT "1.x.y" ]]..from..[[;]])
        t.assert_equals(err.message, "Can’t resolve field '1.x.y'")
    end)
end

-- An alias is an identifier like any other, so it may not be empty.
g.test_empty_alias = function()
    g.server:exec(function()
        local invalid = "Invalid identifier '' (expected printable " ..
                        "symbols only or it is too long)"
        for _, sql in ipairs({
            [[SELECT * FROM t2 AS "";]],
            [[SELECT * FROM t2 "";]],
            [[SELECT * FROM (SELECT 1) AS "";]],
            [[SELECT * FROM ("t.1", t2) AS "";]],
            [[WITH "" AS (SELECT 1) SELECT * FROM "";]],
            [[WITH c AS (SELECT 1), "" AS (SELECT 2) SELECT * FROM c;]],
        }) do
            local _, err = box.execute(sql)
            t.assert_equals(err.message, invalid, sql)
        end
    end)
end
