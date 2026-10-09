local server = require('luatest.server')
local t = require('luatest')

local g = t.group('skip_scan', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

-- Reference queries carry NOT INDEXED. In this fork it only disables
-- automatic indexes: the planner may still choose a secondary index,
-- but never a skip-scan, which needs INDEXED BY. A reference is thus
-- "without INDEXED BY" rather than "a full scan".

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
    cg.server:exec(function()
        local h = {}
        rawset(_G, 'skip_scan_test', h)

        h.sql = function(sql, params, options)
            local result, err = box.execute(sql, params or {}, options or {})
            t.assert(result, tostring(err) .. ': ' .. sql)
            return result
        end

        h.plan = function(sql, params)
            local details = {}
            for _, row in ipairs(h.sql('EXPLAIN QUERY PLAN ' .. sql,
                                      params).rows) do
                table.insert(details, row[4])
            end
            return table.concat(details, '\n')
        end

        h.rows = function(sql, expected, params)
            t.assert_equals(h.sql(sql, params).rows, expected, sql)
        end

        h.skip = function(sql, expected, params)
            t.assert_str_contains(h.plan(sql, params), 'ANY(BUCKET_ID)')
            h.rows(sql, expected, params)
        end
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.before_each(function(cg)
    cg.server:exec(function(engine)
        local h = _G.skip_scan_test
        local engines = {
            memtx = [[SET SESSION "sql_default_engine"='memtx']],
            vinyl = [[SET SESSION "sql_default_engine"='vinyl']],
        }
        h.sql(engines[engine])
        h.sql([[CREATE TABLE t(id INTEGER PRIMARY KEY,
                              bucket_id INTEGER NOT NULL,
                              k INTEGER, payload STRING)]])
        h.sql('CREATE INDEX bk ON t(bucket_id, k)')
        h.sql([[INSERT INTO t VALUES
                (1,1,NULL,'null'), (2,1,1,'a'), (3,1,3,'b'),
                (4,2,NULL,'c'), (5,2,2,'d'), (6,2,4,'e'),
                (7,3,1,'f'), (8,3,3,'g')]])
    end, {cg.params.engine})
end)

g.after_each(function(cg)
    cg.server:exec(function()
        box.execute([[SET SESSION "sql_seq_scan"=true]])
        box.execute([[SET SESSION "sql_reverse_unordered_selects"=false]])
        for _, sql in ipairs({
            'DROP VIEW IF EXISTS vw',
            'DROP TABLE IF EXISTS t',
            'DROP TABLE IF EXISTS u',
            'DROP TABLE IF EXISTS v',
            'DROP TABLE IF EXISTS j',
        }) do
            assert(box.execute(sql))
        end
    end)
end)

g.test_dml = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local original = h.sql('SELECT * FROM t ORDER BY id').rows
        for _, case in ipairs({
            {
                sql = 'DELETE FROM t INDEXED BY bk WHERE k=2',
                ids = {{5}},
            },
            {
                sql = [[UPDATE t INDEXED BY bk SET payload='changed'
                        WHERE k=2]],
                ids = {{5}},
                update = true,
            },
            {
                sql = 'DELETE FROM t INDEXED BY bk WHERE k IN (2,3)',
                ids = {{3}, {5}, {8}},
            },
            {
                sql = [[UPDATE t INDEXED BY bk SET payload='changed'
                        WHERE k IN (2,3)]],
                ids = {{3}, {5}, {8}},
                update = true,
            },
            {
                sql = 'DELETE FROM t INDEXED BY bk WHERE k>=3',
                ids = {{3}, {6}, {8}},
            },
            {
                sql = [[UPDATE t INDEXED BY bk SET payload='changed'
                        WHERE k>=3]],
                ids = {{3}, {6}, {8}},
                update = true,
            },
        }) do
            box.begin()
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID)')
            t.assert_equals(h.sql(case.sql).row_count, #case.ids, case.sql)
            if case.update then
                h.rows([[SELECT id FROM t WHERE payload='changed'
                         ORDER BY id]], case.ids)
            else
                for _, row in ipairs(case.ids) do
                    h.rows('SELECT id FROM t WHERE id=?', {}, row)
                end
            end
            box.rollback()
            h.rows('SELECT * FROM t ORDER BY id', original)
        end
    end)
end

g.test_range_bounds = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k>=2 AND k<4 ORDER BY id]], {{3}, {5}, {8}})
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k>2 AND k<=4 ORDER BY id]], {{3}, {6}, {8}})
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k<2 ORDER BY id',
               {{2}, {7}})
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k>3 ORDER BY id', {{6}})
    end)
end

g.test_bound_parameters_and_reverse_scan = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT id FROM t INDEXED BY bk
                      WHERE k>=CAST(? AS INTEGER) AND k<=CAST(? AS INTEGER)
                      ORDER BY bucket_id DESC,k DESC]]
        h.skip(sql, {{8}, {7}, {5}, {3}, {2}}, {1, 3})
        h.skip(sql, {{5}}, {2, 2})
    end)
end

g.test_key_types_and_desc_prefix = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        -- The captured value of a skipped part drives the next seeks.
        -- Rows inserted from Lua keep the engine encoding, e.g. integers
        -- in a DOUBLE field.
        for _, case in ipairs({
            {type = 'DOUBLE', sql = {'1.5', '2.5', 'NULL'}, lua = {1, 2}},
            {
                type = 'DECIMAL',
                sql = {"CAST('1.5' AS DECIMAL)", "CAST('2' AS DECIMAL)",
                       'NULL'},
            },
            {
                type = 'UUID',
                sql = {"CAST('00000000-0000-0000-0000-000000000002' AS UUID)",
                       "CAST('00000000-0000-0000-0000-000000000001' AS UUID)",
                       'NULL'},
            },
            {
                type = 'DATETIME',
                sql = {"CAST('2024-06-01T00:00:00Z' AS DATETIME)",
                       "CAST('2024-01-01T00:00:00Z' AS DATETIME)", 'NULL'},
            },
            {type = 'VARBINARY', sql = {"X'02'", "X'01'", 'NULL'}},
            {type = 'BOOLEAN', sql = {'TRUE', 'FALSE', 'NULL'}},
            {type = 'SCALAR', sql = {'1', "'a'", 'TRUE', '1.5', 'NULL'}},
        }) do
            h.sql('DROP TABLE IF EXISTS v')
            h.sql(('CREATE TABLE v(id INTEGER PRIMARY KEY, p %s, k INTEGER)')
                  :format(case.type))
            h.sql('CREATE INDEX pk2 ON v(p,k)')
            local id = 0
            for _, value in ipairs(case.sql) do
                for k = 1, 3 do
                    id = id + 1
                    h.sql(('INSERT INTO v VALUES (%d,%s,%d)')
                          :format(id, value, k))
                end
            end
            for _, value in ipairs(case.lua or {}) do
                for k = 1, 3 do
                    id = id + 1
                    box.space.V:insert({id, value, k})
                end
            end
            for _, where in ipairs({'k=2', 'k>=2', 'k<3', 'k IN (1,3)'}) do
                for _, order in ipairs({'p,k', 'p DESC,k DESC'}) do
                    local sql = ('SELECT id FROM v INDEXED BY pk2 WHERE %s ' ..
                                 'ORDER BY %s'):format(where, order)
                    local reference = ('SELECT id FROM v NOT INDEXED ' ..
                                       'WHERE %s ORDER BY %s,id')
                                      :format(where, order)
                    local plan = h.plan(sql)
                    t.assert_str_contains(plan, 'ANY(P)', false, case.type)
                    -- A suffix IN loop keeps the sorter.
                    if where:find('IN') == nil then
                        t.assert_not_str_contains(plan, 'TEMP B-TREE', false,
                                                  case.type)
                    end
                    h.rows(sql, h.sql(reference).rows)
                end
            end
        end

        -- A DESC skipped part: prefixes are visited in index order.
        h.sql('CREATE INDEX bdk ON t(bucket_id DESC,k)')
        for _, case in ipairs({
            {
                sql = [[SELECT id FROM t INDEXED BY bdk WHERE k>=2
                        ORDER BY bucket_id DESC,k]],
                rows = {{8}, {5}, {6}, {3}},
            },
            {
                sql = [[SELECT id FROM t INDEXED BY bdk WHERE k>=2
                        ORDER BY bucket_id,k DESC]],
                rows = {{3}, {6}, {5}, {8}},
            },
            {
                sql = [[SELECT id FROM t INDEXED BY bdk WHERE k=1
                        ORDER BY bucket_id DESC]],
                rows = {{7}, {2}},
            },
        }) do
            t.assert_not_str_contains(h.plan(case.sql), 'TEMP B-TREE')
            h.skip(case.sql, case.rows)
        end

        -- A composite primary key named by INDEXED BY.
        h.sql([[CREATE TABLE u(bucket_id INTEGER NOT NULL,
                              k INTEGER NOT NULL, payload STRING,
                              CONSTRAINT upk PRIMARY KEY (bucket_id,k))]])
        h.sql([[INSERT INTO u VALUES (1,1,'a'),(1,3,'b'),(2,2,'c'),
                (2,4,'d'),(3,1,'e'),(3,3,'f')]])
        h.skip([[SELECT payload FROM u INDEXED BY upk WHERE k=3
                 ORDER BY bucket_id]], {{'b'}, {'f'}})
        h.skip([[SELECT payload FROM u INDEXED BY upk WHERE k>=2 AND k<4
                 ORDER BY bucket_id DESC]], {{'f'}, {'c'}, {'b'}})
    end)
end

g.test_dml_or_like_grouping = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local original = h.sql('SELECT * FROM t ORDER BY id').rows
        -- Updates of the skipped part and of the suffix move rows within
        -- the scanned index. Keys are collected before the update, so no
        -- row is updated twice.
        for _, case in ipairs({
            {
                sql = 'UPDATE t INDEXED BY bk SET k=k+10 WHERE k>=2',
                count = 4,
                check = 'SELECT id,k FROM t WHERE k>=12 ORDER BY id',
                rows = {{3, 13}, {5, 12}, {6, 14}, {8, 13}},
            },
            {
                sql = [[UPDATE t INDEXED BY bk SET bucket_id=bucket_id+10
                        WHERE k=1]],
                count = 2,
                check = [[SELECT id,bucket_id FROM t WHERE bucket_id>10
                          ORDER BY id]],
                rows = {{2, 11}, {7, 13}},
            },
            {
                sql = 'UPDATE t INDEXED BY bk SET k=k-1 WHERE k>=1',
                count = 6,
                check = 'SELECT id,k FROM t WHERE k IS NOT NULL ORDER BY id',
                rows = {{2, 0}, {3, 2}, {5, 1}, {6, 3}, {7, 0}, {8, 2}},
            },
        }) do
            box.begin()
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID)')
            t.assert_equals(h.sql(case.sql).row_count, case.count, case.sql)
            h.rows(case.check, case.rows)
            box.rollback()
            h.rows('SELECT * FROM t ORDER BY id', original)
        end

        -- OR on the suffix becomes IN; OR across parts combines searches.
        h.skip([[SELECT id FROM t INDEXED BY bk WHERE k=1 OR k=3
                 ORDER BY id]], {{2}, {3}, {7}, {8}})
        h.rows([[SELECT id FROM t INDEXED BY bk WHERE k=1 OR bucket_id=2
                 ORDER BY id]], {{2}, {4}, {5}, {6}, {7}})

        -- A LIKE prefix on a string suffix becomes a range.
        h.sql('CREATE INDEX bp ON t(bucket_id,payload)')
        h.sql([[INSERT INTO t VALUES (9,1,5,'nurse'),(10,3,6,'nut')]])
        local sql = [[SELECT id FROM t INDEXED BY bp WHERE payload LIKE 'nu%'
                      ORDER BY id]]
        t.assert_str_contains(h.plan(sql),
                              'ANY(BUCKET_ID) AND PAYLOAD>? AND PAYLOAD<?')
        h.rows(sql, {{1}, {9}, {10}})
        sql = [[SELECT id FROM t INDEXED BY bp WHERE payload LIKE '%u%'
                ORDER BY id]]
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{1}, {9}, {10}})

        -- The skipped part comes first in index order: DISTINCT and
        -- GROUP BY on it need no sorter, GROUP BY on the suffix does.
        for _, case in ipairs({
            {
                sql = [[SELECT DISTINCT bucket_id FROM t INDEXED BY bk
                        WHERE k>=1]],
                rows = {{1}, {2}, {3}},
            },
            {
                sql = [[SELECT bucket_id,count(*) FROM t INDEXED BY bk
                        WHERE k>=1 GROUP BY bucket_id]],
                rows = {{1, 3}, {2, 2}, {3, 3}},
            },
            {
                sql = [[SELECT k,count(*) FROM t INDEXED BY bk
                        WHERE k>=1 GROUP BY k]],
                rows = {{1, 2}, {2, 1}, {3, 2}, {4, 1}, {5, 1}, {6, 1}},
                sorter = 'USE TEMP B-TREE FOR GROUP BY',
            },
        }) do
            local plan = h.plan(case.sql)
            t.assert_str_contains(plan, 'ANY(BUCKET_ID)')
            if case.sorter ~= nil then
                t.assert_str_contains(plan, case.sorter)
            else
                t.assert_not_str_contains(plan, 'TEMP B-TREE')
            end
            h.rows(case.sql, case.rows)
        end
    end)
end

g.test_prepared_params_and_query_shapes = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT id FROM t INDEXED BY bk
                      WHERE k>=CAST(? AS INTEGER) ORDER BY id]]
        t.assert_str_contains(h.plan(sql, {3}), 'ANY(BUCKET_ID)')
        local stmt = assert(box.prepare(sql))
        for _, case in ipairs({
            {params = {3}, rows = {{3}, {6}, {8}}},
            {params = {1}, rows = {{2}, {3}, {5}, {6}, {7}, {8}}},
            {params = {5}, rows = {}},
            {params = {box.NULL}, rows = {}},
            {params = {2}, rows = {{3}, {5}, {6}, {8}}},
        }) do
            t.assert_equals(stmt:execute(case.params).rows, case.rows)
        end
        stmt:unprepare()

        -- A skip-scan inside IN (SELECT ...), a compound query, OFFSET,
        -- a view and two skip-scan levels of a three-table join.
        h.skip([[SELECT id FROM t
                 WHERE id IN (SELECT id FROM t INDEXED BY bk WHERE k=3)
                 ORDER BY id]], {{3}, {8}})
        h.skip([[SELECT id FROM t INDEXED BY bk WHERE k=1
                 UNION SELECT id FROM t INDEXED BY bk WHERE k=3
                 ORDER BY id]], {{2}, {3}, {7}, {8}})
        h.skip([[SELECT id FROM t INDEXED BY bk WHERE k>=1
                 ORDER BY bucket_id,k LIMIT 2 OFFSET 2]], {{5}, {6}})
        h.sql([[CREATE VIEW vw AS SELECT id,k FROM t INDEXED BY bk
                WHERE k>=2]])
        h.skip('SELECT id FROM vw ORDER BY id', {{3}, {5}, {6}, {8}})
        h.sql('DROP VIEW vw')

        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY, x INTEGER)')
        h.sql('INSERT INTO u VALUES (1,1),(2,3),(3,5)')
        sql = [[SELECT u.id,a.id,b.id FROM u
                CROSS JOIN t a INDEXED BY bk CROSS JOIN t b INDEXED BY bk
                WHERE a.k=u.x AND b.k=a.k+2 ORDER BY u.id,a.id,b.id]]
        local _, count = h.plan(sql):gsub('ANY%(BUCKET_ID%)', '')
        t.assert_equals(count, 2)
        h.rows(sql, {{1, 2, 3}, {1, 2, 8}, {1, 7, 3}, {1, 7, 8}})
    end)
end

g.test_sorter_rejects_ordered_inner_loop = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<200
                )
                INSERT INTO t
                SELECT id,(id-1)/4+1,(id-1)%4+1,'row' FROM seq]])
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY)')
        h.sql('INSERT INTO u VALUES (1),(2),(3)')
        -- The ORDER BY is not satisfied across the outer rows, but the
        -- skip-scan delivers each outer row's run in order. Once the full
        -- sorter rejects a row, the rest of the run is skipped: the scan
        -- ends instead of visiting every remaining prefix.
        for _, case in ipairs({
            {
                sql = [[SELECT t.bucket_id,t.k FROM u CROSS JOIN t INDEXED BY bk
                        WHERE t.k>=2 ORDER BY t.bucket_id,t.k LIMIT 1]],
                rows = {{1, 2}},
            },
            {
                sql = [[SELECT t.bucket_id,t.k FROM u CROSS JOIN t INDEXED BY bk
                        WHERE t.k<=3
                        ORDER BY t.bucket_id DESC,t.k DESC LIMIT 2]],
                rows = {{50, 3}, {50, 3}},
            },
        }) do
            local plan = h.plan(case.sql)
            t.assert_str_contains(plan, 'ANY(BUCKET_ID)')
            t.assert_str_contains(plan, 'USE TEMP B-TREE FOR ORDER BY')
            local before = box.stat.sql().sql_search_count
            h.rows(case.sql, case.rows)
            t.assert_lt(box.stat.sql().sql_search_count - before, 30,
                        case.sql)
        end
        -- A suffix IN loop runs inside the prefix loop, so the run of
        -- the inner loop is not ordered and the sorter keeps every row.
        h.rows([[SELECT t.bucket_id,t.k FROM u CROSS JOIN t INDEXED BY bk
                 WHERE t.k IN (3,2) ORDER BY t.bucket_id,t.k LIMIT 2]],
               {{1, 2}, {1, 2}})

        -- Rejecting tenant=1's ordered run must still enter tenant=2,
        -- whose first bucket improves the current LIMIT result.
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX i ON v(tenant,bucket,k)')
        h.sql([[INSERT INTO v SELECT t.id+(u.id-1)*200,u.id,
                       t.bucket_id+CASE u.id WHEN 2 THEN 0 ELSE 100*u.id END,t.k
                FROM u CROSS JOIN t]])
        local query = [[SELECT tenant,bucket,k FROM v INDEXED BY i
                         WHERE tenant IN (1,2,3) AND k>=2
                         ORDER BY bucket,k LIMIT 1]]
        t.assert_str_contains(h.plan(query), 'TENANT=? AND ANY(BUCKET) AND K>?')
        t.assert_str_contains(h.plan(query), 'USE TEMP B-TREE FOR ORDER BY')
        local before = box.stat.sql().sql_search_count
        h.rows(query, {{2, 1, 2}})
        t.assert_lt(box.stat.sql().sql_search_count - before, 30, query)
    end)
