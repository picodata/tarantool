local t = require('luatest')
local server = require('luatest.server')

local g = t.group('seek_bounds', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
    cg.server:exec(function(engine)
        assert(box.execute(('SET SESSION "sql_default_engine"=\'%s\'')
                           :format(engine)))
        assert(box.execute([[CREATE TABLE t(id INTEGER PRIMARY KEY,
                             bucket INTEGER NOT NULL,a INTEGER NOT NULL,
                             b INTEGER NOT NULL)]]))
        assert(box.execute('CREATE INDEX i ON t(a,b)'))
        assert(box.execute('CREATE INDEX s ON t(bucket,a,b)'))
        assert(box.execute('CREATE INDEX sd ON t(bucket DESC,a,b DESC)'))
        assert(box.execute([[INSERT INTO t VALUES(1,1,1,1),(2,1,2,2),
                             (3,1,3,3),(4,2,1,1),(5,2,2,2),(6,2,3,3)]]))
    end, {cg.params.engine})
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        assert(box.execute(
            [[SET SESSION "sql_reverse_unordered_selects"=false]]))
        assert(box.execute('DROP TABLE IF EXISTS v'))
    end)
end)

g.test_numeric_bounds_match_ordinary_search = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local h = require('test.sql-luatest.skip_scan_helpers')
        for _, op in ipairs({'=', '>', '>=', '<', '<='}) do
            for _, value in ipairs({1, 1.0, 1.5, 2.0, 2.5, 4,
                                    decimal.new('1.5'), box.NULL, 'bad'}) do
                for _, reverse in ipairs({false, true}) do
                    assert(box.execute(
                        ('SET SESSION "sql_reverse_unordered_selects"=%s')
                        :format(tostring(reverse))))
                    local sql = ('SELECT id FROM t INDEXED BY %%s ' ..
                                 'WHERE a%s? /* reverse=%s */')
                                :format(op, tostring(reverse))
                    local ordinary, e1 = box.execute(sql:format('i'), {value})
                    local expected = {}
                    if value ~= box.NULL and type(value) ~= 'string' then
                        local n = tonumber(tostring(value))
                        for id = 1, 6 do
                            local a = (id - 1) % 3 + 1
                            if (op == '=' and a == n) or
                               (op == '>' and a > n) or
                               (op == '>=' and a >= n) or
                               (op == '<' and a < n) or
                               (op == '<=' and a <= n) then
                                table.insert(expected, {id})
                            end
                        end
                    end
                    if ordinary and type(value) ~= 'string' then
                        t.assert_equals(h.primary_rows(box.space.T, 'a' .. op ..
                                                       '?', {value}), expected)
                    end
                    for _, index in ipairs({'s', 'sd'}) do
                        local query = sql:format(index)
                        h.assert_search(query, 'ANY(BUCKET) AND A', {value})
                        h.assert_direction(query, box.space.T,
                                           box.space.T.index[index:upper()],
                                           reverse, {value})
                        local skip, e2 = box.execute(query, {value})
                        if ordinary then
                            t.assert(skip, tostring(e2))
                            t.assert_equals(h.sorted(skip.rows),
                                            h.sorted(ordinary.rows), query)
                            if type(value) ~= 'string' then
                                t.assert_equals(skip.rows, expected, query)
                            end
                        else
                            t.assert_equals(skip, nil, query)
                            t.assert_equals(e2.code, e1.code, query)
                        end
                    end
                end
            end
        end
        local result = assert(box.execute([[SELECT a FROM t INDEXED BY s
                                            WHERE a>1.5 AND a<3 ORDER BY id]]))
        t.assert_equals(result.rows, {{2}, {2}})
    end)
end

g.test_late_null_vector_bounds = function(cg)
    cg.server:exec(function()
        local h = require('test.sql-luatest.skip_scan_helpers')
        for _, index in ipairs({'i', 's', 'sd'}) do
            for _, op in ipairs({'>', '>=', '<', '<='}) do
                for _, reverse in ipairs({false, true}) do
                    assert(box.execute(
                        ('SET SESSION "sql_reverse_unordered_selects"=%s')
                        :format(tostring(reverse))))
                    local sql = ('SELECT id FROM t INDEXED BY %s ' ..
                                 'WHERE (a,b)%s(2,NULL) /* reverse=%s */')
                                :format(index, op, tostring(reverse))
                    local expected = op:sub(1, 1) == '>' and {{3}, {6}} or
                                     {{1}, {4}}
                    if index ~= 'i' then
                        -- Mixed ASC/DESC uses A as a bound and filters B.
                        h.assert_search(sql, index == 'sd' and
                                        'ANY(BUCKET) AND A' or
                                        'ANY(BUCKET) AND (A,B)')
                    end
                    t.assert_equals(h.primary_rows(box.space.T,
                                    '(a,b)' .. op .. '(2,NULL)'), expected)
                    h.assert_direction(sql, box.space.T,
                                       box.space.T.index[index:upper()],
                                       reverse)
                    local result, err = box.execute(sql)
                    t.assert(result, tostring(err))
                    t.assert_equals(h.sorted(result.rows), expected, sql)
                end
            end
        end
    end)
