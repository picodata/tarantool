local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'cast-expr-compare'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (k INTEGER PRIMARY KEY, c DOUBLE);]])
        box.execute([[INSERT INTO t VALUES (1, 1.5e0), (2, 2.5e0);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- Aggregates whose arguments differ only in the type they cast to must be
-- computed separately rather than share one result.
g.test_aggregates_of_casts_to_different_types = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT SUM(CAST(c AS INTEGER)), SUM(CAST(c AS DOUBLE)) FROM t;]])
        t.assert_equals(res.metadata[1].type, 'integer')
        t.assert_equals(res.metadata[2].type, 'double')
        t.assert_equals(res.rows, {{3, 4}})

        res = box.execute([[
            SELECT AVG(CAST(c AS INTEGER)), AVG(CAST(c AS DOUBLE)) FROM t;]])
        t.assert_equals(res.rows, {{1, 2}})
    end)
end