end

g.test_in_values_visit_all_buckets = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k IN (NULL,1,3,1) ORDER BY id]],
               {{2}, {3}, {7}, {8}})
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k IN (20,30) ORDER BY id]], {})
    end)
end

g.test_in_prefix_lookups = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        -- 100 prefixes with 32 consecutive suffix values each.
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<3200
                )
                INSERT INTO t
                SELECT id,(id-1)/32+1,(id-1)%32+1,'row' FROM seq]], {},
              {{sql_vdbe_max_steps = 10000000}})
        h.sql('CREATE INDEX bkd ON t(bucket_id,k DESC)')
        for _, name in ipairs({'BK', 'BKD'}) do
            for _, first in ipairs({1, 33}) do
                local values, expected = {}, {}
                for k = first, first + 99 do
                    table.insert(values, k)
                end
                if first == 1 then
                    for id = 1, 3200 do
                        table.insert(expected, {id})
                    end
                end
                for _, reverse in ipairs({false, true}) do
                    h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                          :format(tostring(reverse)))
                    -- Separate cache entries for the two compiled directions.
                    local sql = ('SELECT id FROM t INDEXED BY %s ' ..
                                 'WHERE k IN (%s) /* reverse=%s */')
                                :format(name, table.concat(values, ','),
                                        tostring(reverse))
                    t.assert_str_contains(h.plan(sql), 'ANY(BUCKET_ID)')
                    local index = box.space.T.index[name]
                    local stmt = assert(box.prepare(sql))
                    for _ = 1, 2 do
                        local before = index:stat().lookup
                        local result, err = stmt:execute({},
                            {{sql_vdbe_max_steps = 10000000}})
                        local after = index:stat().lookup
                        t.assert(result, tostring(err))
                        table.sort(result.rows,
                                   function(x, y) return x[1] < y[1] end)
                        t.assert_equals(result.rows, expected, sql)
                        if box.space.T.engine == 'vinyl' then
                            t.assert_lt(after - before, 416, sql)
                        end
                    end
                    stmt:unprepare()
                end
            end
        end
    end)
end

g.test_in_nested_suffixes = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket_id INTEGER,
                              a INTEGER,b INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX abc ON v(bucket_id,a,b,c)')
        h.sql('CREATE INDEX abcd ON v(bucket_id,a DESC,b,c DESC)')
        -- Every combination of three values in four index parts.
        h.sql([[WITH values3(x) AS (VALUES(0),(1),(2))
                INSERT INTO v
                SELECT 1+bucket.x*27+a.x*9+b.x*3+c.x,
                       bucket.x,a.x,b.x,c.x
                FROM values3 AS bucket CROSS JOIN values3 AS a
                CROSS JOIN values3 AS b CROSS JOIN values3 AS c]])
        local checks = require('test.sql-luatest.skip_scan_helpers')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, case in ipairs({
                {where = 'a IN (0,2,9) AND b IN (0,2,9) AND c>=2',
                 match = function(a, b, c)
                     return a ~= 1 and b ~= 1 and c == 2
                 end,
                 key = 'A=? AND B=? AND C>?'},
                {where = 'a IN (0,2,9) AND b=1 AND c IN (0,2,9)',
                 match = function(a, b, c)
                     return a ~= 1 and b == 1 and c ~= 1
                 end,
                 key = 'A=? AND B=? AND C=?'},
                {where = 'a IN (NULL,0,2,0) AND b IN (0,2,2,NULL) AND c<2',
                 match = function(a, b, c)
                     return a ~= 1 and b ~= 1 and c < 2
                 end,
                 key = 'A=? AND B=? AND C<?'},
                {where = 'a IN (SELECT a FROM v WHERE id<0) AND b IN (0,2)',
                 match = function() return false end,
                 key = 'A=? AND B=?'},
            }) do
                local expected = {}
                for bucket = 0, 2 do
                    for a = 0, 2 do
                        for b = 0, 2 do
                            for c = 0, 2 do
                                if case.match(a, b, c) then
                                    table.insert(expected,
                                                 {1+bucket*27+a*9+b*3+c})
                                end
                            end
                        end
                    end
                end
                t.assert_equals(checks.primary_rows(box.space.V, case.where),
                                expected)
                for _, index in ipairs({'abc', 'abcd'}) do
                    local query = ('SELECT id FROM v INDEXED BY %s WHERE %s ' ..
                                   '/* reverse=%s */')
                                  :format(index, case.where, tostring(reverse))
                    checks.assert_search(query,
                                         'ANY(BUCKET_ID) AND ' .. case.key)
                    checks.assert_direction(query, box.space.V,
                                            box.space.V.index[index:upper()],
                                            reverse)
                    t.assert_equals(checks.sorted(h.sql(query).rows), expected)
                end
            end
        end
    end)
end

-- The NULL row of a LEFT JOIN must not resume inner IN values left by a
-- previous outer row.
g.test_in_suffix_left_join_null_row = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY, bucket_id INTEGER,
                              b INTEGER, c INTEGER)]])
        h.sql('CREATE INDEX i ON v(bucket_id,b,c)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY, x INTEGER)')
        h.sql('INSERT INTO v VALUES (1,1,1,1),(2,1,1,2),(3,2,NULL,2)')
        h.sql('INSERT INTO u VALUES (1,1),(2,NULL),(3,1)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local sql = [[SELECT u.id,v.id FROM u LEFT JOIN v INDEXED BY i
                          ON v.b=u.x AND v.c IN (1,2,3)]] ..
                        (' /* reverse=%s */'):format(tostring(reverse))
            t.assert_str_contains(h.plan(sql), 'ANY(BUCKET_ID) AND B=? AND C=?')
            checks.assert_direction(sql, box.space.V, box.space.V.index.I,
                                    reverse)
            t.assert_equals(checks.sorted(h.sql(sql).rows),
                            {{1, 1}, {1, 2}, {2, box.NULL}, {3, 1}, {3, 2}})
        end
    end)
end

g.test_equality_after_inner_in_is_saved = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        rawset(_G, 'skip_scan_eq_calls', 0)
        rawset(_G, 'skip_scan_eq_value', 7)
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,a INTEGER,b INTEGER)]])
        h.sql('CREATE INDEX i ON v(bucket,a,b)')
        h.sql('CREATE INDEX ordinary ON v(a,b)')
        h.sql('CREATE INDEX p ON v(tenant,bucket,a,b)')
        local expected = {}
        for bucket = 1, 50 do
            for a = 1, 2 do
                local id = (bucket - 1) * 2 + a
                h.sql(('INSERT INTO v VALUES(%d,1,%d,%d,7)')
                      :format(id, bucket, a))
                table.insert(expected, {id})
            end
        end
        for _, deterministic in ipairs({false, true}) do
            box.schema.func.create('SKIP_SCAN_EQ_VALUE', {
                body = [[function()
                    _G.skip_scan_eq_calls = _G.skip_scan_eq_calls + 1
                    return _G.skip_scan_eq_value
                end]],
                returns = 'integer', is_deterministic = deterministic,
                exports = {'SQL'},
            })
            for _, reverse in ipairs({false, true}) do
                h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                      :format(tostring(reverse)))
                for _, index in ipairs({'i', 'ordinary'}) do
                    local sql = ('SELECT id FROM v INDEXED BY %s ' ..
                                 'WHERE a IN (1,2) AND ' ..
                                 'b=SKIP_SCAN_EQ_VALUE() ' ..
                                 '/* reverse=%s deterministic=%s */')
                                :format(index, tostring(reverse),
                                        tostring(deterministic))
                    local plan = h.plan(sql)
                    t.assert_str_contains(plan, 'A=? AND B=?')
                    if index == 'i' then
                        t.assert_str_contains(plan, 'ANY(BUCKET)')
                    end
                    checks.assert_direction(sql, box.space.V,
                                            box.space.V.index[index:upper()],
                                            reverse)
                    local stmt = assert(box.prepare(sql))
                    for _, value in ipairs({7, 8, 7}) do
                        _G.skip_scan_eq_calls = 0
                        _G.skip_scan_eq_value = value
                        local rows = checks.sorted(assert(stmt:execute()).rows)
                        t.assert_equals(rows, value == 7 and expected or {})
                        -- Skip-scan evaluates it once per pass, an
                        -- ordinary search once per IN value.
                        t.assert_equals(_G.skip_scan_eq_calls,
                                        index == 'i' and 1 or 2, sql)
                    end
                    stmt:unprepare()
                end
            end
            box.schema.func.drop('SKIP_SCAN_EQ_VALUE')
        end
        box.schema.func.create('SKIP_SCAN_EQ_VALUE', {
            body = [[function()
                _G.skip_scan_eq_calls = _G.skip_scan_eq_calls + 1
                return _G.skip_scan_eq_value
            end]],
            returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        -- Each outer row must discard values saved for the preceding row,
        -- including a row with NULL followed by a row that has matches.
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,7),(2,NULL),(3,8),(4,7)')
        local joined = {{2, box.NULL}, {3, box.NULL}}
        for _, id in ipairs({1, 4}) do
            for _, row in ipairs(expected) do
                table.insert(joined, {id, row[1]})
            end
        end
        checks.sorted(joined)
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local sql = [[SELECT u.id,v.id FROM u LEFT JOIN v INDEXED BY i
                          ON v.a IN (1,2) AND
                             v.b=SKIP_SCAN_EQ_VALUE()+u.x-7]] ..
                        (' /* reverse=%s */'):format(tostring(reverse))
            t.assert_str_contains(h.plan(sql), 'ANY(BUCKET) AND A=? AND B=?')
            checks.assert_direction(sql, box.space.V, box.space.V.index.I,
                                    reverse)
            _G.skip_scan_eq_calls = 0
            t.assert_equals(checks.sorted(h.sql(sql).rows), joined)
            -- Once for each outer row.
            t.assert_equals(_G.skip_scan_eq_calls, 4)
        end
        -- A new external prefix-IN combination is also a new pass.
        h.sql('INSERT INTO v SELECT id+100,2,bucket,a,b FROM v')
        local both_tenants = {}
        for id = 1, 200 do table.insert(both_tenants, {id}) end
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local sql = [[SELECT id FROM v INDEXED BY p
                          WHERE tenant IN (1,2) AND a IN (1,2)
                          AND b=SKIP_SCAN_EQ_VALUE()]] ..
                        (' /* prefix reverse=%s */'):format(tostring(reverse))
            t.assert_str_contains(h.plan(sql),
                                  'TENANT=? AND ANY(BUCKET) AND A=? AND B=?')
            checks.assert_direction(sql, box.space.V, box.space.V.index.P,
                                    reverse)
            local stmt = assert(box.prepare(sql))
            for _, value in ipairs({7, 8, 7}) do
                _G.skip_scan_eq_calls = 0
                _G.skip_scan_eq_value = value
                local rows = checks.sorted(assert(stmt:execute()).rows)
                t.assert_equals(rows, value == 7 and both_tenants or {})
                -- Once for each tenant.
                t.assert_equals(_G.skip_scan_eq_calls, 2, sql)
            end
            stmt:unprepare()
        end
        -- Several saved equalities between inner IN loops.
        h.sql('DROP TABLE v')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,b INTEGER,c INTEGER,d INTEGER)]])
        h.sql('CREATE INDEX i ON v(bucket,a,b,c,d)')
        local nested = {}
        for bucket = 1, 10 do
            for a = 1, 2 do
                for c = 1, 2 do
                    local id = #nested + 1
                    h.sql(('INSERT INTO v VALUES(%d,%d,%d,7,%d,7)')
                          :format(id, bucket, a, c))
                    table.insert(nested, {id})
                end
            end
        end
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local sql = [[SELECT id FROM v INDEXED BY i
                          WHERE a IN (1,2) AND b=SKIP_SCAN_EQ_VALUE()
                          AND c IN (1,2) AND d=SKIP_SCAN_EQ_VALUE()]] ..
                        (' /* nested reverse=%s */'):format(tostring(reverse))
            t.assert_str_contains(h.plan(sql),
                                  'ANY(BUCKET) AND A=? AND B=? AND C=? AND D=?')
            checks.assert_direction(sql, box.space.V, box.space.V.index.I,
                                    reverse)
            _G.skip_scan_eq_calls = 0
            t.assert_equals(checks.sorted(h.sql(sql).rows), nested)
            t.assert_equals(_G.skip_scan_eq_calls, 2)
        end
        box.schema.func.drop('SKIP_SCAN_EQ_VALUE')
    end)
end

-- IN values that are rebuilt on every evaluation stay outside the
-- prefix loop: otherwise they would be rebuilt for each prefix.
g.test_in_suffix_rebuilt_values = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        -- 50 prefixes with suffix values 1..4 each.
        h.sql([[WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL
                                         SELECT x+1 FROM n WHERE x<199)
                INSERT INTO t SELECT x+1, x/4+1, x%4+1, 'row' FROM n]])
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY, x INTEGER, y INTEGER)')
        h.sql('INSERT INTO u VALUES (1,2,3),(2,4,NULL)')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY, uid INTEGER,
                              k INTEGER)]])
        h.sql('INSERT INTO v VALUES (1,1,2),(2,1,3),(3,2,4)')
        rawset(_G, 'skip_scan_in_calls', 0)
        box.schema.func.create('SKIP_SCAN_IN_CALL', {
            body = [[function()
                _G.skip_scan_in_calls = _G.skip_scan_in_calls + 1
                return 0
            end]],
            returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        for _, case in ipairs({
            {
                sql = [[SELECT u.id,count(*) FROM u
                        CROSS JOIN t INDEXED BY bk
                        WHERE t.k IN (SELECT k+SKIP_SCAN_IN_CALL() FROM v
                                      WHERE v.uid=u.id)
                        GROUP BY u.id ORDER BY u.id]],
                calls = 3,
            },
            {
                sql = [[SELECT u.id,count(*) FROM u
                        CROSS JOIN t INDEXED BY bk
                        WHERE t.k IN (u.x,u.y,SKIP_SCAN_IN_CALL())
                        GROUP BY u.id ORDER BY u.id]],
                calls = 2,
            },
        }) do
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID) AND K=?')
            _G.skip_scan_in_calls = 0
            h.rows(case.sql, {{1, 100}, {2, 50}})
            t.assert_equals(_G.skip_scan_in_calls, case.calls, case.sql)
        end
        box.schema.func.drop('SKIP_SCAN_IN_CALL')
    end)
end

g.test_in_suffix_empty_list = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<200
                )
                INSERT INTO t
                SELECT id,(id-1)/2+1,(id-1)%2+1,'row' FROM seq]])
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY, a INTEGER NOT NULL,
                              b INTEGER NOT NULL, c INTEGER NOT NULL)]])
        h.sql('CREATE INDEX abc ON v(a,b,c)')
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<200
                )
                INSERT INTO v SELECT id,(id-1)/100+1,(id-1)%100+1,id FROM seq]])
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY, x INTEGER)')
        h.sql('INSERT INTO u VALUES (1,1)')
        -- An empty suffix IN list ends the skip-scan at once instead of
        -- opening it for every prefix.
        for _, case in ipairs({
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k IN (SELECT x FROM u WHERE x<0)]],
                plan = 'ANY(BUCKET_ID) AND K=?',
            },
            {
                sql = [[SELECT count(*) FROM v INDEXED BY abc
                        WHERE a IN (1,2) AND c IN (SELECT x FROM u WHERE x<0)]],
                plan = 'A=? AND ANY(B) AND C=?',
            },
        }) do
            t.assert_str_contains(h.plan(case.sql), case.plan)
            local before = box.stat.sql().sql_search_count
            h.rows(case.sql, {{0}})
            t.assert_lt(box.stat.sql().sql_search_count - before, 20,
                        case.sql)
        end
    end)
end

g.test_null_bounds_and_empty_scan = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k IS NULL ORDER BY id',
               {{1}, {4}})
        local sql = [[SELECT id FROM t INDEXED BY bk
                      WHERE k>=CAST(? AS INTEGER) AND k<=CAST(? AS INTEGER)
                      ORDER BY id]]
        h.skip(sql, {}, {box.NULL, 4})
        h.skip(sql, {}, {1, box.NULL})
        h.skip(sql, {}, {4, 2})
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k=CAST(? AS INTEGER)',
               {}, {box.NULL})
        h.sql('DELETE FROM t')
        h.skip(sql, {}, {1, 4})
    end)
end

