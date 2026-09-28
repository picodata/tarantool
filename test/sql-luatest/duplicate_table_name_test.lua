local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'duplicate-table-name'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t(x INTEGER PRIMARY KEY, y INTEGER);]])
        box.execute([[CREATE TABLE s(x INTEGER PRIMARY KEY, z INTEGER);]])
        box.execute([[INSERT INTO t VALUES (1, 2);]])
        box.execute([[INSERT INTO s VALUES (1, 3);]])
        box.execute([[CREATE VIEW v AS
                      SELECT t.x, s.z FROM t JOIN s USING (x);]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- Two items of a FROM clause may not be visible under the same table name,
-- whether or not a column is referenced by it, and whatever the items are.
g.test_duplicate_table_name = function()
    g.server:exec(function()
        for _, case in ipairs({
            {[[SELECT q.* FROM (SELECT 1 AS a, 2 AS a) AS q
               CROSS JOIN (SELECT 3 AS a, 4 AS a) AS q;]], 'Q'},
            {[[SELECT 1 FROM t, t;]], 'T'},
            {[[SELECT 1 FROM t, s AS t;]], 'T'},
            {[[SELECT 1 FROM t, (SELECT 1) AS t;]], 'T'},
            {[[SELECT 1 FROM t AS "T", s AS t;]], 'T'},
            {[[SELECT 1 FROM t AS a JOIN s AS a USING (x);]], 'A'},
            {[[SELECT 1 FROM t AS a JOIN s AS a ON TRUE;]], 'A'},
            {[[SELECT 1 FROM v AS a, t AS a;]], 'A'},
            {[[WITH q AS (SELECT 1) SELECT 1 FROM q, q;]], 'Q'},
            {[[SELECT 1 FROM (t JOIN s USING (x)) AS j, t AS j;]], 'J'},
            {[[SELECT 1 FROM (t AS a JOIN s AS a USING (x)) AS j;]], 'A'},
            {[[SELECT 1 FROM (t), t;]], 'T'},
            {[[SELECT (SELECT COUNT(*) FROM t, t);]], 'T'},
        }) do
            local sql, name = unpack(case)
            local _, err = box.execute(sql)
            t.assert_not_equals(err, nil, sql)
            t.assert_equals(err.message, ('table name "%s" specified more ' ..
                                          'than once'):format(name), sql)
        end
    end)
end

-- The tables inside a parenthesized join without an alias are visible by
-- their own names, so they may not repeat a name outside of it either.
g.test_unaliased_join = function()
    g.server:exec(function()
        for _, sql in ipairs({
            [[SELECT 1 FROM (t JOIN s USING (x)), t;]],
            [[SELECT 1 FROM t JOIN (s JOIN t USING (x)) USING (x);]],
            [[SELECT 1 FROM ((s JOIN t USING (x)) JOIN s AS u USING (x))
              CROSS JOIN (SELECT 1) AS t;]],
        }) do
            local _, err = box.execute(sql)
            t.assert_not_equals(err, nil, sql)
            t.assert_equals(err.message,
                            'table name "T" specified more than once', sql)
        end
    end)
end

-- Distinct names are fine: an alias hides the name of its table, and that of
-- a join hides the names inside it. So are a quoted name differing in case,
-- subqueries without an alias, and the same name in a nested query.
g.test_distinct_table_names = function()
    g.server:exec(function()
        for _, case in ipairs({
            {[[SELECT * FROM t, t AS u;]], {{1, 2, 1, 2}}},
            {[[SELECT * FROM t AS "t", s AS t;]], {{1, 2, 1, 3}}},
            {[[SELECT 1 FROM (t JOIN s USING (x)) AS j, t;]], {{1}}},
            {[[SELECT * FROM (t JOIN s USING (x)) AS t;]], {{1, 2, 3}}},
            {[[SELECT * FROM (t AS u), t;]], {{1, 2, 1, 2}}},
            {[[SELECT * FROM v, t;]], {{1, 3, 1, 2}}},
            {[[WITH q AS (SELECT 1) SELECT * FROM q, q AS r;]], {{1, 1}}},
            {[[SELECT * FROM (SELECT 1), (SELECT 2);]], {{1, 2}}},
            {[[SELECT * FROM t AS a WHERE EXISTS (SELECT * FROM s AS a);]],
             {{1, 2}}},
        }) do
            local sql, rows = unpack(case)
            local res, err = box.execute(sql)
            t.assert_equals(err, nil, sql)
            t.assert_equals(res.rows, rows, sql)
        end
    end)
end
