local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-full-metadata'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY AUTOINCREMENT,
                                      a INT,
                                      s TEXT COLLATE "unicode_ci");]])
        box.execute([[CREATE VIEW v AS SELECT a FROM t;]])
        box.execute([[INSERT INTO t(a, s) VALUES (1, 'x');]])
        -- Returns the names of the result columns and the number of the
        -- rows of the statement.
        rawset(_G, 'names_and_row_count', function(sql)
            local res, err = box.execute(sql)
            t.assert_equals(err, nil, sql)
            local names = {}
            for i, column in ipairs(res.metadata) do
                names[i] = column.name
            end
            return {names, #res.rows}
        end)
        -- The statements whose queries have a result column that is
        -- a column of a table or has a collation.
        rawset(_G, 'statements', {
            [[EXPLAIN SELECT a FROM t;]],
            [[EXPLAIN SELECT s FROM t;]],
            [[EXPLAIN SELECT id, a, s FROM t ORDER BY a;]],
            [[EXPLAIN SELECT 'a' COLLATE "unicode_ci";]],
            [[EXPLAIN SELECT a FROM v;]],
            [[EXPLAIN SELECT a FROM (SELECT a FROM t);]],
            [[EXPLAIN SELECT a FROM t UNION SELECT a FROM t;]],
            [[EXPLAIN SELECT a FROM t UNION ALL SELECT a FROM t;]],
            [[EXPLAIN QUERY PLAN SELECT * FROM t WHERE a = 5;]],
            [[EXPLAIN (ANALYZE {'mode': 'hits'}) SELECT a FROM t;]],
        })
    end)
end)

g.after_all(function()
    g.server:stop()
end)

g.after_each(function()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_full_metadata" = false;]])
    end)
end)

-- EXPLAIN gives the same result columns and rows with the full metadata
-- on as with the full metadata off.
g.test_explain_with_full_metadata = function()
    g.server:exec(function()
        local expected = {}
        for i, sql in ipairs(_G.statements) do
            expected[i] = _G.names_and_row_count(sql)
            t.assert_gt(expected[i][2], 0, sql)
        end
        box.execute([[SET SESSION "sql_full_metadata" = true;]])
        for i, sql in ipairs(_G.statements) do
            t.assert_equals(_G.names_and_row_count(sql), expected[i], sql)
        end
    end)
end

-- A prepared EXPLAIN works with the full metadata on.
g.test_prepared_explain_with_full_metadata = function()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_full_metadata" = true;]])
        for _, sql in ipairs(_G.statements) do
            local stmt, err = box.prepare(sql)
            t.assert_equals(err, nil, sql)
            t.assert_gt(#stmt:execute().rows, 0, sql)
            stmt:unprepare()
        end
    end)
end

-- A query with no EXPLAIN has the full metadata, also after an EXPLAIN of
-- the same query.
g.test_query_keeps_full_metadata = function()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_full_metadata" = true;]])
        box.execute([[EXPLAIN SELECT id, a, s FROM t;]])
        local res = box.execute([[SELECT id, a, s FROM t;]])
        t.assert_equals(res.rows, {{1, 1, 'x'}})
        t.assert_equals(res.metadata, {
            {name = 'ID', span = 'ID', type = 'integer', is_nullable = false,
             is_autoincrement = true},
            {name = 'A', span = 'A', type = 'integer', is_nullable = true},
            {name = 'S', span = 'S', type = 'string', is_nullable = true,
             collation = 'unicode_ci'},
        })
    end)
end