g.test_search_and_full_scan_selection = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT id FROM t INDEXED BY bk
                      WHERE bucket_id=1 AND k>=1 ORDER BY id]]
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        t.assert_str_contains(h.plan(sql), 'SEARCH TABLE T')
        h.rows(sql, {{2}, {3}})

        sql = [[SELECT id FROM t INDEXED BY bk WHERE payload='a']]
        t.assert_str_contains(h.plan(sql), 'SCAN TABLE T')
        t.assert_str_contains(h.plan(sql), 'INDEX BK')
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{2}})

        sql = 'SELECT id FROM t WHERE k=1 ORDER BY id'
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{2}, {7}})
        t.assert_not_str_contains(h.plan('SELECT * FROM t INDEXED BY bk'),
                                  'ANY(')
    end)
end

g.test_seq_scan_setting = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[SET SESSION "sql_seq_scan"=false]])
        h.skip([[SELECT id FROM t INDEXED BY bk WHERE k>=2 ORDER BY id]],
               {{3}, {5}, {6}, {8}})
        local query = 'SELECT id FROM t INDEXED BY bk WHERE k>=? ORDER BY id'
        t.assert_str_contains(h.plan(query, {2}), 'ANY(BUCKET_ID) AND K>?')
        local stmt = assert(box.prepare(query))
        for _, case in ipairs({
            {value = 2, rows = {{3}, {5}, {6}, {8}}},
            {value = 100, rows = {}},
            {value = box.NULL, rows = {}},
        }) do
            t.assert_equals(assert(stmt:execute({case.value})).rows, case.rows)
        end
        stmt:unprepare()
        for _, sql in ipairs({
            'SELECT id FROM t INDEXED BY bk',
            [[SELECT id FROM t INDEXED BY bk WHERE payload='a']],
        }) do
            local result, err = box.execute(sql)
            t.assert_equals(result, nil)
            t.assert_str_contains(err.message, 'Scanning is not allowed')
        end
        h.sql([[SET SESSION "sql_seq_scan"=true]])
        h.rows([[SELECT payload FROM t INDEXED BY bk WHERE payload='a']],
               {{'a'}})
    end)
end

g.test_join_dependencies = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT a.id,b.id
                      FROM t a INDEXED BY bk CROSS JOIN t b INDEXED BY bk
                      ON a.k=b.k WHERE a.id IN (2,5) ORDER BY a.id,b.id]]
        local plan = h.plan(sql)
        t.assert_str_contains(plan, 'SCAN TABLE T AS A')
        t.assert_str_contains(plan, 'SEARCH TABLE T AS B')
        t.assert_str_contains(plan, 'ANY(BUCKET_ID)')
        h.rows(sql, {{2, 2}, {2, 7}, {5, 5}})

        sql = [[SELECT a.id,b.id FROM t a LEFT JOIN t b INDEXED BY bk
                ON b.k=a.k+100 WHERE a.id=2]]
        h.skip(sql, {{2, box.NULL}})
    end)
end

g.test_indexed_by_scope_and_parentheses = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.skip([[SELECT id FROM (t INDEXED BY bk) AS s
                 WHERE k=1 ORDER BY id]], {{2}, {7}})
        local sql = [[SELECT a.id,b.id FROM t a INDEXED BY bk CROSS JOIN t b
                      WHERE a.k=1 AND b.k=2 ORDER BY a.id,b.id]]
        local _, skips = h.plan(sql):gsub('ANY%(', '')
        t.assert_equals(skips, 1)
        h.rows(sql, {{2, 5}, {7, 5}})

        sql = [[SELECT id FROM t INDEXED BY bk WHERE k=1
                UNION ALL SELECT id FROM t WHERE k=2 ORDER BY id]]
        _, skips = h.plan(sql):gsub('ANY%(', '')
        t.assert_equals(skips, 1)
        h.rows(sql, {{2}, {5}, {7}})
    end)
end

g.test_in_before_and_after_skip_block = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,
                              b INTEGER,c INTEGER)]])
        h.sql('CREATE UNIQUE INDEX abc ON v(a,b,c)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,k INTEGER)')
        h.sql([[INSERT INTO v VALUES (1,1,10,20),(2,1,11,20),
                (3,2,12,20),(4,2,13,30),(5,3,14,20),
                (6,NULL,10,20),(7,NULL,11,30)]])
        h.sql('INSERT INTO u VALUES(1,10),(2,20)')
        -- Keep A fixed by =, IN or IS NULL; skip only B.
        for _, case in ipairs({
            {
                sql = [[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                        WHERE v.a=1 AND v.c IN (20,30)
                        ORDER BY v.c,v.a,v.id,u.id]],
                rows = {{1, 1}, {1, 2}, {2, 1}, {2, 2}},
            },
            {
                sql = [[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                        WHERE v.a IN (1,2) AND v.c IN (20,30)
                        ORDER BY v.c,v.a,v.id,u.id]],
                rows = {{1, 1}, {1, 2}, {2, 1}, {2, 2},
                        {3, 1}, {3, 2}, {4, 1}, {4, 2}},
            },
            {
                sql = [[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                        WHERE v.a IS NULL AND v.c IN (20,30)
                        ORDER BY v.c,v.a,v.id,u.id]],
                rows = {{6, 1}, {6, 2}, {7, 1}, {7, 2}},
            },
        }) do
            t.assert_str_contains(h.plan(case.sql), 'A=? AND ANY(B) AND C=?')
            h.rows(case.sql, case.rows)
        end
    end)
end

g.test_fixed_parts_from_outer_table = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,b INTEGER,
                              c INTEGER,d INTEGER)]])
        h.sql('CREATE INDEX abcd ON v(a,b,c,d)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,k INTEGER)')
        h.sql([[INSERT INTO v VALUES(1,1,10,1,20),(2,1,10,2,20),
                                    (3,2,20,3,20),(4,2,20,4,30),
                                    (5,3,30,5,20)]])
        h.sql('INSERT INTO u VALUES(1,10),(2,20)')
        -- Once U is read, using U.K for B adds no dependency beyond
        -- the one already needed for A=U.ID. Both parts stay fixed.
        local sql = [[SELECT v.id,u.id FROM u CROSS JOIN v INDEXED BY abcd
                      WHERE v.a=u.id AND v.b=u.k AND v.d IN (20,30)
                      ORDER BY v.d,v.a,v.id,u.id]]
        t.assert_str_contains(h.plan(sql), 'A=? AND B=?')
        t.assert_not_str_contains(h.plan(sql), 'ANY(A)')
        t.assert_not_str_contains(h.plan(sql), 'ANY(B)')
        h.rows(sql, {{1, 1}, {2, 1}, {3, 2}, {4, 2}})

        -- With V first, values from U are not available yet. Enumerate
        -- the leading parts and search by the constant D values.
        sql = [[SELECT v.id,u.id FROM v INDEXED BY abcd CROSS JOIN u
                WHERE v.a=u.id AND v.b=u.k AND v.d IN (20,30)
                ORDER BY v.d,v.a,v.id,u.id]]
        t.assert_str_contains(h.plan(sql),
                              'ANY(A) AND ANY(B) AND ANY(C) AND D=?')
        h.rows(sql, {{1, 1}, {2, 1}, {3, 2}, {4, 2}})
    end)
end

g.test_correlated_subquery_with_null_before_in = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket_id INTEGER,
                              a INTEGER,b INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX abc ON v(bucket_id,a,b,c)')
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,b INTEGER)]])
        h.sql([[INSERT INTO v VALUES (1,1,1,1,1),(2,2,1,NULL,2),
                                     (3,3,1,2,1)]])
        h.sql('INSERT INTO u VALUES (1,1),(2,NULL),(3,2)')
        -- The first invocation stops at c=1. On the next invocation,
        -- b=NULL must not advance its old IN cursor to c=2, even if
        -- another IN loop has already started for the current row.
        h.skip([[SELECT u.id FROM u WHERE EXISTS (
                    SELECT 1 FROM v INDEXED BY abc
                    WHERE a=1 AND v.b=u.b AND c IN (1,2))
                 ORDER BY u.id]], {{1}, {3}})
        h.skip([[SELECT u.id FROM u WHERE NOT EXISTS (
                    SELECT 1 FROM v INDEXED BY abc
                    WHERE a=1 AND v.b=u.b AND c IN (1,2))
                 ORDER BY u.id]], {{2}})
        h.skip([[SELECT u.id,(SELECT v.id FROM v INDEXED BY abc
                    WHERE a=1 AND v.b=u.b AND c IN (1,2)
                    LIMIT 1) FROM u ORDER BY u.id]],
               {{1, 1}, {2, box.NULL}, {3, 3}})
        h.skip([[SELECT u.id FROM u WHERE EXISTS (
                    SELECT 1 FROM v INDEXED BY abc
                    WHERE a IN (1,2) AND v.b=u.b AND c IN (1,2))
                 ORDER BY u.id]], {{1}, {3}})
        h.skip([[SELECT u.id FROM u WHERE NOT EXISTS (
                    SELECT 1 FROM v INDEXED BY abc
                    WHERE a IN (1,2) AND v.b=u.b AND c IN (1,2))
                 ORDER BY u.id]], {{2}})
        h.skip([[SELECT u.id,(SELECT v.id FROM v INDEXED BY abc
                    WHERE a IN (1,2) AND v.b=u.b AND c IN (1,2)
                    LIMIT 1) FROM u ORDER BY u.id]],
               {{1, 1}, {2, box.NULL}, {3, 3}})
    end)
end

g.test_json_suffix_is_refused = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE j(id UNSIGNED PRIMARY KEY,
                              a UNSIGNED NOT NULL,b MAP)]])
        -- SQL CREATE INDEX cannot define a key part at a JSON path.
        box.space.J:create_index('IX', {unique = false, parts = {
            {field = 'A', type = 'unsigned'},
            {field = 'B', path = 'x', type = 'unsigned', is_nullable = true},
        }})
        local _, err = box.execute([[SELECT id FROM j INDEXED BY ix
                                     WHERE b IS NOT NULL]])
        t.assert_str_contains(err.message, 'with a JSON path or a function')
    end)
end

-- A skipped part must be a format field: skip-scan reads it as a column.
g.test_part_outside_format_uses_full_scan = function(cg)
    cg.server:exec(function(engine)
        local h = _G.skip_scan_test
        local s = box.schema.space.create('J', {engine = engine, format = {
            {name = 'ID', type = 'unsigned'},
            {name = 'B', type = 'integer'},
        }})
        s:create_index('PK')
        s:create_index('IX', {unique = false, parts = {
            {4, 'unsigned'}, {2, 'integer'},
        }})
        s:insert{1, 1, 0, 5}
        s:insert{2, 1, 0, 6}
        s:insert{3, 2, 0, 5}
        local sql = 'SELECT id FROM j INDEXED BY ix WHERE b = 1 ORDER BY id'
        t.assert_str_contains(h.plan(sql), 'SCAN TABLE J')
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{1}, {2}})
    end, {cg.params.engine})
end

-- The planner conservatively retains sorting for skip-scan with IN,
-- including vector IN loops that still run outside the prefix loop.
g.test_in_requires_sort = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                      WHERE k IN (1,3) ORDER BY bucket_id,k]]
        h.skip(sql, {{1, 1}, {1, 3}, {3, 1}, {3, 3}})
        t.assert_str_contains(h.plan(sql), 'USE TEMP B-TREE FOR ORDER BY')
    end)
end

g.test_in_reverse_order_and_limit = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                      WHERE k IN (1,3) ORDER BY bucket_id DESC,k DESC]]
        h.skip(sql, {{3, 3}, {3, 1}, {1, 3}, {1, 1}})
        h.skip([[SELECT bucket_id,k FROM t INDEXED BY bk
                 WHERE k IN (1,3) ORDER BY bucket_id DESC,k DESC LIMIT 3]],
               {{3, 3}, {3, 1}, {1, 3}})
        t.assert_str_contains(h.plan(sql), 'USE TEMP B-TREE FOR ORDER BY')
    end)
end

g.test_nullable_unique_keys_need_sort = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,a INTEGER,
                              b INTEGER,payload STRING)]])
        h.sql('CREATE UNIQUE INDEX ab ON u(a,b)')
        -- Equal keys containing NULL do not make payload order irrelevant.
        h.sql([[INSERT INTO u VALUES (1,NULL,10,'z'),(2,NULL,10,'a'),
                                    (3,2,10,'b')]])
        local sql = [[SELECT a,payload FROM u INDEXED BY ab
                      WHERE b=10 ORDER BY a,payload]]
        local plan = h.plan(sql)
        t.assert_str_contains(plan, 'ANY(A)')
        h.rows(sql, {{box.NULL, 'a'}, {box.NULL, 'z'}, {2, 'b'}})
        t.assert_str_contains(plan, 'USE TEMP B-TREE')
    end)
end

g.test_min_max_nullable_prefix = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        for _, create_index in ipairs({
            'CREATE UNIQUE INDEX ab ON u(a,b)',
            'CREATE INDEX ab ON u(a,b)',
        }) do
            h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,a INTEGER,
                                  b INTEGER)]])
            h.sql(create_index)
            h.sql([[INSERT INTO u VALUES
                    (1,NULL,10),(2,2,10),(3,NULL,20)]])
            for _, sql in ipairs({
                [[SELECT min(a) FROM u INDEXED BY ab
                  WHERE b=CAST(? AS INTEGER)]],
                [[SELECT max(a) FROM u INDEXED BY ab
                  WHERE b=CAST(? AS INTEGER)]],
            }) do
                for _, case in ipairs({
                    {10, 2}, {20, box.NULL}, {30, box.NULL},
                }) do
                    t.assert_str_contains(h.plan(sql, {case[1]}), 'ANY(A)')
                    h.rows(sql, {{case[2]}}, {case[1]})
                end
            end
            h.sql('DROP TABLE u')
        end
    end)
end

g.test_min_max_with_range_bounds = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        -- bucket_id cannot be NULL, but the constrained suffix k can.
        -- MIN must not use the ordinary scan's NULL-seeking shortcut.
        h.skip([[SELECT min(bucket_id) FROM t INDEXED BY bk WHERE k>=1]],
               {{1}})
        h.skip([[SELECT max(bucket_id) FROM t INDEXED BY bk WHERE k>=1]],
               {{3}})
    end)
end

g.test_vector_bounds_with_null = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,
                              bucket_id INTEGER NOT NULL,
                              a INTEGER NOT NULL,b INTEGER NOT NULL)]])
        h.sql('CREATE INDEX bab ON u(bucket_id,a,b)')
        h.sql([[INSERT INTO u VALUES
                (1,1,1,1),(2,1,2,2),(3,1,3,3),
                (4,2,1,1),(5,2,2,2),(6,2,3,3),
                (7,3,1,1),(8,3,2,2),(9,3,3,3)]])
        -- Shorten the key at NULL for both seek directions. When this
        -- is the end bound, check its prefix and keep the full comparison.
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)>(2,NULL)
                 ORDER BY bucket_id,a,b]], {{3}, {6}, {9}})
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)>(2,NULL)
                 ORDER BY bucket_id DESC,a DESC,b DESC]], {{9}, {6}, {3}})
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)<=(2,NULL)
                 ORDER BY bucket_id,a,b]], {{1}, {4}, {7}})
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)<=(2,NULL)
                 ORDER BY bucket_id DESC,a DESC,b DESC]], {{7}, {4}, {1}})
        -- A non-NULL bound must still use every key part.
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)>=(2,2)
                 ORDER BY bucket_id,a,b]], {{2}, {3}, {5}, {6}, {8}, {9}})
        h.skip([[SELECT id FROM u INDEXED BY bab WHERE (a,b)<=(2,2)
                 ORDER BY bucket_id DESC,a DESC,b DESC]],
               {{8}, {7}, {5}, {4}, {2}, {1}})
        -- Exhausting a shortened seek must also finish suffix IN loops.
        h.sql('CREATE INDEX biab ON u(bucket_id,id,a,b)')
        h.skip([[SELECT id FROM u INDEXED BY biab
                 WHERE id IN (1,2,3,4,5,6,7,8,9,100) AND (a,b)>(2,NULL)
                 ORDER BY bucket_id,id,a,b]], {{3}, {6}, {9}})
        h.skip([[SELECT id FROM u INDEXED BY biab
                 WHERE id IN (0,1,2,3,4,5,6,7,8,9) AND (a,b)<=(2,NULL)
                 ORDER BY bucket_id DESC,id DESC,a DESC,b DESC]],
               {{7}, {4}, {1}})
    end)
end

g.test_probe_lookups = function(cg)
    t.skip_if(cg.params.engine ~= 'vinyl', 'lookup counts are vinyl-only')
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<320
                )
                INSERT INTO t
                SELECT id,(id-1)/32+1,(id-1)%32+1,'row' FROM seq]])
        local index = box.space.T.index.BK
        -- The first range-start seek only compares the current row;
        -- later prefixes can avoid that seek by probing.
        for _, case in ipairs({
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k>=1]],
                lookups = 1,
                count = 320,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k>=3]],
                lookups = 2,
                count = 300,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k<=28]],
                lookups = 1,
                count = 280,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k>1]],
                lookups = 2,
                count = 310,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k>=2 AND k<=31]],
                lookups = 2,
                count = 300,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k>=20]],
                lookups = 11,
                count = 130,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k<=3]],
                lookups = 11,
                count = 30,
            },
            {
                sql = [[SELECT count(*) FROM t INDEXED BY bk
                        WHERE k=17]],
                lookups = 21,
                count = 10,
            },
        }) do
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID)')
            -- Executing the same prepared statement must start fresh.
            local stmt = assert(box.prepare(case.sql))
            for _ = 1, 2 do
                local before = index:stat().lookup
                local result = stmt:execute()
                t.assert_equals(result.rows, {{case.count}}, case.sql)
                t.assert_equals(index:stat().lookup - before, case.lookups,
                                case.sql)
            end
            stmt:unprepare()
        end
    end)
end

