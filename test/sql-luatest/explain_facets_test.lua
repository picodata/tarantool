local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-facets'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        -- Returns the names of the columns of EXPLAIN with the given
        -- text after the keyword, or the error message.
        rawset(_G, 'columns', function(facets)
            local sql = ('EXPLAIN %s SELECT a FROM t;'):format(facets)
            local res, err = box.execute(sql)
            if res == nil then
                return err.message
            end
            local names = {}
            for _, meta in ipairs(res.metadata) do
                table.insert(names, meta.name)
            end
            return names
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- Each facet is a group of columns. Plain EXPLAIN shows the facet
-- "pseudocode".
g.test_columns = function()
    g.server:exec(function()
        local opcode = {'addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5'}
        local pseudocode = {'addr', 'pseudocode'}
        t.assert_equals(_G.columns(''), pseudocode)
        t.assert_equals(_G.columns('(pseudocode)'), pseudocode)
        t.assert_equals(_G.columns('(opcode)'), opcode)
        -- The name of a facet is not case-sensitive.
        t.assert_equals(_G.columns('(OPCODE)'), opcode)
    end)
end

-- The columns of "opcode" come before the columns of "pseudocode". The
-- order of the facets in the list and a facet that is given two times
-- change nothing.
g.test_column_order = function()
    g.server:exec(function()
        local both = {'addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5',
                      'addr', 'pseudocode'}
        t.assert_equals(_G.columns('(opcode, pseudocode)'), both)
        t.assert_equals(_G.columns('(pseudocode, opcode)'), both)
        t.assert_equals(_G.columns('(opcode, pseudocode, opcode)'), both)
    end)
end

-- The types of the columns, and the rows: the address in "pseudocode" is
-- the address in "opcode".
g.test_rows = function()
    g.server:exec(function()
        local res = box.execute([[EXPLAIN (opcode, pseudocode) SELECT 1;]])
        local types = {}
        for _, meta in ipairs(res.metadata) do
            table.insert(types, meta.type)
        end
        t.assert_equals(types, {'integer', 'text', 'integer', 'integer',
                                'integer', 'text', 'text', 'integer',
                                'text'})
        t.assert_equals(res.rows, {
            {0, 'Init', 0, 1, 0, '', '00', 0, 'START AT 1'},
            {1, 'Integer', 1, 1, 0, '', '00', 1, 'r[1] = 1'},
            {2, 'ResultRow', 1, 1, 0, '', '00', 2, 'OUTPUT r[1]'},
            {3, 'Halt', 0, 0, 0, '', '00', 3, 'HALT'},
        })
    end)
end

-- A prepared statement has the columns of its facets.
g.test_prepared = function()
    g.server:exec(function()
        local stmt = box.prepare([[EXPLAIN (opcode) SELECT a FROM t;]])
        local names = {}
        for _, meta in ipairs(stmt.metadata) do
            table.insert(names, meta.name)
        end
        local res = stmt:execute()
        stmt:unprepare()
        t.assert_equals(names, {'addr', 'opcode', 'p1', 'p2', 'p3', 'p4',
                                'p5'})
        t.assert_equals(#res.rows[1], 7)
    end)
end

-- A name that is not a facet, an empty list and a list before QUERY PLAN
-- are errors.
g.test_errors = function()
    g.server:exec(function()
        t.assert_str_contains(_G.columns('(kek)'),
                              "Unknown EXPLAIN facet 'kek'")
        t.assert_str_contains(_G.columns('(opcode, kek)'),
                              "Unknown EXPLAIN facet 'kek'")
        t.assert_str_contains(_G.columns('()'), "Syntax error")
        t.assert_str_contains(_G.columns('(opcode,)'), "Syntax error")
        t.assert_str_contains(_G.columns('(opcode) QUERY PLAN'),
                              "Syntax error")
    end)
end

-- EXPLAIN QUERY PLAN has its own columns.
g.test_query_plan = function()
    g.server:exec(function()
        t.assert_equals(_G.columns('QUERY PLAN'),
                        {'selectid', 'order', 'from', 'detail'})
    end)
end