end

g.test_inexact_composite_equalities = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local h = require('test.sql-luatest.skip_scan_helpers')
        local function sql(query, params)
            local result, err = box.execute(query, params or {})
            t.assert(result, tostring(err) .. ': ' .. query)
            return result
        end
        sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                            a INTEGER,b INTEGER)]])
        sql('CREATE INDEX i ON v(a,b)')
        sql('CREATE INDEX s ON v(bucket,a,b)')
        sql('CREATE INDEX sd ON v(bucket DESC,a,b DESC)')
        -- A multi-part fixed prefix also needs exact equality after casting.
        sql('CREATE INDEX p ON v(a,b,bucket,id)')
        sql('INSERT INTO v VALUES(1,1,0,3),(2,1,2,1),(3,2,0,3),(4,2,2,1)')
        for _, reverse in ipairs({false, true}) do
            sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                :format(tostring(reverse)))
            for _, case in ipairs({
                {where = 'a=0.5 AND b=1', rows = {}},
                {where = 'a=? AND b=1', params = {0.5}, rows = {}},
                {where = 'a=? AND b=1', params = {decimal.new('0.5')},
                 rows = {}},
                {where = 'a IN (0.5,2) AND b=1', rows = {{2}, {4}}},
                {where = 'a IN (?,2) AND b=1',
                 params = {decimal.new('0.5')}, rows = {{2}, {4}}},
                {where = 'a=? AND b=1', params = {2.0}, rows = {{2}, {4}}},
                {where = 'a=? AND b=1', params = {decimal.new('2')},
                 rows = {{2}, {4}}},
            }) do
                t.assert_equals(h.primary_rows(box.space.V, case.where,
                                               case.params), case.rows)
                for _, index in ipairs({'i', 's', 'sd'}) do
                    local query = ('SELECT id FROM v INDEXED BY %s WHERE %s ' ..
                                   '/* reverse=%s */')
                                  :format(index, case.where, tostring(reverse))
                    h.assert_direction(query, box.space.V,
                                       box.space.V.index[index:upper()],
                                       reverse, case.params)
                    if index ~= 'i' then
                        h.assert_search(query, 'ANY(BUCKET) AND A=? AND B=?',
                                        case.params)
                    end
                    t.assert_equals(h.sorted(sql(query, case.params).rows),
                                    case.rows, query)
                end
            end
            local prefix = [[SELECT id FROM v INDEXED BY p
                             WHERE a=? AND b=1 AND id>0]] ..
                           (' /* prefix reverse=%s */')
                           :format(tostring(reverse))
            h.assert_direction(prefix, box.space.V, box.space.V.index.P,
                               reverse, {0.5})
            t.assert_equals(sql(prefix, {0.5}).rows, {})
        end
    end)
end