g.test_probe_short_limit = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        h.sql([[WITH RECURSIVE seq(id) AS (
                    VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<64
                )
                INSERT INTO t
                SELECT id,(id-1)/32+1,(id-1)%32+1,'row' FROM seq]])
        for _, case in ipairs({
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 1]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 1]],
                limit = 1,
            },
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 5]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 5]],
                limit = 5,
            },
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 16]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k>=17
                        ORDER BY bucket_id,k LIMIT 16]],
                limit = 16,
            },
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 1]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 1]],
                limit = 1,
            },
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 5]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 5]],
                limit = 5,
            },
            {
                sql = [[SELECT bucket_id,k FROM t INDEXED BY bk
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 16]],
                reference = [[SELECT bucket_id,k FROM t NOT INDEXED
                        WHERE k<=16
                        ORDER BY bucket_id DESC,k DESC LIMIT 16]],
                limit = 16,
            },
        }) do
            local expected = h.sql(case.reference).rows
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID)')
            local stmt = assert(box.prepare(case.sql))
            for _ = 1, 2 do
                local before = box.stat.sql().sql_search_count
                local result = stmt:execute()
                local count = box.stat.sql().sql_search_count - before
                t.assert_equals(result.rows, expected, case.sql)
                -- One Seek and limit-1 Next/Prev, with no probe steps.
                t.assert_equals(count, case.limit, case.sql)
            end
            stmt:unprepare()
        end
    end)
end

g.test_probe_bounds_and_direction = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,
                              bucket_id INTEGER NOT NULL,k INTEGER,
                              s STRING COLLATE "unicode_ci")]])
        h.sql('CREATE INDEX bk ON u(bucket_id,k)')
        h.sql('CREATE INDEX bkd ON u(bucket_id,k DESC)')
        h.sql('CREATE INDEX bs ON u(bucket_id,s)')
        -- Prefix b has two copies of keys 1..3*b and one NULL row.
        -- Alternate letter case to exercise the case-insensitive index.
        h.sql([[WITH RECURSIVE
                buckets(b) AS (
                    VALUES(1) UNION ALL SELECT b+1 FROM buckets WHERE b<12
                ),
                keys(k) AS (
                    VALUES(1) UNION ALL SELECT k+1 FROM keys WHERE k<36
                ),
                copies(n) AS (VALUES(1),(2)),
                data_rows(id,b,k) AS (
                    SELECT 3*b*(b-1)+b-1+2*(k-1)+n,b,k
                    FROM buckets CROSS JOIN keys CROSS JOIN copies
                    WHERE k<=3*b
                )
                INSERT INTO u
                SELECT id,b,k,CASE WHEN id%2=0 THEN upper(char(97+k%26))
                                                  ELSE char(97+k%26) END
                FROM data_rows
                UNION ALL
                SELECT 3*b*(b+1)+b,b,NULL,NULL FROM buckets]])
        local integers = {{0}, {1}, {2}, {9}, {17}, {36}, {37}}
        local ranges = {{9, 30}, {30, 9}}
        local strings = {{'a'}, {'B'}, {'k'}, {'Z'}}
        for _, case in ipairs({
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = integers,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k>=CAST(? AS INTEGER) AND k<CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = ranges,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id,k,id LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IS NULL
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id,k,id LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bkd
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE k IN (NULL,1,9,17,100)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s>=CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 1]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id,k,id LIMIT 19]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 1]],
                params = strings,
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bs
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                reference = [[SELECT id FROM u NOT INDEXED
                        WHERE s<CAST(? AS STRING)
                        ORDER BY bucket_id DESC,k DESC,id DESC LIMIT 19]],
                params = strings,
            },
        }) do
            for _, params in ipairs(case.params or {{}}) do
                h.skip(case.sql, h.sql(case.reference, params).rows, params)
            end
        end
        local _, err = box.execute([[SELECT id FROM u INDEXED BY bk
                                     WHERE k>CAST(? AS INTEGER)]],
                                   {'wrong type'})
        t.assert(err)
    end)
end

for _, probe_case in ipairs({
    {
        name = 'test_probe_alternating_range_0_false',
        phase = 0,
        bound = 17,
        reverse = false,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k>=17
                ORDER BY bucket_id,k]],
    },
    {
        name = 'test_probe_alternating_range_0_true',
        phase = 0,
        bound = 1,
        reverse = true,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k<=1
                ORDER BY bucket_id DESC,k DESC]],
    },
    {
        name = 'test_probe_alternating_range_1_false',
        phase = 1,
        bound = 17,
        reverse = false,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k>=17
                ORDER BY bucket_id,k]],
    },
    {
        name = 'test_probe_alternating_range_1_true',
        phase = 1,
        bound = 1,
        reverse = true,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k<=1
                ORDER BY bucket_id DESC,k DESC]],
    },
    {
        name = 'test_probe_alternating_prefix_0_false',
        phase = 0,
        bound = 1,
        reverse = false,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k<=1
                ORDER BY bucket_id,k]],
    },
    {
        name = 'test_probe_alternating_prefix_0_true',
        phase = 0,
        bound = 17,
        reverse = true,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k>=17
                ORDER BY bucket_id DESC,k DESC]],
    },
    {
        name = 'test_probe_alternating_prefix_1_false',
        phase = 1,
        bound = 1,
        reverse = false,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k<=1
                ORDER BY bucket_id,k]],
    },
    {
        name = 'test_probe_alternating_prefix_1_true',
        phase = 1,
        bound = 17,
        reverse = true,
        sql = [[SELECT bucket_id,k FROM t INDEXED BY bk WHERE k>=17
                ORDER BY bucket_id DESC,k DESC]],
    },
}) do
    g[probe_case.name] = function(cg)
        cg.server:exec(function(case)
            local h = _G.skip_scan_test
            h.sql('DELETE FROM t')
            -- phase=0 makes even prefixes dense; phase=1 makes odd ones
            -- dense. Other prefixes contain only the target key.
            -- Each earlier dense prefix contributes 16 extra rows.
            h.sql([[WITH RECURSIVE
                    buckets(b) AS (
                        VALUES(1) UNION ALL SELECT b+1 FROM buckets WHERE b<100
                    ),
                    keys(k) AS (
                        VALUES(1) UNION ALL SELECT k+1 FROM keys WHERE k<17
                    ),
                    settings(phase,bound) AS (
                        VALUES(CAST(? AS INTEGER),CAST(? AS INTEGER))
                    )
                    INSERT INTO t
                    SELECT b-1+16*((b-1+phase)/2)+
                           CASE WHEN b%2=phase THEN k ELSE 1 END,
                           b,k,'row'
                    FROM buckets CROSS JOIN keys CROSS JOIN settings
                    WHERE b%2=phase OR k=bound]], {case.phase, case.bound},
                  {{sql_vdbe_max_steps = 10000000}})
            local expected = {}
            for b = 1, 100 do
                expected[case.reverse and 101-b or b] = {b, case.bound}
            end
            t.assert_str_contains(h.plan(case.sql), 'ANY(BUCKET_ID)')
            local stmt = assert(box.prepare(case.sql))
            local index = box.space.T.index.BK
            for _ = 1, 2 do
                local before = box.stat.sql().sql_search_count
                local stat = index:stat()
                local result = stmt:execute()
                local count = box.stat.sql().sql_search_count - before
                t.assert_equals(result.rows, expected, case.sql)
                -- About three cursor operations per prefix leave room
                -- for occasional probes, but not eight at every miss.
                t.assert_le(count, 400, 'zero-step hits must keep the pause')
                if box.space.T.engine == 'vinyl' then
                    t.assert_le(index:stat().lookup - stat.lookup, 51,
                                'zero-step hits must still avoid seeks')
                end
            end
            stmt:unprepare()
        end, {probe_case})
    end
end

g.test_probe_resumes_after_backoff = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        -- First, 200 prefixes with keys 1..128 make probes fail long enough
        -- to reach maximum backoff. Then, 200 prefixes with keys 95..102
        -- make the target key 97 reachable in two steps.
        h.sql([[WITH RECURSIVE
                buckets(b) AS (
                    VALUES(1) UNION ALL SELECT b+1 FROM buckets WHERE b<400
                ),
                keys(k) AS (
                    VALUES(1) UNION ALL SELECT k+1 FROM keys WHERE k<128
                )
                INSERT INTO t
                SELECT CASE WHEN b<=200 THEN (b-1)*128+k
                                       ELSE 25600+(b-201)*8+k-94 END,
                       b,k,'row'
                FROM buckets CROSS JOIN keys
                WHERE b<=200 OR k BETWEEN 95 AND 102]], {},
              {{sql_vdbe_max_steps = 10000000}})
        local query = [[SELECT id FROM t INDEXED BY bk WHERE k>=97
                         ORDER BY bucket_id,k]]
        -- The full-scan reference must read all 27200 fixture rows.
        local expected = h.sql([[SELECT id FROM t NOT INDEXED WHERE k>=97
                                 ORDER BY bucket_id,k]], {},
                               {{sql_vdbe_max_steps = 10000000}}).rows
        local index = box.space.T.index.BK
        local before = index:stat()
        h.skip(query, expected)
        if box.space.T.engine == 'vinyl' then
            local lookups = index:stat().lookup - before.lookup
            t.assert_ge(lookups, 201)
            t.assert_le(lookups, 264, 'probing must resume after the pause')
        end
    end)
end

-- A skip after a fixed prefix reads no more rows than the prefix search
-- and filters by the next part in the index, so it is preferred.
g.test_internal_skip_selection = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY, a INTEGER NOT NULL,
                              b INTEGER NOT NULL, c INTEGER NOT NULL,
                              d INTEGER)]])
        h.sql('CREATE INDEX abc ON v(a,b,c)')
        h.sql([[INSERT INTO v VALUES (1,1,1,5,0),(2,1,2,6,0),(3,1,3,5,0),
                (4,2,1,5,0),(5,2,2,5,0)]])
        for _, case in ipairs({
            {
                sql = [[SELECT id FROM v INDEXED BY abc
                        WHERE a=1 AND c=5 ORDER BY id]],
                plan = 'A=? AND ANY(B) AND C=?',
                rows = {{1}, {3}},
            },
            {
                sql = [[SELECT d FROM v INDEXED BY abc
                        WHERE a=1 AND c=5 ORDER BY id]],
                plan = 'A=? AND ANY(B) AND C=?',
                rows = {{0}, {0}},
            },
            {
                sql = [[SELECT id FROM v INDEXED BY abc
                        WHERE a IN (1,2) AND c>5 ORDER BY id]],
                plan = 'A=? AND ANY(B) AND C>?',
                rows = {{2}},
            },
            {
                sql = 'SELECT id FROM v INDEXED BY abc WHERE a=2 ORDER BY id',
                plan = '(A=?)',
                rows = {{4}, {5}},
            },
            {
                sql = 'SELECT id FROM v WHERE a=1 AND c=5 ORDER BY id',
                plan = '(A=?)',
                rows = {{1}, {3}},
            },
        }) do
            t.assert_str_contains(h.plan(case.sql), case.plan)
            h.rows(case.sql, case.rows)
        end
    end)
end

g.test_probe_text_prefix = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,
                              bucket_id STRING COLLATE "unicode_ci",
                              k INTEGER)]])
        h.sql('CREATE INDEX bk ON u(bucket_id,k)')
        -- 13 prefixes, each with keys 1..32. The first prefix is NULL.
        -- Other prefixes contain 'prefix' 20 times followed by the number,
        -- with alternating letter case within each prefix.
        h.sql([[WITH RECURSIVE
                buckets(b) AS (
                    VALUES(0) UNION ALL SELECT b+1 FROM buckets WHERE b<12
                ),
                keys(k) AS (
                    VALUES(1) UNION ALL SELECT k+1 FROM keys WHERE k<32
                ),
                prefix_text(s) AS (
                    VALUES('prefixprefixprefixprefixprefix' ||
                           'prefixprefixprefixprefixprefix' ||
                           'prefixprefixprefixprefixprefix' ||
                           'prefixprefixprefixprefixprefix')
                )
                INSERT INTO u
                SELECT b*32+k,
                       CASE WHEN b=0 THEN NULL
                            WHEN k%2=0 THEN upper(s)||CAST(b AS STRING)
                            ELSE s||CAST(b AS STRING) END,
                       k
                FROM buckets CROSS JOIN keys CROSS JOIN prefix_text]])
        for _, case in ipairs({
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER) ORDER BY bucket_id,k,id]],
                reference = [[SELECT id FROM u NOT INDEXED
                              WHERE k>=CAST(? AS INTEGER)
                              ORDER BY bucket_id,k,id]],
            },
            {
                sql = [[SELECT id FROM u INDEXED BY bk
                        WHERE k>=CAST(? AS INTEGER)
                        ORDER BY bucket_id DESC,k DESC,id DESC]],
                reference = [[SELECT id FROM u NOT INDEXED
                              WHERE k>=CAST(? AS INTEGER)
                              ORDER BY bucket_id DESC,k DESC,id DESC]],
            },
        }) do
            for _, bound in ipairs({2, 9, 17, 33}) do
                h.skip(case.sql, h.sql(case.reference, {bound}).rows, {bound})
            end
        end
    end)
end

-- Check actual key values before and after the skipped block.
g.test_key_types_around_skip_block = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local function mismatch(sql, params, code)
            local stmt = assert(box.prepare(sql))
            local result, err = stmt:execute(params or {})
            stmt:unprepare()
            t.assert_equals(result, nil, sql)
            t.assert_equals(err.code, code or box.error.KEY_PART_TYPE, sql)
        end
        -- SQL converts numeric seek bounds before probing, just as it
        -- does for ordinary seeks. A Lua index key has different rules.
        h.sql('DELETE FROM t WHERE k IS NULL')
        for _, condition in ipairs({
            'k=1.0', 'k IN (1,1.5)', 'k>0.5', 'k>=0.5',
            'k<4.5', 'k<=4.5', 'k>1.5', 'k>=1.5', 'k<1.5', 'k<=1.5',
        }) do
            local sql = 'SELECT id FROM t %s WHERE ' .. condition ..
                        ' ORDER BY id'
            h.skip(sql:format('INDEXED BY bk'),
                   h.sql(sql:format('NOT INDEXED')).rows)
        end
        mismatch("SELECT id FROM t INDEXED BY bk WHERE k='1'", {},
                 box.error.SQL_TYPE_MISMATCH)
        local params = {require('decimal').new('0.5')}
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k>? ORDER BY id',
               h.sql('SELECT id FROM t NOT INDEXED WHERE k>? ORDER BY id',
                     params).rows, params)
        h.skip('SELECT id FROM t INDEXED BY bk WHERE k=? ORDER BY id',
               {{5}}, {2})
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k=CAST(? AS INTEGER) ORDER BY id]], {{5}}, {2})
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,
                              b INTEGER,c INTEGER)]])
        h.sql('CREATE UNIQUE INDEX abc ON v(a,b,c)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,k INTEGER)')
        h.sql([[INSERT INTO v VALUES (1,1,10,20),(2,1,11,20),
                (3,2,12,20),(4,2,13,30),(5,3,14,20)]])
        h.sql('INSERT INTO u VALUES(1,10),(2,20)')
        -- The join and sort make the planner choose the internal skip
        -- block, as in test_in_before_and_after_skip_block.
        mismatch([[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                    WHERE v.a IN (1,'x') AND v.c IN (20,30)
                    ORDER BY v.c,v.a,v.id,u.id]], {},
                 box.error.SQL_TYPE_MISMATCH)
        h.rows([[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                  WHERE v.a IN (1,2) AND v.c IN (20,1.5)
                  ORDER BY v.c,v.a,v.id,u.id]],
               {{1, 1}, {1, 2}, {2, 1}, {2, 2}, {3, 1}, {3, 2}})
        local sql = [[SELECT v.id,u.id FROM v INDEXED BY abc CROSS JOIN u
                      WHERE v.a IN (1,2) AND v.c IN (?,?)
                      ORDER BY v.c,v.a,v.id,u.id]]
        t.assert_str_contains(h.plan(sql, {20, 30}), 'A=? AND ANY(B) AND C=?')
        h.rows(sql, {{1, 1}, {1, 2}, {2, 1}, {2, 2},
                     {3, 1}, {3, 2}, {4, 1}, {4, 2}}, {20, 30})
    end)
end

-- Exact SQL examples from the skip-scan specification.
g.test_left_join_null_between_in = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,1),(2,NULL)')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,b INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX i ON v(bucket,a,b,c)')
        h.sql('CREATE INDEX ip ON v(id,bucket,a,b,c)')
        h.sql('INSERT INTO v VALUES(1,1,1,1,1),(2,1,1,NULL,3)')
        local query = [[SELECT u.id,v.id FROM u LEFT JOIN v INDEXED BY %s
                       ON v.a IN (1,2) AND v.b=u.x AND v.c IN (1,2,3)
                       %s /* reverse=%s */]]
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, prefix in ipairs({'', 'AND v.id IN (1,2)'}) do
                local index = prefix == '' and 'i' or 'ip'
                local sql = query:format(index, prefix, tostring(reverse))
                t.assert_str_contains(h.plan(sql), 'ANY(BUCKET)')
                checks.assert_direction(sql, box.space.V,
                                        box.space.V.index[index:upper()],
                                        reverse)
                t.assert_equals(checks.sorted(h.sql(sql).rows),
                                {{1, 1}, {2, box.NULL}})
            end
        end
        h.sql('INSERT INTO u VALUES(3,1)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, prefix in ipairs({'', 'AND v.id IN (1,2)'}) do
                local index = prefix == '' and 'i' or 'ip'
                local sql = query:format(index, prefix,
                                         'next ' .. tostring(reverse))
                checks.assert_direction(sql, box.space.V,
                                        box.space.V.index[index:upper()],
                                        reverse)
                t.assert_equals(checks.sorted(h.sql(sql).rows),
                                {{1, 1}, {2, box.NULL}, {3, 1}})
            end
        end
    end)
