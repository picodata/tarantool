local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'collate-chain-depth'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

-- A chain of COLLATE clauses on one expression has the same depth limit
-- as other expressions.
g.test_collate_chain_depth_limit = function()
    g.server:exec(function()
        local function chain(count)
            return "SELECT 'a'" .. (' COLLATE "unicode_ci"'):rep(count) ..
                   " = 'A';"
        end
        t.assert_equals(box.execute(chain(1)).rows, {{true}})
        t.assert_equals(box.execute(chain(100)).rows, {{true}})
        for _, count in ipairs({250, 1000, 100000}) do
            local _, err = box.execute(chain(count))
            t.assert_equals(err.message, 'Number of nodes in expression ' ..
                            'tree 201 exceeds the limit (200)', count)
        end
        -- The instance works after the error.
        t.assert_equals(box.execute(chain(2)).rows, {{true}})
    end)
end

-- The chain can be on a column, in each clause that takes an expression.
g.test_collate_chain_on_column = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, s TEXT);]])
        box.execute([[INSERT INTO t VALUES (1, 'a'), (2, 'B');]])
        local collate = (' COLLATE "unicode_ci"'):rep(100000)
        for _, sql in ipairs({
            'SELECT s' .. collate .. ' FROM t;',
            'SELECT id FROM t WHERE s' .. collate .. " = 'A';",
            'SELECT id FROM t ORDER BY s' .. collate .. ';',
        }) do
            local _, err = box.execute(sql)
            t.assert_equals(err.message, 'Number of nodes in expression ' ..
                            'tree 201 exceeds the limit (200)')
        end
        local res = box.execute([[SELECT id FROM t ORDER BY s COLLATE
                                  "unicode_ci" COLLATE "unicode_ci";]])
        t.assert_equals(res.rows, {{1}, {2}})
        box.execute([[DROP TABLE t;]])
    end)
end