g.test_fractional_nested_in_keeps_exact_matches = function(cg)
    cg.server:exec(function()
        local h = require('test.sql-luatest.skip_scan_helpers')
        local decimal = require('decimal')
        local function sql(query, params)
            local result, err = box.execute(query, params or {})
            t.assert(result, tostring(err) .. ': ' .. query)
            return result
        end
        sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                            a INTEGER,b INTEGER)]])
        sql('CREATE INDEX s ON v(bucket,a,b)')
        sql('CREATE INDEX sd ON v(bucket,a DESC,b DESC)')
        sql('INSERT INTO v VALUES(1,1,1,1),(2,1,1,2)')
        for _, reverse in ipairs({false, true}) do
            sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                :format(tostring(reverse)))
            for _, case in ipairs({
                {where = 'a IN (1.5,1) AND b IN (1,2)'},
                {where = 'a IN (?,1) AND b IN (1,2)', params = {1.5}},
                {where = 'a IN (?,1) AND b IN (1,2)',
                 params = {decimal.new('1.5')}},
            }) do
                t.assert_equals(h.primary_rows(box.space.V, case.where,
                                               case.params), {{1}, {2}})
                for _, index in ipairs({'s', 'sd'}) do
                    local tail = ('INDEXED BY %s WHERE %s /* reverse=%s */')
                                 :format(index, case.where, tostring(reverse))
                    local query = 'SELECT id FROM v ' .. tail
                    h.assert_search(query, 'ANY(BUCKET) AND A=? AND B=?',
                                    case.params)
                    h.assert_direction(query, box.space.V,
                                       box.space.V.index[index:upper()],
                                       reverse, case.params)
                    t.assert_equals(h.sorted(sql(query, case.params).rows),
                                    {{1}, {2}})
                    for _, op in ipairs({'DELETE', 'UPDATE'}) do
                        box.begin()
                        query = op == 'DELETE' and 'DELETE FROM v ' .. tail or
                            ('UPDATE v INDEXED BY %s ' ..
                             'SET bucket=bucket+1,b=b+10 ' ..
                             'WHERE %s /* reverse=%s */')
                            :format(index, case.where, tostring(reverse))
                        h.assert_search(query, 'ANY(BUCKET) AND A=? AND B=?',
                                        case.params)
                        h.assert_direction(query, box.space.V,
                                           box.space.V.index[index:upper()],
                                           reverse, case.params)
                        t.assert_equals(sql(query, case.params).row_count, 2)
                        local expected = op == 'DELETE' and {} or
                                         {{1, 2, 1, 11}, {2, 2, 1, 12}}
                        t.assert_equals(sql('SELECT * FROM v ORDER BY id').rows,
                                        expected)
                        box.rollback()
                    end
                end
            end
        end
    end)
end

g.test_inexact_equalities_do_not_modify_rows = function(cg)
    cg.server:exec(function()
        local decimal = require('decimal')
        local checks = require('test.sql-luatest.skip_scan_helpers')
        local function sql(query, params)
            local result, err = box.execute(query, params or {})
            t.assert(result, tostring(err) .. ': ' .. query)
            return result
        end
        sql([[CREATE TABLE v(id INTEGER PRIMARY KEY,bucket INTEGER,
                            a INTEGER,b INTEGER)]])
        sql('CREATE INDEX s ON v(bucket,a,b)')
        sql('CREATE INDEX sd ON v(bucket DESC,a,b DESC)')
        sql('INSERT INTO v VALUES(1,1,0,3),(2,1,2,1)')
        for _, reverse in ipairs({false, true}) do
            sql(('SET SESSION "sql_reverse_unordered_selects"=%s')
                :format(tostring(reverse)))
            for _, index in ipairs({'s', 'sd'}) do
                for _, case in ipairs({
                    {value = '0.5', params = {}},
                    {value = '?', params = {0.5}},
                    {value = '?', params = {decimal.new('0.5')}},
                }) do
                    for _, in_list in ipairs({false, true}) do
                        local predicate = in_list and
                            ('a IN (%s,2) AND b=1'):format(case.value) or
                            ('a=%s AND b=1'):format(case.value)
                        local ids = in_list and {{2}} or {}
                        t.assert_equals(checks.primary_rows(box.space.V,
                                        predicate, case.params), ids)
                        for _, op in ipairs({'UPDATE', 'DELETE'}) do
                            box.begin()
                            local query = op == 'UPDATE' and
                                ('UPDATE v INDEXED BY %s SET bucket=9,b=9 ' ..
                                 'WHERE %s'):format(index, predicate) or
                                ('DELETE FROM v INDEXED BY %s WHERE %s')
                                :format(index, predicate)
                            query = query .. (' /* reverse=%s */')
                                             :format(tostring(reverse))
                            checks.assert_search(query,
                                'ANY(BUCKET) AND A=? AND B=?', case.params)
                            checks.assert_direction(query, box.space.V,
                                box.space.V.index[index:upper()], reverse,
                                case.params)
                            t.assert_equals(sql(query, case.params).row_count,
                                            #ids, query)
                            local expected = {{1, 1, 0, 3}}
                            if not in_list then
                                table.insert(expected, {2, 1, 2, 1})
                            elseif op == 'UPDATE' then
                                table.insert(expected, {2, 9, 2, 9})
                            end
                            local all = 'SELECT * FROM v ORDER BY id'
                            t.assert_equals(sql(all).rows, expected, query)
                            box.rollback()
                        end
                    end
                end
            end
        end
    end)
end