end

g.test_external_vector_in_after_eof = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER,y INTEGER)]])
        h.sql('INSERT INTO u VALUES(1,5,1),(2,9,2),(3,NULL,1),(4,5,1)')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              k INTEGER,m INTEGER)]])
        h.sql('CREATE INDEX i ON v(bucket,k,m)')
        h.sql('INSERT INTO v VALUES(1,1,5,1),(2,1,9,2),(3,2,5,1)')
        -- Exercise both vector components, even if a shorter key costs less.
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', true)
        local ok, err = pcall(function()
            for _, reverse in ipairs({false, true}) do
                h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                      :format(tostring(reverse)))
                local sql = ([[SELECT id FROM v INDEXED BY i
                               WHERE (k,m) IN (SELECT x,y FROM u)
                               /* reverse=%s */]]):format(tostring(reverse))
                checks.assert_search(sql, 'ANY(BUCKET) AND K=? AND M=?')
                checks.assert_direction(sql, box.space.V, box.space.V.index.I,
                                        reverse)
                local rows = h.sql(sql).rows
                table.sort(rows, function(a, b) return a[1] < b[1] end)
                t.assert_equals(rows, {{1}, {2}, {3}})
            end
        end)
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', false)
        if not ok then error(err) end
    end)
end

g.test_exists_repositions_after_early_return = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('DELETE FROM t')
        h.sql("INSERT INTO t VALUES(1,1,5,'a'),(2,2,9,'b')")
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,9),(2,5)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local sql = ([[SELECT id,EXISTS(SELECT 1 FROM t INDEXED BY bk
                           WHERE t.k=u.x) FROM u ORDER BY id
                           /* reverse=%s */]]):format(tostring(reverse))
            h.skip(sql, {{1, true}, {2, true}})
        end
    end)
end

g.test_exclude_null_disables_skip = function(cg)
    cg.server:exec(function(engine)
        local h = _G.skip_scan_test
        local s = box.schema.space.create('V', {engine = engine, format = {
            {name = 'ID', type = 'integer'},
            {name = 'BUCKET', type = 'integer', is_nullable = true},
            {name = 'K', type = 'integer'},
        }})
        s:create_index('pk', {parts = {'ID'}})
        s:create_index('I', {unique = false, parts = {
            {field = 'BUCKET', exclude_null = true}, {field = 'K'},
        }})
        s:insert{1, box.NULL, 5}
        s:insert{2, 1, 5}
        local sql = 'SELECT id FROM v INDEXED BY i WHERE k=5'
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        -- Even a full scan of this index omits its excluded NULL rows.
        h.rows(sql, {{2}})
    end, {cg.params.engine})
end

g.test_update_index_parts_once = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        for _, assignment in ipairs({'bucket_id=bucket_id+1', 'k=k+1'}) do
            box.begin()
            local sql = 'UPDATE t INDEXED BY bk SET ' .. assignment ..
                        ' WHERE k IN (1,2,3)'
            t.assert_str_contains(h.plan(sql), 'ANY(BUCKET_ID)')
            t.assert_equals(h.sql(sql).row_count, 5)
            if assignment == 'k=k+1' then
                h.rows('SELECT id,k FROM t WHERE k IS NOT NULL ORDER BY id',
                       {{2, 2}, {3, 4}, {5, 3}, {6, 4}, {7, 2}, {8, 4}})
            else
                h.rows('SELECT id,bucket_id FROM t ORDER BY id',
                       {{1, 1}, {2, 2}, {3, 2}, {4, 2},
                        {5, 3}, {6, 2}, {7, 4}, {8, 4}})
            end
            box.rollback()
        end
    end)
end

g.test_suffix_order_and_nullable_unique_exact = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX i ON v(tenant,bucket,k)')
        h.sql('INSERT INTO v VALUES(1,7,1,9),(2,7,2,6)')
        for _, prefix in ipairs({'tenant=7 AND ', ''}) do
            local query = 'SELECT k FROM v INDEXED BY i WHERE ' ..
                          prefix .. 'k>5 ORDER BY k'
            local key = prefix == '' and 'ANY(TENANT) AND ANY(BUCKET)' or
                                        'TENANT=? AND ANY(BUCKET)'
            t.assert_str_contains(h.plan(query), key .. ' AND K>?')
            t.assert_str_contains(h.plan(query), 'USE TEMP B-TREE')
            h.rows(query, {{6}, {9}})
        end
        h.sql('DELETE FROM t')
        h.sql("INSERT INTO t VALUES(1,1,9,'a'),(2,2,6,'b')")
        h.skip('SELECT k FROM t INDEXED BY bk WHERE k>=5 ORDER BY k',
               {{6}, {9}})
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,a INTEGER,b INTEGER,
                              payload INTEGER)]])
        h.sql('CREATE UNIQUE INDEX i ON u(a,b)')
        h.sql('INSERT INTO u VALUES(1,NULL,10,2),(2,NULL,10,1)')
        local sql = [[SELECT id FROM u INDEXED BY i WHERE b=10
                      ORDER BY a,payload]]
        t.assert_str_contains(h.plan(sql), 'USE TEMP B-TREE')
        h.rows(sql, {{2}, {1}})
    end)
end

g.test_costed_search_alternatives = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,b INTEGER,
                              c INTEGER,d INTEGER,e INTEGER)]])
        h.sql('CREATE INDEX i ON v(a,b,c,d,e)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER,y INTEGER)')
        h.sql('INSERT INTO u VALUES(1,5,1),(2,9,2),(3,5,1)')
        h.sql([[INSERT INTO v VALUES(1,1,1,5,5,1),(2,1,2,9,9,2),
                                    (3,2,3,5,5,1),(4,10000,4,5,5,1)]])
        local sql = [[SELECT id FROM v INDEXED BY i
                      WHERE a=1 AND (d,e) IN (SELECT x,y FROM u)
                      ORDER BY id]]
        -- The ordinary search is cheaper than repeated passes of b,c.
        t.assert_str_contains(h.plan(sql), '(A=?)')
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{1}, {2}})
        sql = [[SELECT id FROM v INDEXED BY i
                 WHERE (d,e) IN (SELECT x,y FROM u) ORDER BY id]]
        -- The very same external IN cannot select a full scan when the
        -- suffix search is the only available search on the named index.
        t.assert_str_contains(h.plan(sql), 'ANY(A)')
        h.rows(sql, {{1}, {2}, {3}, {4}})
        sql = [[SELECT id FROM v INDEXED BY i WHERE a=1 AND c IN (5,9)
                 AND (d,e) IN (SELECT x,y FROM u) ORDER BY id]]
        h.rows(sql, {{1}, {2}})
        -- The mixed candidate is checked with controlled costs in the
        -- unit test. Here the planner can also leave (d,e) as a filter;
        -- only INs used by a search key affect that key's loop layout.
        t.assert_str_contains(h.plan(sql), 'SEARCH TABLE V')
        sql = [[SELECT id FROM v INDEXED BY i WHERE a>9990 AND c=5
                 ORDER BY id]]
        t.assert_str_contains(h.plan(sql), '(A>?)')
        t.assert_not_str_contains(h.plan(sql), 'ANY(')
        h.rows(sql, {{4}})
        h.sql('CREATE TABLE j(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO j VALUES(1,9990)')
        sql = [[SELECT v.id FROM v INDEXED BY i CROSS JOIN j
                 WHERE v.a>j.x AND v.c=5 ORDER BY v.id]]
        -- The range depends on the later table: enumerate a, then apply
        -- the range as a filter, without treating it as a group boundary.
        t.assert_str_contains(h.plan(sql), 'ANY(A) AND ANY(B) AND C=?')
        h.rows(sql, {{4}})
    end)
end

g.test_mixed_external_in_execution = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,b INTEGER,
                              c INTEGER,d INTEGER,e INTEGER)]])
        for _, index in ipairs({'mix_base', 'mix_pairs', 'mix_long'}) do
            h.sql(('CREATE INDEX %s ON v(a,b,c,d,e)'):format(index))
        end
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER,y INTEGER)')
        h.sql([[INSERT INTO u VALUES(1,5,1),(2,9,2),(3,5,1),(4,NULL,1),
                                    (5,9,NULL),(6,99,99)]])
        h.sql([[INSERT INTO v VALUES(1,1,1,5,5,1),(2,1,1,9,9,2),
                                    (3,1,2,5,5,1),(4,2,1,5,5,1)]])
        -- Keep actual candidate construction and costs, but exclude shorter
        -- searches so their lower cost cannot hide execution of the full key.
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', true)
        local ok, err = pcall(function()
            for _, reverse in ipairs({false, true}) do
                h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                      :format(tostring(reverse)))
                for _, case in ipairs({
                    {index = 'mix_base', where = 'c IN (5,9) AND d=5 AND e=1',
                     rows = {{1}, {3}}, external = false},
                    {index = 'mix_pairs', where = [[c IN (5,9) AND
                                      (d,e) IN (SELECT x,y FROM u)]],
                     rows = {{1}, {2}, {3}}, external = true},
                    {index = 'mix_long', where = [[c IN (5,9,5,NULL) AND
                                     (d,e) IN (SELECT x,y FROM u)]],
                     rows = {{1}, {2}, {3}}, external = true},
                }) do
                    local sql = ('SELECT id FROM v INDEXED BY %s ' ..
                                 'WHERE a=1 AND %s /* mixed reverse=%s */')
                                :format(case.index, case.where,
                                        tostring(reverse))
                    t.assert_str_contains(h.plan(sql),
                        'A=? AND ANY(B) AND C=? AND D=? AND E=?')
                    local program, cursor = checks.assert_direction(
                        sql, box.space.V, box.space.V.index[case.index:upper()],
                        reverse)
                    local pass_start, in_loops = nil, {}
                    for _, row in ipairs(program) do
                        -- The first seek of the cursor finds the next group.
                        if row[3] == cursor and row[2]:match('^Seek') and
                           pass_start == nil then
                            pass_start = row[1]
                        elseif row[2] == 'NextIfOpen' or
                               row[2] == 'PrevIfOpen' then
                            table.insert(in_loops, row[4])
                        end
                    end
                    t.assert_not_equals(pass_start, nil, sql)
                    t.assert_equals(#in_loops, case.external and 2 or 1, sql)
                    for _, target in ipairs(in_loops) do
                        -- External IN resumes before the group loop;
                        -- internal IN resumes after the group-advance seek.
                        t.assert_equals(target < pass_start, case.external, sql)
                    end
                    local stmt = assert(box.prepare(sql))
                    for _ = 1, 2 do
                        local rows = assert(stmt:execute()).rows
                        t.assert_equals(checks.sorted(rows), case.rows, sql)
                    end
                    stmt:unprepare()
                end
            end
        end)
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', false)
        if not ok then error(err) end
    end)
    local costs = {}
    for _, index in ipairs({'MIX_BASE', 'MIX_PAIRS', 'MIX_LONG'}) do
        local pattern = 'skip%-scan cost: index=' .. index ..
                        ' run=(%-?%d+) base=(%-?%d+) multiplier=(%-?%d+) ' ..
                        'inner=(%-?%d+)'
        -- grep_log returns the first capture, so retain the whole record.
        local line = cg.server:grep_log('(' .. pattern .. ')')
        t.assert(line, 'missing constructed candidate cost: ' .. index)
        local run, base, multiplier, inner = line:match(pattern)
        costs[index] = {run = tonumber(run), base = tonumber(base),
                        multiplier = tonumber(multiplier),
                        inner = tonumber(inner)}
        t.assert_equals(tonumber(run), tonumber(base) + tonumber(multiplier))
    end
    t.assert_equals(costs.MIX_BASE.inner, 2)
    t.assert_equals(costs.MIX_PAIRS.inner, -1)
    t.assert_equals(costs.MIX_LONG.inner, -1)
    t.assert_equals(costs.MIX_BASE.base, costs.MIX_PAIRS.base)
    t.assert_equals(costs.MIX_BASE.base, costs.MIX_LONG.base)
    -- The vector subquery contributes logEst(25)=46 exactly once, and
    -- doubling the scalar list contributes logEst(4)-logEst(2)=10.
    t.assert_equals(costs.MIX_PAIRS.multiplier - costs.MIX_BASE.multiplier, 46)
    t.assert_equals(costs.MIX_LONG.multiplier - costs.MIX_PAIRS.multiplier, 10)
    t.assert_equals(costs.MIX_PAIRS.run - costs.MIX_BASE.run, 46)
    t.assert_equals(costs.MIX_LONG.run - costs.MIX_PAIRS.run, 10)
end

g.test_join_orders_and_scan_fallback = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,k INTEGER)')
        h.sql('INSERT INTO u VALUES(1,1),(2,3)')
        for _, from in ipairs({
            'u JOIN t INDEXED BY bk', 't INDEXED BY bk JOIN u',
            'u CROSS JOIN t INDEXED BY bk', 't INDEXED BY bk CROSS JOIN u',
        }) do
            local sql = 'SELECT u.id,t.id FROM ' .. from ..
                        ' ON t.k=u.k WHERE u.id>=1 ORDER BY u.id,t.id'
            h.rows(sql, {{1, 2}, {1, 7}, {2, 3}, {2, 8}})
            local plan = h.plan(sql)
            local fixed_scan = from == 't INDEXED BY bk CROSS JOIN u'
            if fixed_scan then
                t.assert_str_contains(plan, 'SCAN TABLE T')
            else
                t.assert_str_contains(plan, 'ANY(BUCKET_ID)')
            end
            h.sql('SET SESSION "sql_seq_scan"=false')
            -- u has its own primary-key bound. Only the forced fallback
            -- scan of t can cause this error.
            local query = sql .. ' /* scan disabled */'
            if fixed_scan then
                local rows, err = box.execute(query)
                t.assert_equals(rows, nil)
                t.assert_str_contains(err.message, 'Scanning is not allowed')
                t.assert_str_contains(err.message, "'T'")
            else
                h.rows(query, {{1, 2}, {1, 7}, {2, 3}, {2, 8}})
            end
            h.sql('SET SESSION "sql_seq_scan"=true')
        end
    end)
end

g.test_excluded_index_kinds = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('V', {engine = engine, format = {
            {name = 'ID', type = 'integer'},
            {name = 'K', type = 'integer'},
            {name = 'DATA', type = 'array'},
        }})
        s:create_index('pk', {parts = {'ID'}})
        s:create_index('M', {unique = false, parts = {
            {field = 'DATA', path = '[*]', type = 'unsigned'},
            {field = 'K'},
        }})
        local sql = 'SELECT id FROM v INDEXED BY %s WHERE k=5'
        local refused = 'with a JSON path or a function'
        local _, err = box.execute(sql:format('m'))
        t.assert_str_contains(err.message, refused)
        if engine == 'memtx' then
            s:create_index('H', {type = 'hash', parts = {'ID', 'K'}})
            local result, err = box.execute('EXPLAIN QUERY PLAN ' ..
                                           sql:format('h'))
            t.assert_equals(result, nil)
            t.assert_str_contains(err.message, 'non-TREE index')
            box.schema.func.create('SKIP_SCAN_KEY', {
                body = 'function(tuple) return {tuple[1], tuple[2]} end',
                is_deterministic = true, is_sandboxed = true,
            })
            s:create_index('F', {func = 'SKIP_SCAN_KEY', parts = {
                {1, 'integer'}, {2, 'integer'},
            }})
            _, err = box.execute(sql:format('f'))
            t.assert_str_contains(err.message, refused)
            s.index.F:drop()
            box.schema.func.drop('SKIP_SCAN_KEY')
        end
    end, {cg.params.engine})
end

g.test_in_incompatible_equality_is_filter = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              s STRING,k INTEGER)]])
        h.sql('CREATE INDEX coll_scan ON v(bucket,s)')
        h.sql('CREATE INDEX coll_search ON v(bucket,s,k)')
        h.sql('CREATE INDEX ordinary ON v(s)')
        h.sql('CREATE TABLE j(id INTEGER PRIMARY KEY,x STRING)')
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,
                              x STRING COLLATE "unicode_ci")]])
        for _, letters in ipairs({{'B', 'b'}, {'B', 'a'}}) do
            box.space.V:truncate()
            box.space.J:truncate()
            box.space.U:truncate()
            for id = 1, 4 do
                box.space.V:insert{id, math.ceil(id / 2),
                                   letters[(id - 1) % 2 + 1], 7}
            end
            h.sql("INSERT INTO j VALUES(1,'B'),(2,'B'),(3,NULL)")
            h.sql("INSERT INTO u VALUES(1,'B'),(2,NULL)")
            if letters[2] == 'a' then
                h.sql("INSERT INTO j VALUES(4,'a')")
                h.sql("INSERT INTO u VALUES(3,'a')")
            end
            for _, case in ipairs({
                {rhs = 'SELECT x COLLATE "unicode_ci" FROM j'},
                {rhs = 'SELECT x FROM u'},
                {rhs = 'SELECT x FROM u', ready = true},
            }) do
                if case.ready then h.sql('CREATE UNIQUE INDEX ux ON u(x)') end
                for _, reverse in ipairs({false, true}) do
                    h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                          :format(tostring(reverse)))
                    local predicate = 's IN (' .. case.rhs .. ')'
                    local suffix = (' /* reverse=%s */')
                                   :format(tostring(reverse))
                    t.assert_equals(checks.primary_rows(box.space.V, predicate),
                                    {{1}, {2}, {3}, {4}})
                    for _, index in ipairs({'coll_scan', 'coll_search',
                                            'ordinary'}) do
                        local where = predicate ..
                            (index == 'coll_search' and ' AND k=7' or '')
                        local query =
                            ('SELECT id FROM v INDEXED BY %s WHERE %s%s')
                            :format(index, where, suffix)
                        local plan = h.plan(query)
                        t.assert_not_str_contains(plan, 'S=?')
                        if index == 'coll_search' then
                            checks.assert_search(query,
                                'ANY(BUCKET) AND ANY(S) AND K=?')
                        else
                            t.assert_str_contains(plan, 'SCAN TABLE')
                            t.assert_not_str_contains(plan, 'ANY(')
                        end
                        if case.ready then
                            t.assert_str_contains(
                                plan, 'USING INDEX UX FOR IN-OPERATOR')
                        end
                        local program = checks.assert_direction(query,
                            box.space.V, box.space.V.index[index:upper()],
                            reverse)
                        for _, row in ipairs(program) do
                            t.assert_not_equals(row[2], 'NextIfOpen')
                            t.assert_not_equals(row[2], 'PrevIfOpen')
                        end
                        t.assert_equals(checks.sorted(h.sql(query).rows),
                                        {{1}, {2}, {3}, {4}})
                        -- The scan prohibition also applies to the IN source.
                        -- Give it an ordinary primary-key search here.
                        local guarded = query
                            :gsub('FROM j', 'FROM j WHERE id>0')
                            :gsub('FROM u', 'FROM u WHERE id>0')
                        h.sql('SET SESSION "sql_seq_scan"=false')
                        local result, err = box.execute(guarded)
                        h.sql('SET SESSION "sql_seq_scan"=true')
                        if index == 'coll_search' then
                            t.assert(result, tostring(err))
                        else
                            t.assert_equals(result, nil)
                            t.assert_str_contains(tostring(err), 'Scanning')
                        end
                    end
                    for _, verb in ipairs({'UPDATE', 'DELETE'}) do
                        box.begin()
                        local query = verb == 'UPDATE' and
                            'UPDATE v INDEXED BY coll_scan ' ..
                            'SET bucket=bucket+10' or
                            'DELETE FROM v INDEXED BY coll_scan'
                        query = query .. ' WHERE ' .. predicate .. suffix
                        t.assert_str_contains(h.plan(query), 'SCAN TABLE')
                        checks.assert_direction(query, box.space.V,
                                                box.space.V.index.COLL_SCAN,
                                                reverse)
                        t.assert_equals(h.sql(query).row_count, 4)
                        local expected = {}
                        if verb == 'UPDATE' then
                            for id = 1, 4 do
                                table.insert(expected, {
                                    id, math.ceil(id / 2) + 10,
                                    letters[(id - 1) % 2 + 1], 7})
                            end
                        end
                        h.rows('SELECT * FROM v ORDER BY id', expected)
                        box.rollback()
                    end
                end
                if case.ready then h.sql('DROP INDEX ux ON u') end
            end
        end
    end)
end

g.test_range_values_follow_in_passes = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        rawset(_G, 'skip_scan_bound_calls', 0)
        rawset(_G, 'skip_scan_bound_offset', 0)
        box.schema.func.create('SKIP_SCAN_BOUND', {
            body = [[function()
                _G.skip_scan_bound_calls = _G.skip_scan_bound_calls + 1
                return _G.skip_scan_bound_calls + _G.skip_scan_bound_offset
            end]], returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX p ON v(tenant,bucket,k)')
        h.sql('CREATE INDEX i ON v(bucket,tenant,k)')
        h.sql('CREATE INDEX ordinary ON v(tenant,k)')
        for bucket = 1, 50 do
            h.sql(('INSERT INTO v VALUES(%d,1,%d,2),(%d,2,%d,2)')
                  :format(bucket * 2 - 1, bucket, bucket * 2, bucket))
        end
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, index in ipairs({'p', 'i', 'ordinary'}) do
                for _, case in ipairs({
                    {op = '>', k = 2, offset = 0, first = true},
                    {op = '>=', k = 2, offset = 1, first = true},
                    {op = '<', k = 1, offset = 0, first = false},
                    {op = '<=', k = 2, offset = 0, first = false},
                }) do
                    h.sql(('UPDATE v SET k=%d'):format(case.k))
                    local query = ('SELECT id FROM v INDEXED BY %s WHERE ' ..
                                   'tenant IN (1,2) AND ' ..
                                   'k%sSKIP_SCAN_BOUND() /* reverse=%s */')
                                  :format(index, case.op, tostring(reverse))
                    checks.assert_search(query, index == 'i' and
                        'ANY(BUCKET) AND TENANT=? AND K' or index == 'p' and
                        'TENANT=? AND ANY(BUCKET) AND K' or 'TENANT=? AND K')
                    checks.assert_direction(query, box.space.V,
                                            box.space.V.index[index:upper()],
                                            reverse)
                    local tenant = case.first ~= reverse and 1 or 2
                    local expected = {}
                    for bucket = 1, 50 do
                        table.insert(expected, {(bucket - 1) * 2 + tenant})
                    end
                    -- With an inner tenant IN, both tenants share the
                    -- bound evaluated once for the pass.
                    local calls = index == 'i' and 1 or 2
                    if index == 'i' then
                        expected = {}
                        for id = 1, case.first and 100 or 0 do
                            table.insert(expected, {id})
                        end
                    end
                    local stmt = assert(box.prepare(query))
                    for _ = 1, 2 do
                        _G.skip_scan_bound_calls = 0
                        _G.skip_scan_bound_offset = case.offset
                        local rows = assert(stmt:execute()).rows
                        t.assert_equals(checks.sorted(rows), expected, query)
                        t.assert_equals(_G.skip_scan_bound_calls, calls,
                                        query)
                    end
                    stmt:unprepare()
                end
            end
        end
        -- A new outer row must not see the preceding row's saved bounds.
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,0),(2,10),(3,0)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, index in ipairs({'p', 'i'}) do
                local query = ('SELECT u.id,v.id FROM u CROSS JOIN v ' ..
                    'INDEXED BY %s WHERE tenant IN (1,2) ' ..
                    'AND k>=SKIP_SCAN_BOUND()+u.x /* outer reverse=%s */')
                    :format(index, tostring(reverse))
                local reference = query:gsub('INDEXED BY ' .. index .. ' ',
                                             'INDEXED BY ordinary ')
                _G.skip_scan_bound_calls = 0
                _G.skip_scan_bound_offset = 0
                local expected = {}
                for id = 1, 100 do
                    table.insert(expected, {reverse and 3 or 1, id})
                end
                t.assert_equals(checks.sorted(h.sql(reference).rows), expected)
                t.assert_equals(_G.skip_scan_bound_calls, 6)
                _G.skip_scan_bound_calls = 0
                checks.assert_direction(query, box.space.V,
                                        box.space.V.index[index:upper()],
                                        reverse)
                t.assert_equals(checks.sorted(h.sql(query).rows), expected)
                t.assert_equals(_G.skip_scan_bound_calls,
                                index == 'i' and 3 or 6)
            end
        end
        box.schema.func.drop('SKIP_SCAN_BOUND')
        rawset(_G, 'skip_scan_bound_calls', nil)
        rawset(_G, 'skip_scan_bound_offset', nil)
    end)
end

g.test_unreached_range_is_not_evaluated = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        rawset(_G, 'skip_scan_bound_calls', 0)
        box.schema.func.create('SKIP_SCAN_FAIL_BOUND', {
            body = [[function()
                _G.skip_scan_bound_calls = _G.skip_scan_bound_calls + 1
                error('unreached bound')
            end]], returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX p ON v(tenant,bucket,k)')
        h.sql('CREATE INDEX i ON v(bucket,tenant,k)')
        h.sql('CREATE INDEX ordinary ON v(tenant,k)')
        h.sql('INSERT INTO v VALUES(1,1,1,2),(2,2,1,2)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, index in ipairs({'p', 'i', 'ordinary'}) do
                for _, op in ipairs({'>', '>=', '<', '<='}) do
                    local query = ('SELECT id FROM v INDEXED BY %s ' ..
                        'WHERE tenant IN (SELECT id FROM u) ' ..
                        'AND k%sSKIP_SCAN_FAIL_BOUND() /* empty reverse=%s */')
                        :format(index, op, tostring(reverse))
                    if index ~= 'ordinary' then
                        t.assert_str_contains(h.plan(query), 'ANY(BUCKET)')
                    end
                    checks.assert_direction(query, box.space.V,
                                            box.space.V.index[index:upper()],
                                            reverse)
                    h.rows(query, {})
                    t.assert_equals(_G.skip_scan_bound_calls, 0)
                    query = ('SELECT id FROM v INDEXED BY %s ' ..
                        'WHERE tenant=? AND k%sCAST(? AS INTEGER) ' ..
                        '/* null reverse=%s */')
                        :format(index, op, tostring(reverse))
                    h.rows(query, {}, {box.NULL, 'x'})
                end
            end
        end
        box.schema.func.drop('SKIP_SCAN_FAIL_BOUND')
        rawset(_G, 'skip_scan_bound_calls', nil)
    end)
end

g.test_reached_bounds_and_error_order = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        local decimal = require('decimal')
        rawset(_G, 'skip_scan_bound_calls', 0)
        box.schema.func.create('SKIP_SCAN_FAIL_BOUND', {
            body = [[function()
                _G.skip_scan_bound_calls = _G.skip_scan_bound_calls + 1
                error('unreached bound')
            end]], returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k,c)')
        h.sql('CREATE INDEX ordinary ON v(a,k,c)')
        h.sql('INSERT INTO v VALUES(1,1,1,1,1),(2,2,1,1,1)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local start_op = reverse and '<' or '>'
            local end_op = reverse and '>' or '<'
            local absent = reverse and -5 or 5
            local cases = {
                {where = 'a=? AND k' .. start_op .. '?',
                 params = {'x', box.NULL}},
                {where = 'a=? AND k' .. start_op .. '?',
                 params = {0.5, 'x'}, code = 171},
                {where = 'a=? AND k' .. start_op .. '?',
                 params = {decimal.new('0.5'), 'x'}, code = 171},
                {where = 'a IN (1,2) AND k=? AND c=1',
                 params = {require('datetime').interval.new{day=1}}, code = 171,
                 key = 'ANY(BUCKET) AND A=? AND K=? AND C=?'},
                -- A NULL range must also bypass invalid cached key values.
                {where = 'a IN (1,2) AND k=? AND c' .. start_op .. '?',
                 params = {require('datetime').interval.new{day=1}, box.NULL},
                 key = 'ANY(BUCKET) AND A=? AND K=? AND C' .. start_op .. '?'},
            }
            for _, prefix in ipairs({'a=1', 'a IN (1,2)'}) do
                for _, terminal in ipairs({'CAST(? AS INTEGER)',
                                           'SKIP_SCAN_FAIL_BOUND()'}) do
                    table.insert(cases, {
                        where = prefix .. ' AND k' .. start_op .. '?' ..
                                ' AND k' .. end_op .. terminal,
                        params = terminal:match('CAST') and {box.NULL, 'bad'} or
                                                            {box.NULL},
                        calls = 0,
                        key = 'ANY(BUCKET) AND A=? AND K>? AND K<?',
                    })
                end
            end
            for _, prefix in ipairs({
                'a=' .. absent,
                ('a IN (%d,%d)'):format(absent, absent * 2),
                'a=1 AND k' .. start_op .. (reverse and '0' or '5'),
            }) do
                for _, terminal in ipairs({'CAST(? AS INTEGER)',
                                           'SKIP_SCAN_FAIL_BOUND()'}) do
                    table.insert(cases, {
                        where = prefix .. ' AND k' .. end_op .. terminal,
                        params = terminal:match('CAST') and {'bad'} or {},
                        calls = 0,
                    })
                end
            end
            -- Reached terminal expressions must still report their error.
            table.insert(cases, {
                where = 'a=1 AND k' .. start_op .. (reverse and '2' or '0') ..
                        ' AND k' .. end_op .. 'SKIP_SCAN_FAIL_BOUND()',
                code = 0, calls = 1,
            })
            for n, case in ipairs(cases) do
                local query = ('SELECT id FROM v INDEXED BY %%s WHERE %s ' ..
                               '/* reverse=%s case=%d */')
                              :format(case.where, tostring(reverse), n)
                for _, index in ipairs({'ordinary', 's'}) do
                    local sql = query:format(index)
                    if index == 's' then
                        checks.assert_search(sql, case.key or
                            'ANY(BUCKET) AND A=? AND K', case.params)
                    end
                    checks.assert_direction(sql, box.space.V,
                        box.space.V.index[index:upper()], reverse, case.params)
                    _G.skip_scan_bound_calls = 0
                    local result, err = box.execute(sql, case.params or {})
                    if case.code then
                        t.assert_equals(result, nil, sql)
                        t.assert_equals(err.code, case.code, sql)
                        if n == 4 then
                            t.assert_str_contains(tostring(err), 'interval')
                            t.assert_str_contains(tostring(err), 'integer')
                        end
                    else
                        t.assert(result, tostring(err) .. ': ' .. sql)
                        t.assert_equals(result.rows, {}, sql)
                    end
                    if case.calls then
                        t.assert_equals(_G.skip_scan_bound_calls, case.calls,
                                        sql)
                    end
                end
            end
        end
        box.schema.func.drop('SKIP_SCAN_FAIL_BOUND')
        rawset(_G, 'skip_scan_bound_calls', nil)
    end)
end

g.test_saved_fractional_deterministic_bounds = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        h.sql('CREATE INDEX ordinary ON v(a,k)')
        local expected = {{}, {}}
        for bucket = 1, 50 do
            for a = 1, 2 do
                for k = 1, 2 do
                    local id = (bucket - 1) * 4 + (a - 1) * 2 + k
                    box.space.V:insert{id, bucket, a, k}
                    table.insert(expected[k], {id})
                end
            end
        end
        rawset(_G, 'skip_scan_bound_calls', 0)
        for _, kind in ipairs({'double', 'decimal'}) do
            local value = kind == 'double' and '1.5' or
                          "require('decimal').new('1.5')"
            box.schema.func.create('SKIP_SCAN_BOUND', {
                body = ('function() _G.skip_scan_bound_calls = ' ..
                        '_G.skip_scan_bound_calls + 1; return %s end')
                       :format(value),
                returns = kind, is_deterministic = true, exports = {'SQL'},
            })
            for _, reverse in ipairs({false, true}) do
                h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                      :format(tostring(reverse)))
                for _, op in ipairs({'>', '>=', '<', '<='}) do
                    local predicate = 'a IN (1,2) AND k' .. op ..
                                      'SKIP_SCAN_BOUND()'
                    local query = ('SELECT id FROM v INDEXED BY s WHERE %s ' ..
                                   '/* reverse=%s kind=%s */')
                                  :format(predicate, tostring(reverse), kind)
                    checks.assert_search(query, 'ANY(BUCKET) AND A=? AND K')
                    checks.assert_direction(query, box.space.V,
                                            box.space.V.index.S, reverse)
                    local statement = box.prepare(query)
                    for _ = 1, 2 do
                        _G.skip_scan_bound_calls = 0
                        local result, err = statement:execute()
                        t.assert(result, tostring(err))
                        t.assert_equals(checks.sorted(result.rows),
                            expected[op:sub(1, 1) == '>' and 2 or 1])
                        t.assert_equals(_G.skip_scan_bound_calls, 1)
                    end
                    statement:unprepare()
                    -- Use a parameter for the independent full-scan
                    -- oracle: evaluating the counted function there
                    -- would change counts.
                    local bound = kind == 'double' and 1.5 or
                                  require('decimal').new('1.5')
                    t.assert_equals(checks.primary_rows(box.space.V,
                        'a IN (1,2) AND k' .. op .. '?', {bound}),
                        expected[op:sub(1, 1) == '>' and 2 or 1])
                end
            end
            box.schema.func.drop('SKIP_SCAN_BOUND')
        end
        rawset(_G, 'skip_scan_bound_calls', nil)
    end)
end

g.test_independent_scalar_subquery_is_built_once = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,1),(2,3),(3,3),(4,NULL)')
        rawset(_G, 'skip_scan_rhs_calls', 0)
        box.schema.func.create('SKIP_SCAN_RHS', {
            body = [[function(x)
                _G.skip_scan_rhs_calls = _G.skip_scan_rhs_calls + 1
                return x
            end]], param_list = {'integer'}, returns = 'integer',
            is_deterministic = true, exports = {'SQL'},
        })
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local query = ('SELECT id FROM t INDEXED BY bk WHERE ' ..
                           'k IN (SELECT SKIP_SCAN_RHS(x) FROM u) ' ..
                           '/* reverse=%s */'):format(tostring(reverse))
            checks.assert_search(query, 'ANY(BUCKET_ID) AND K=?')
            local program, cursor = checks.assert_direction(
                query, box.space.T, box.space.T.index.BK, reverse)
            local start, inner
            for _, row in ipairs(program) do
                -- The first seek of the cursor finds the next group.
                if row[3] == cursor and row[2]:match('^Seek') and
                   start == nil then start = row[1] end
                if row[2] == 'NextIfOpen' or row[2] == 'PrevIfOpen' then
                    inner = row[4]
                end
            end
            t.assert_gt(inner, start)
            local statement = box.prepare(query)
            for _ = 1, 2 do
                _G.skip_scan_rhs_calls = 0
                local result, err = statement:execute()
                t.assert(result, tostring(err))
                t.assert_equals(checks.sorted(result.rows),
                                {{2}, {3}, {7}, {8}})
                t.assert_equals(_G.skip_scan_rhs_calls, 4)
            end
            statement:unprepare()
        end
        box.schema.func.drop('SKIP_SCAN_RHS')
        rawset(_G, 'skip_scan_rhs_calls', nil)
    end)
end

g.test_prepared_query_after_saved_value_error = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,b INTEGER,c INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,b,c,k)')
        local expected = {{}, {}}
        local id = 0
        for bucket = 1, 3 do
            for a = 1, 3 do
                for b = 1, 2 do
                    for c = 1, 2 do
                        id = id + 1
                        box.space.V:insert{id, bucket, a, b, c, 2}
                        table.insert(expected[c], {id})
                    end
                end
            end
        end
        rawset(_G, 'skip_scan_error_calls', 0)
        rawset(_G, 'skip_scan_saved_calls', 0)
        rawset(_G, 'skip_scan_should_fail', false)
        box.schema.func.create('SKIP_SCAN_ERROR_EQ', {
            body = [[function(x)
                _G.skip_scan_error_calls = _G.skip_scan_error_calls + 1
                if _G.skip_scan_should_fail then
                    error('saved value failed')
                end
                return x
            end]], param_list = {'integer'}, returns = 'integer',
            is_deterministic = false, exports = {'SQL'},
        })
        box.schema.func.create('SKIP_SCAN_SAVED_RANGE', {
            body = [[function(x)
                _G.skip_scan_saved_calls = _G.skip_scan_saved_calls + 1
                return x
            end]], param_list = {'double'}, returns = 'double',
            is_deterministic = false, exports = {'SQL'},
        })
        local ok, err = pcall(function()
            for _, reverse in ipairs({false, true}) do
                h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                      :format(tostring(reverse)))
                local query = ('SELECT id FROM v INDEXED BY s WHERE ' ..
                    'a IN (1,2,3) AND b IN (1,2) AND ' ..
                    'c=SKIP_SCAN_ERROR_EQ(?) ' ..
                    'AND k>SKIP_SCAN_SAVED_RANGE(?) /* reverse=%s */')
                    :format(tostring(reverse))
                checks.assert_search(query,
                    'ANY(BUCKET) AND A=? AND B=? AND C=? AND K>?', {1, 0.5})
                checks.assert_direction(query, box.space.V, box.space.V.index.S,
                                        reverse, {1, 0.5})
                local statement = box.prepare(query)
                for repeat_id = 1, 6 do
                    _G.skip_scan_error_calls = 0
                    _G.skip_scan_saved_calls = 0
                    _G.skip_scan_should_fail = true
                    local result, failure = statement:execute({1, 0.5})
                    t.assert_equals(result, nil)
                    t.assert_str_contains(tostring(failure),
                                          'saved value failed')
                    t.assert_equals(_G.skip_scan_error_calls, 1)
                    t.assert_equals(_G.skip_scan_saved_calls, 0)
                    _G.skip_scan_error_calls = 0
                    _G.skip_scan_saved_calls = 0
                    _G.skip_scan_should_fail = false
                    local c = repeat_id % 2 + 1
                    result, failure = statement:execute({c, 1.5})
                    t.assert(result, tostring(failure))
                    t.assert_equals(checks.sorted(result.rows), expected[c])
                    -- The values saved by the previous execution are
                    -- not reused: c changes on every repeat.
                    t.assert_equals(_G.skip_scan_error_calls, 1)
                    t.assert_equals(_G.skip_scan_saved_calls, 1)
                    t.assert_equals(checks.primary_rows(box.space.V,
                        'a IN (1,2,3) AND b IN (1,2) AND c=? AND k>1.5', {c}),
                        expected[c])
                end
                statement:unprepare()
            end
        end)
        box.schema.func.drop('SKIP_SCAN_ERROR_EQ')
        box.schema.func.drop('SKIP_SCAN_SAVED_RANGE')
        rawset(_G, 'skip_scan_error_calls', nil)
        rawset(_G, 'skip_scan_saved_calls', nil)
        rawset(_G, 'skip_scan_should_fail', nil)
        if not ok then error(err) end
    end)
end

g.test_filter_in_has_no_search_multiplier = function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              s STRING,k INTEGER)]])
        h.sql('CREATE INDEX filter_cost ON v(bucket,s,k)')
        h.sql('CREATE INDEX filter_base ON v(bucket,s,k)')
        h.sql([[INSERT INTO v VALUES(1,1,'B',7),(2,1,'b',7)]])
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY,
                              x STRING COLLATE "unicode_ci")]])
        h.sql([[INSERT INTO u VALUES(1,'B')]])
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', true)
        local ok, err = pcall(function()
            for _, index in ipairs({'filter_base', 'filter_cost'}) do
                local predicate = index == 'filter_cost' and
                                  's IN (SELECT x FROM u) AND k=7' or 'k=7'
                local query = ('SELECT id FROM v INDEXED BY %s WHERE %s')
                              :format(index, predicate)
                checks.assert_search(query, 'ANY(BUCKET) AND ANY(S) AND K=?')
                local program = h.sql('EXPLAIN (opcode) ' .. query).rows
                for _, row in ipairs(program) do
                    t.assert_not_equals(row[2], 'NextIfOpen')
                    t.assert_not_equals(row[2], 'PrevIfOpen')
                end
                t.assert_equals(checks.sorted(h.sql(query).rows), {{1}, {2}})
            end
        end)
        box.error.injection.set('ERRINJ_SQL_SKIP_SCAN_FULL_KEY', false)
        if not ok then error(err) end
    end)
    local costs = {}
    for _, index in ipairs({'FILTER_BASE', 'FILTER_COST'}) do
        local pattern = 'skip%-scan cost: index=' .. index ..
                        ' run=(%-?%d+) base=(%-?%d+) ' ..
                        'multiplier=(%-?%d+) inner=(%-?%d+)'
        local line = cg.server:grep_log('(' .. pattern .. ')')
        t.assert(line)
        local run, base, multiplier, inner = line:match(pattern)
        costs[index] = tonumber(multiplier)
        t.assert_equals(tonumber(inner), -1)
        t.assert_equals(tonumber(run), tonumber(base) + tonumber(multiplier))
    end
    -- Both searches pay for groups; the IN filter adds no search repetition.
    t.assert_equals(costs.FILTER_COST, costs.FILTER_BASE)
end

-- The fixed prefix and suffix form one reached initial key. No index
-- movement may precede the suffix IN, NULL and type checks.
g.test_fixed_prefix_initial_key_order = function(cg)
    cg.server:exec(function(engine)
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,a INTEGER,
                              bucket INTEGER,c INTEGER,d INTEGER)]])
        h.sql('CREATE INDEX s ON v(a,bucket,c,d)')
        h.sql('CREATE INDEX ordinary ON v(a,c,d)')
        h.sql('INSERT INTO v VALUES(1,1,1,1,1),(2,2,1,1,1)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local op = reverse and '<' or '>'
            local cases = {
                {'a=? AND c' .. op .. '?', {'x', box.NULL}},
                {'a=? AND c' .. op .. '?', {0.5, 'x'}, 171},
                {'a=? AND c' .. op .. '?', {require('decimal').new('0.5'), 'x'},
                 171},
                {'a=? AND c IN (SELECT c FROM v WHERE id=-1)', {'x'}},
                {'a=? AND c IN (1,2) AND d=?', {'x', box.NULL}},
                {'a=5 AND c' .. op .. 'CAST(? AS INTEGER)', {'bad'}, 171},
            }
            for n, case in ipairs(cases) do
                for _, index in ipairs({'ordinary', 's'}) do
                    local q = ('SELECT id FROM v INDEXED BY %s WHERE %s ' ..
                               '/* prefix %s %d */')
                              :format(index, case[1], tostring(reverse), n)
                    if index == 's' then
                        checks.assert_search(q, 'A=? AND ANY(BUCKET) AND C',
                                             case[2])
                    end
                    checks.assert_direction(q, box.space.V,
                        box.space.V.index[index:upper()], reverse, case[2])
                    local result, err = box.execute(q, case[2])
                    if case[3] then
                        t.assert_equals(result, nil, q)
                        t.assert_equals(err.code, case[3], q)
                    else
                        t.assert(result, tostring(err))
                        t.assert_equals(result.rows, {}, q)
                    end
                end
            end
        end
        h.sql('DROP TABLE v')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,k)')
        for bucket = 1, 100 do box.space.V:insert{bucket, bucket, 1} end
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, case in ipairs({
                {'k' .. (reverse and '<' or '>') .. '?', {box.NULL}},
                {'k=?', {0.5}},
            }) do
                local q = ('SELECT id FROM v INDEXED BY s WHERE %s /* %s */')
                          :format(case[1], tostring(reverse))
                checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                        reverse, case[2])
                local before = engine == 'vinyl' and
                               box.space.V.index.S:stat().lookup or 0
                h.rows(q, {}, case[2])
                if engine == 'vinyl' then
                    t.assert_equals(box.space.V.index.S:stat().lookup, before)
                end
            end
        end
    end, {cg.params.engine})
end

g.test_nested_in_default_step_limit = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        local settings = box.space._session_settings
        t.assert_equals(settings:get{'sql_vdbe_max_steps'}[2], 45000)
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,b INTEGER,c INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,b,c,k)')
        h.sql('CREATE INDEX ordinary ON v(a,b,c,k)')
        local expected, values = {}, {}
        for i = 1, 24 do values[i] = tostring(i) end
        for bucket = 1, 4 do
            box.begin()
            for a = 1, 24 do
                for b = 1, 24 do
                    local id = #expected + 1
                    box.space.V:insert{id, bucket, a, b, 7, 2}
                    expected[id] = {id}
                end
            end
            box.commit()
        end
        local list = table.concat(values, ',')
        local lists = ('a IN (%s) AND b IN (%s)'):format(list, list)
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, parameterized in ipairs({false, true}) do
                local predicate = lists .. (parameterized and
                                            ' AND c=? AND k>?' or
                                            ' AND c=7 AND k>1.5')
                local params = parameterized and
                               {7, require('decimal').new('1.5')} or {}
                for _, index in ipairs({'s', 'ordinary'}) do
                    local q = ('SELECT id FROM v INDEXED BY %s WHERE %s ' ..
                               '/* limit reverse=%s */')
                              :format(index, predicate, tostring(reverse))
                    checks.assert_search(q, (index == 's' and
                        'ANY(BUCKET) AND ' or '') ..
                        'A=? AND B=? AND C=? AND K>?', params)
                    checks.assert_direction(q, box.space.V,
                        box.space.V.index[index:upper()], reverse, params)
                    t.assert_equals(checks.sorted(h.sql(q, params).rows),
                                    expected)
                    -- No expression cache table is needed for these values.
                    if index == 's' then
                        local program =
                            h.sql('EXPLAIN (opcode) ' .. q, params).rows
                        for _, row in ipairs(program) do
                            if row[2] == 'IteratorOpen' then
                                t.assert_not_equals(tonumber(row[7], 16), 0x80)
                            end
                        end
                    end
                end
                t.assert_equals(checks.primary_rows(box.space.V, predicate,
                                                   params), expected)
            end
        end
    end)
end

g.test_three_part_bound_with_inner_in = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER NOT NULL,
                    a INTEGER NOT NULL,b INTEGER NOT NULL,c INTEGER NOT NULL)]])
        h.sql('CREATE INDEX s ON v(bucket,a,b,c)')
        h.sql('CREATE INDEX ordinary ON v(a,b,c)')
        h.sql([[INSERT INTO v VALUES(1,1,0,0,1),(2,1,1,1,1),(3,1,2,2,1),
            (4,2,0,0,1),(5,2,1,1,1),(6,2,2,2,1),
            (7,1,1,2,1),(8,1,1,0,1),(9,2,1,2,1),(10,2,1,0,1)]])
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local op = reverse and '<' or '>'
            for _, index in ipairs({'s', 'ordinary'}) do
                local q = ('SELECT id FROM v INDEXED BY %s WHERE ' ..
                           '(a,b,c)%s(?,NULL,?) /* %s */')
                          :format(index, op, tostring(reverse))
                checks.assert_direction(q, box.space.V,
                    box.space.V.index[index:upper()], reverse, {1, 'x'})
                t.assert_equals(checks.sorted(h.sql(q, {1, 'x'}).rows),
                                reverse and {{1}, {4}} or {{3}, {6}})
                local result, err = box.execute(q, {'x', 1})
                t.assert_equals(result, nil)
                t.assert_equals(err.code, 171)
            end
            local predicate = 'a IN (1.5,1) AND (b,c)' .. op .. '(1,NULL)'
            local q = ('SELECT id FROM v INDEXED BY s WHERE %s /* %s */')
                      :format(predicate, tostring(reverse))
            checks.assert_search(q, 'ANY(BUCKET) AND A=? AND (B,C)' .. op ..
                                    '(?,?)')
            checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                    reverse)
            local expected = reverse and {{8}, {10}} or {{7}, {9}}
            t.assert_equals(checks.sorted(h.sql(q).rows), expected)
            t.assert_equals(checks.primary_rows(box.space.V, predicate),
                            expected)
        end
    end)
end

g.test_two_saved_bounds_together = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        for bucket = 1, 50 do
            for a = 1, 2 do
                for k = 1, 3 do
                    box.space.V:insert{(bucket - 1) * 6 + (a - 1) * 3 + k,
                                       bucket, a, k}
                end
            end
        end
        rawset(_G, 'skip_scan_two_calls', {0, 0})
        box.schema.func.create('SKIP_SCAN_TWO_BOUND', {
            body = [[function(n)
                _G.skip_scan_two_calls[n] = _G.skip_scan_two_calls[n] + 1
                return n == 1 and 0 or 4
            end]], param_list = {'integer'}, returns = 'integer',
            is_deterministic = false, exports = {'SQL'},
        })
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local q = ('SELECT count(*) FROM v INDEXED BY s ' ..
                       'WHERE a IN (1,2) AND k>SKIP_SCAN_TWO_BOUND(1) ' ..
                       'AND k<SKIP_SCAN_TWO_BOUND(2) /* %s */')
                      :format(tostring(reverse))
            checks.assert_search(q, 'ANY(BUCKET) AND A=? AND K>? AND K<?')
            checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                    reverse)
            local stmt = assert(box.prepare(q))
            for _ = 1, 2 do
                _G.skip_scan_two_calls = {0, 0}
                t.assert_equals(assert(stmt:execute()).rows, {{300}})
                t.assert_equals(_G.skip_scan_two_calls, {1, 1})
            end
            stmt:unprepare()
        end
        box.schema.func.drop('SKIP_SCAN_TWO_BOUND')
        rawset(_G, 'skip_scan_two_calls', nil)
    end)
end

g.test_or_to_in_preserves_collation = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              s STRING)]])
        h.sql('CREATE INDEX s ON v(bucket,s)')
        h.sql('CREATE INDEX ordinary ON v(s)')
        h.sql('CREATE INDEX ci ON v(bucket,s COLLATE "unicode_ci")')
        local function reset()
            box.space.V:truncate()
            for _, row in ipairs({{1, 1, 'B'}, {2, 1, 'b'},
                                  {3, 2, 'b'}, {4, 2, 'C'}}) do
                box.space.V:insert(row)
            end
        end
        local cases = {
            {[[s='B' COLLATE "unicode_ci" OR s='C' COLLATE "unicode_ci"]],
             {{1}, {2}, {3}, {4}}},
            {[[s COLLATE "unicode_ci"='b' OR s='C']], {{1}, {2}, {3}, {4}}},
            {[[s='C' OR s COLLATE "unicode_ci"='b']], {{1}, {2}, {3}, {4}}},
            {[[s COLLATE "unicode_ci"='b' OR s COLLATE "unicode_ci"='c']],
             {{1}, {2}, {3}, {4}}, 'ci'},
            {[[s='B' OR s='C']], {{1}, {4}}, 'binary'},
        }
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for n, case in ipairs(cases) do
                local indexes = {'s', 'ordinary'}
                if case[3] == 'ci' then table.insert(indexes, 'ci') end
                for _, index in ipairs(indexes) do
                    reset()
                    local clause =
                        (' FROM v INDEXED BY %s WHERE %s /* %s %d */')
                        :format(index, case[1], tostring(reverse), n)
                    local query = 'SELECT id' .. clause
                    t.assert_equals(checks.sorted(h.sql(query).rows), case[2])
                    t.assert_equals(checks.primary_rows(box.space.V, case[1]),
                                    case[2])
                    checks.assert_direction(query, box.space.V,
                        box.space.V.index[index:upper()], reverse)
                    if case[3] == 'binary' and index ~= 'ci' then
                        checks.assert_search(query, 'S=?')
                    elseif case[3] == 'ci' and index == 'ci' then
                        checks.assert_search(query, 'ANY(BUCKET) AND S=?')
                    elseif index == 's' then
                        t.assert_str_contains(h.plan(query), 'SCAN TABLE V')
                    end
                    local update = ('UPDATE v INDEXED BY %s ' ..
                                    'SET bucket=bucket+10 WHERE %s')
                                   :format(index, case[1])
                    t.assert_equals(h.sql(update).row_count, #case[2])
                    t.assert_equals(
                        checks.primary_rows(box.space.V, 'bucket>=10'),
                        case[2])
                    reset()
                    t.assert_equals(h.sql('DELETE' .. clause).row_count,
                                    #case[2])
                    local remaining = #box.space.V:select{}
                    t.assert_equals(remaining, 4 - #case[2])
                end
            end
        end
    end)
end

g.test_constant_null_bound_ends_inner_in_pass = function(cg)
    cg.server:exec(function(engine)
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,NULL)')
        box.begin()
        for bucket = 1, 2000 do
            for a = 1, 2 do
                box.space.V:insert{(bucket - 1) * 2 + a, bucket, a, 1}
            end
        end
        box.commit()
        local settings = box.space._session_settings
        t.assert_equals(settings:get{'sql_vdbe_max_steps'}[2], 45000)
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, case in ipairs({
                {'k>? AND k<2', not reverse},
                {'k>0 AND k<?', reverse},
            }) do
                for _, source in ipairs({'?', 'CAST(? AS INTEGER)',
                                          'u.x', 'CAST(u.x AS INTEGER)'}) do
                    local outer = source:find('u.x', 1, true) ~= nil
                    local params = source:find('?', 1, true) and
                                   {box.NULL} or {}
                    local predicate = case[1]:gsub('%?', source)
                    local q = ('SELECT v.id FROM %s INDEXED BY s WHERE %s' ..
                               'a IN (1,2) AND %s /* null %s */')
                              :format(outer and 'u CROSS JOIN v' or 'v',
                                      outer and 'u.id=1 AND ' or '', predicate,
                                      tostring(reverse))
                    checks.assert_search(
                        q, 'ANY(BUCKET) AND A=? AND K>? AND K<?', params)
                    checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                            reverse, params)
                    local before = engine == 'vinyl' and
                                   box.space.V.index.S:stat().lookup or 0
                    h.rows(q, {}, params)
                    if engine == 'vinyl' then
                        local delta = box.space.V.index.S:stat().lookup - before
                        t.assert_equals(delta, case[2] and 0 or 1)
                    end
                end
            end
        end
    end, {cg.params.engine})
end

g.test_null_bound_preserves_next_combination_and_pass = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,tenant INTEGER,
                              bucket INTEGER,a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(tenant,bucket,a,k)')
        local expected = {{}, {}}
        for tenant = 1, 2 do
            for bucket = 1, 5 do
                for a = 1, 2 do
                    local id = (tenant - 1) * 10 + (bucket - 1) * 2 + a
                    box.space.V:insert{id, tenant, bucket, a, 1}
                    table.insert(expected[a], {id})
                end
            end
        end
        rawset(_G, 'skip_scan_nullable_calls', 0)
        box.schema.func.create('SKIP_SCAN_NULLABLE_BOUND', {
            body = [[function(x)
                _G.skip_scan_nullable_calls = _G.skip_scan_nullable_calls + 1
                return _G.skip_scan_nullable_calls % 2 == 1 and box.NULL or x
            end]], param_list = {'integer'}, returns = 'integer',
            is_deterministic = false, exports = {'SQL'},
        })
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local op, bound = reverse and '<' or '>', reverse and 2 or 0
            local q = ('SELECT id FROM v INDEXED BY s WHERE tenant IN (1,2) ' ..
                       'AND a IN (1,2) AND k%sSKIP_SCAN_NULLABLE_BOUND(?) ' ..
                       '/* %s */'):format(op, tostring(reverse))
            checks.assert_search(q, 'TENANT=? AND ANY(BUCKET) AND A=? AND K' ..
                                 op .. '?', {bound})
            checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                    reverse, {bound})
            local stmt = assert(box.prepare(q))
            for _ = 1, 2 do
                _G.skip_scan_nullable_calls = 0
                local rows = assert(stmt:execute({bound})).rows
                -- The first tenant pass gets NULL, the second one gets
                -- the bound for all values of a.
                local tenant = reverse and 1 or 2
                local rows_expected = {}
                for id = (tenant - 1) * 10 + 1, tenant * 10 do
                    table.insert(rows_expected, {id})
                end
                t.assert_equals(checks.sorted(rows), rows_expected)
                t.assert_equals(_G.skip_scan_nullable_calls, 2)
            end
            stmt:unprepare()
        end
        box.schema.func.drop('SKIP_SCAN_NULLABLE_BOUND')
        rawset(_G, 'skip_scan_nullable_calls', nil)
    end)
end

g.test_saved_interval_reports_type_error = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        local interval = require('datetime').interval.new{day=1}
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k,c)')
        h.sql('INSERT INTO v VALUES(1,1,1,1,1)')
        box.schema.func.create('SKIP_SCAN_IDENTITY_ANY', {
            body = [[function(x) return x end]], param_list = {'any'},
            returns = 'any', is_deterministic = false, exports = {'SQL'},
        })
        box.schema.func.create('SKIP_SCAN_IDENTITY_INT', {
            body = [[function(x) return x end]], param_list = {'integer'},
            returns = 'integer', is_deterministic = false, exports = {'SQL'},
        })
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local op = reverse and '<' or '>'
            for _, case in ipairs({
                {'k=SKIP_SCAN_IDENTITY_ANY(?) AND c=1', {interval}, true},
                {'k=? AND c' .. op .. 'SKIP_SCAN_IDENTITY_INT(?)',
                 {interval, 0}, true},
                {'k=? AND c' .. op .. 'SKIP_SCAN_IDENTITY_INT(?)',
                 {interval, box.NULL}, false},
            }) do
                local q = ('SELECT id FROM v INDEXED BY s WHERE a IN (1,2) ' ..
                           'AND %s /* interval cache %s */')
                          :format(case[1], tostring(reverse))
                checks.assert_search(q, 'ANY(BUCKET) AND A=? AND K=? AND C',
                                     case[2])
                checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                        reverse, case[2])
                local result, err = box.execute(q, case[2])
                if case[3] then
                    t.assert_equals(result, nil)
                    t.assert_equals(err.code, 171)
                    t.assert_str_contains(tostring(err), 'interval')
                    t.assert_str_contains(tostring(err), 'integer')
                else
                    t.assert(result, tostring(err))
                    t.assert_equals(result.rows, {})
                end
            end
        end
        box.schema.func.drop('SKIP_SCAN_IDENTITY_ANY')
        box.schema.func.drop('SKIP_SCAN_IDENTITY_INT')
    end)
end

g.test_eof_does_not_evaluate_later_in_bounds = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        h.sql('INSERT INTO v VALUES(1,1,0,1)')
        rawset(_G, 'skip_scan_eof_calls', 0)
        box.schema.func.create('SKIP_SCAN_EOF_BOUND', {
            body = [[function()
                _G.skip_scan_eof_calls = _G.skip_scan_eof_calls + 1
                if _G.skip_scan_eof_calls > 1 then error('unreached IN') end
                return 0
            end]], returns = 'integer', is_deterministic = false,
            exports = {'SQL'},
        })
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            local values = reverse and '-2,-1' or '1,2'
            local q = ('SELECT id FROM v INDEXED BY s WHERE a IN (%s) ' ..
                       'AND k%sSKIP_SCAN_EOF_BOUND() /* %s */')
                      :format(values, reverse and '<' or '>', tostring(reverse))
            checks.assert_search(q, 'ANY(BUCKET) AND A=? AND K')
            checks.assert_direction(q, box.space.V, box.space.V.index.S,
                                    reverse)
            local stmt = assert(box.prepare(q))
            for _ = 1, 2 do
                _G.skip_scan_eof_calls = 0
                t.assert_equals(assert(stmt:execute()).rows, {})
                t.assert_equals(_G.skip_scan_eof_calls, 1)
            end
            stmt:unprepare()
        end
        box.schema.func.drop('SKIP_SCAN_EOF_BOUND')
        rawset(_G, 'skip_scan_eof_calls', nil)
    end)
end

g.test_join_fallback_without_order_by = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,k INTEGER)')
        h.sql('INSERT INTO u VALUES(1,1),(2,3)')
        local expected = {{1, 2}, {1, 7}, {2, 3}, {2, 8}}
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, join in ipairs({'JOIN', 'CROSS JOIN'}) do
                local q = ('SELECT u.id,t.id FROM u %s t INDEXED BY bk ' ..
                           'ON t.k=u.k WHERE u.id>=1 /* no order %s */')
                          :format(join, tostring(reverse))
                local plan = h.plan(q)
                t.assert_equals(checks.sorted(h.sql(q).rows), expected)
                checks.assert_direction(q, box.space.T, box.space.T.index.BK,
                                        reverse)
                if join == 'JOIN' then
                    -- The contract permits this order: t precedes u, so
                    -- its dependent boundary is unavailable at this step.
                    t.assert_str_contains(plan, 'SCAN TABLE T')
                else
                    t.assert_str_contains(plan, 'ANY(BUCKET_ID) AND K=?')
                end
                h.sql('SET SESSION "sql_seq_scan"=false')
                if join == 'JOIN' then
                    local result, err = box.execute(q .. ' /* no scan */')
                    t.assert_equals(result, nil)
                    t.assert_str_contains(tostring(err),
                                          "Scanning is not allowed for 'T'")
                else
                    t.assert_equals(checks.sorted(h.sql(q ..
                        ' /* no scan */').rows), expected)
                end
                h.sql('SET SESSION "sql_seq_scan"=true')
            end
        end
    end)
end

g.test_outer_column_needs_no_cache_in_left_join = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER,c INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k,c)')
        h.sql([[INSERT INTO v VALUES(1,1,1,1,7),(2,1,2,1,7),
                                    (3,2,1,1,7),(4,2,2,1,7)]])
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        h.sql('INSERT INTO u VALUES(1,1),(2,NULL),(3,1)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            box.space.U:update({3}, {{'=', 2, 1}})
            local q = ('SELECT u.id,v.id FROM u LEFT JOIN v INDEXED BY s ' ..
                       'ON v.a IN (1,2) AND v.k=u.x AND v.c=7 ' ..
                       'WHERE u.id>=1 /* outer column %s */')
                      :format(tostring(reverse))
            checks.assert_search(q, 'ANY(BUCKET) AND A=? AND K=? AND C=?')
            local program = checks.assert_direction(q, box.space.V,
                box.space.V.index.S, reverse)
            for _, row in ipairs(program) do
                if row[2] == 'IteratorOpen' then
                    t.assert_not_equals(tonumber(row[7], 16), 0x80)
                end
            end
            local stmt = assert(box.prepare(q))
            t.assert_equals(checks.sorted(assert(stmt:execute()).rows),
                {{1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, box.NULL},
                 {3, 1}, {3, 2}, {3, 3}, {3, 4}})
            box.space.U:update({3}, {{'=', 2, 2}})
            t.assert_equals(checks.sorted(assert(stmt:execute()).rows),
                {{1, 1}, {1, 2}, {1, 3}, {1, 4}, {2, box.NULL}, {3, box.NULL}})
            stmt:unprepare()
        end
    end)
end

g.test_outer_null_range_preserves_next_row = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        h.sql('INSERT INTO v VALUES(1,1,1,1),(2,1,2,1),(3,2,1,1),(4,2,2,1)')
        h.sql('CREATE TABLE u(id INTEGER PRIMARY KEY,x INTEGER)')
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, join in ipairs({'LEFT JOIN', 'CROSS JOIN'}) do
                for _, source in ipairs({'u.x', 'CAST(u.x AS INTEGER)'}) do
                    for _, bound in ipairs({
                        {'v.k>%s AND v.k<2', 0},
                        {'v.k>0 AND v.k<%s', 2},
                    }) do
                        local q = ('SELECT u.id,v.id FROM u %s v ' ..
                                   'INDEXED BY s ON v.a IN (1,2) AND %s ' ..
                                   'WHERE u.id>=1 ' ..
                                   '/* next outer row %s */')
                                  :format(join, bound[1]:format(source),
                                          tostring(reverse))
                        checks.assert_search(q,
                            'ANY(BUCKET) AND A=? AND K>? AND K<?')
                        checks.assert_direction(q, box.space.V,
                                                box.space.V.index.S, reverse)
                        local stmt = assert(box.prepare(q))
                        for phase = 1, 2 do
                            local expected = {}
                            for id = 1, 4 do
                                local matches = id % 2 == phase - 1
                                box.space.U:replace{
                                    id, matches and bound[2] or box.NULL,
                                }
                                if matches then
                                    for v_id = 1, 4 do
                                        table.insert(expected, {id, v_id})
                                    end
                                elseif join == 'LEFT JOIN' then
                                    table.insert(expected, {id, box.NULL})
                                end
                            end
                            t.assert_equals(
                                checks.sorted(assert(stmt:execute()).rows),
                                expected)
                        end
                        stmt:unprepare()
                    end
                end
            end
        end
    end)
end

g.test_null_pass_does_not_check_unreached_in_type = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        local checks = require('test.sql-luatest.skip_scan_helpers')
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                              a INTEGER,k INTEGER)]])
        h.sql('CREATE INDEX s ON v(bucket,a,k)')
        h.sql('CREATE INDEX ordinary ON v(a,k)')
        h.sql('INSERT INTO v VALUES(1,1,1,1)')
        local params = {1, 'x', box.NULL}
        for _, reverse in ipairs({false, true}) do
            h.sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                  :format(tostring(reverse)))
            for _, index in ipairs({'s', 'ordinary'}) do
                local q = ('SELECT id FROM v INDEXED BY %s WHERE a IN (?,?) ' ..
                           'AND k>0 AND k<? /* unreached type %s */')
                          :format(index, tostring(reverse))
                checks.assert_search(q, (index == 's' and 'ANY(BUCKET) AND ' or
                                         '') .. 'A=? AND K>? AND K<?', params)
                checks.assert_direction(q, box.space.V,
                    box.space.V.index[index:upper()], reverse, params)
                local stmt = assert(box.prepare(q))
                for _ = 1, 2 do
                    local result, err = stmt:execute(params)
                    if index == 'ordinary' and not reverse then
                        t.assert_equals(result, nil)
                        t.assert_equals(err.code, 171)
                        t.assert_str_contains(tostring(err), "scalar('x')")
                    else
                        t.assert(result, tostring(err))
                        t.assert_equals(result.rows, {})
                    end
                end
                stmt:unprepare()
            end
        end
    end)
end

g.test_truth_predicates_as_suffix = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,
                              bucket_id INTEGER NOT NULL, f BOOLEAN)]])
        h.sql('CREATE INDEX bf ON v(bucket_id,f)')
        h.sql([[INSERT INTO v VALUES (1,1,NULL),(2,1,FALSE),(3,1,TRUE),
                (4,2,TRUE),(5,3,NULL),(6,3,FALSE)]])
        for _, case in ipairs({
            {'f IS TRUE', {{3}, {4}}},
            {'f IS FALSE', {{2}, {6}}},
            -- A nullable part: one search for the other value, one for NULL.
            {'f IS NOT TRUE', {{1}, {2}, {5}, {6}}},
            {'f IS NOT FALSE', {{1}, {3}, {4}, {5}}},
        }) do
            local sql = ('SELECT id FROM v INDEXED BY bf WHERE %s ' ..
                         'ORDER BY id'):format(case[1])
            t.assert_str_contains(h.plan(sql), 'ANY(BUCKET_ID) AND F=?')
            h.rows(sql, case[2])
            h.rows(('SELECT id FROM v NOT INDEXED WHERE %s ORDER BY id')
                   :format(case[1]), case[2])
        end
    end)
end

g.test_table_functions = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.skip([[SELECT id FROM t INDEXED BY bk
                 WHERE k IN (SELECT "VALUE" FROM unnest([3, 1]))
                 ORDER BY id]], {{2}, {3}, {7}, {8}})
        h.skip([[SELECT u."VALUE",t.id
                 FROM unnest([10, 20, 30]) WITH ORDINALITY AS u
                 CROSS JOIN t INDEXED BY bk ON t.k=u."ORDINALITY"
                 ORDER BY 1,2]],
               {{10, 2}, {10, 7}, {20, 5}, {30, 3}, {30, 8}})
        -- The table function is sought by the ordinality from skip-scan rows.
        local sql = [[SELECT t.id,u."VALUE" FROM t INDEXED BY bk
                      CROSS JOIN unnest([10, 20, 30]) WITH ORDINALITY AS u
                      ON u."ORDINALITY"=t.k WHERE t.k>=2 ORDER BY 1]]
        t.assert_str_contains(h.plan(sql), 'USING ORDINALITY')
        h.skip(sql, {{3, 30}, {5, 20}, {8, 30}})
    end)
end

-- A trigger program keeps reduced copies of its expressions. The bounds
-- built from them are evaluated and saved like those of a statement.
g.test_trigger_body = function(cg)
    cg.server:exec(function()
        local h = _G.skip_scan_test
        h.sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,
                              bucket_id INTEGER NOT NULL,
                              b INTEGER, c INTEGER)]])
        h.sql('CREATE INDEX bbc ON v(bucket_id,b,c)')
        for bucket = 1, 3 do
            for b = 1, 4 do
                h.sql('INSERT INTO v VALUES (?,?,?,?)',
                      {(bucket - 1) * 4 + b, bucket, b, b * 10 + bucket})
            end
        end
        h.skip([[SELECT id FROM v INDEXED BY bbc
                 WHERE b IN (1,3) AND c>abs(1 * 10 + 1) ORDER BY id]],
               {{3}, {5}, {7}, {9}, {11}})
        h.sql([[CREATE TABLE u(id INTEGER PRIMARY KEY AUTOINCREMENT,
                              x INTEGER, vid INTEGER)]])
        h.sql('CREATE TABLE j(id INTEGER PRIMARY KEY AUTOINCREMENT, x INTEGER)')
        h.sql([[CREATE TRIGGER tg AFTER INSERT ON j FOR EACH ROW BEGIN
                INSERT INTO u(x,vid) SELECT new.x,id FROM v INDEXED BY bbc
                WHERE b IN (new.x,new.x + 2) AND c>abs(new.x * 10 + 1);
                END]])
        h.sql('INSERT INTO j(x) VALUES (2),(1),(3)')
        h.rows('SELECT x,vid FROM u ORDER BY x,vid', {
            {1, 3}, {1, 5}, {1, 7}, {1, 9}, {1, 11},
            {2, 4}, {2, 6}, {2, 8}, {2, 10}, {2, 12},
            {3, 7}, {3, 11},
        })
    end)
end
