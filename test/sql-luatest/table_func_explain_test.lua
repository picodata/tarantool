local t = require('luatest')
local server = require('luatest.server')

local g = t.group('table_func_explain')

g.before_all(function(cg)
    cg.server = server:new({alias = 'table-func-explain'})
    cg.server:start()
    cg.server:exec(function()
        box.execute([[SET SESSION "sql_seq_scan" = true]])
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0]])
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

local function explain(cg, query)
    local result = cg.server:exec(function(sql)
        return assert(box.execute([[EXPLAIN (
            analyze {'mode': 'hits', 'round': false},
            graph, opcode, pseudocode) ]] .. sql))
    end, {query})
    local rows, totals = {}, {}
    for _, row in ipairs(result.rows) do
        local named = {}
        for i, meta in ipairs(result.metadata) do
            named[meta.name] = row[i]
        end
        named.name = named.opcode:match('^%s*(.-)%s*$')
        totals[named.name] = (totals[named.name] or 0) + tonumber(named.hits)
        table.insert(rows, named)
    end
    return rows, totals
end

-- Parentheses must not consume the whole dependent group before LIMIT.
g.test_group_limit = function(cg)
    local sources = {
        {'', 'GENERATE_SERIES(1, %d + a.VALUE) b, UNNEST([10]) c'},
        {'', '(GENERATE_SERIES(1, %d + a.VALUE) b ' ..
             'JOIN UNNEST([10]) c ON true)'},
        {'ALL ', '(GENERATE_SERIES(1, %d + a.VALUE) b ' ..
                 'JOIN UNNEST([10]) c ON true)'},
    }
    for _, bound in ipairs({100000, 1000000}) do
        for _, source in ipairs(sources) do
            local query = 'SELECT ' .. source[1] ..
                'a.VALUE, b.VALUE, c.VALUE FROM GENERATE_SERIES(1, 1) a, ' ..
                source[2]:format(bound) .. ' LIMIT 1'
            cg.server:exec(function(sql)
                local stmt = assert(box.prepare(sql))
                for _ = 1, 2 do
                    t.assert_equals(stmt:execute().rows, {{1, 1, 10}})
                end
                stmt:unprepare()
            end, {query})
            local _, totals = explain(cg, query)
            t.assert_equals(totals.ResultRow, 1)
            t.assert_equals(totals.TFuncRewind, 3)
            t.assert_equals(totals.TFuncNext, 0)
            t.assert_equals(totals.OpenTEphemeral, nil)
            t.assert_equals(totals.IdxInsert, nil)
        end
    end
end

-- An outer filter may request more than LIMIT rows from the group.
g.test_group_limit_after_filter = function(cg)
    local query = [[SELECT a.VALUE, b.VALUE, c.VALUE
        FROM GENERATE_SERIES(1, 1) a,
             (GENERATE_SERIES(1, 100000 + a.VALUE) b
              JOIN UNNEST([10]) c ON true)
        WHERE b.VALUE > 3 LIMIT 1]]
    cg.server:exec(function(sql)
        t.assert_equals(box.execute(sql).rows, {{1, 4, 10}})
    end, {query})
    local _, totals = explain(cg, query)
    t.assert_equals(totals.ResultRow, 1)
    t.assert_equals(totals.OpenTEphemeral, nil)
    t.assert_lt(totals.TFuncNext, 100000)
end

g.test_group_restart = function(cg)
    cg.server:exec(function()
        local query = [[SELECT a.VALUE, b.VALUE, c.VALUE
            FROM GENERATE_SERIES(1, 3) a,
                 (GENERATE_SERIES(1, a.VALUE) b
                  JOIN UNNEST([10, 20]) c ON true)
            ORDER BY a.VALUE, b.VALUE, c.VALUE]]
        local expected = {}
        for a = 1, 3 do
            for b = 1, a do
                for _, c in ipairs({10, 20}) do
                    table.insert(expected, {a, b, c})
                end
            end
        end
        local stmt = assert(box.prepare(query))
        for _ = 1, 2 do
            t.assert_equals(stmt:execute().rows, expected)
        end
        stmt:unprepare()
    end)
end

-- Both an empty group and a failed ON condition produce one NULL row.
g.test_group_left_join = function(cg)
    cg.server:exec(function()
        local query = [[SELECT a.VALUE, b.VALUE, c.ORDINALITY
            FROM GENERATE_SERIES(0, 2) a LEFT JOIN
                 (GENERATE_SERIES(1, a.VALUE) b
                  JOIN UNNEST([10]) WITH ORDINALITY c ON true)
                 ON b.VALUE > 1
            ORDER BY a.VALUE, b.VALUE]]
        local stmt = assert(box.prepare(query))
        for _ = 1, 2 do
            t.assert_equals(stmt:execute().rows, {
                {0, box.NULL, box.NULL}, {1, box.NULL, box.NULL}, {2, 2, 1},
            })
        end
        stmt:unprepare()
    end)
end

-- A later group must read the current registers of an earlier coroutine.
g.test_chained_groups = function(cg)
    cg.server:exec(function()
        local query = [[SELECT a.VALUE, b.VALUE, d.VALUE
            FROM GENERATE_SERIES(0, 2) a LEFT JOIN
                 (GENERATE_SERIES(1, a.VALUE) b
                  JOIN UNNEST([10]) c ON true) ON true
            LEFT JOIN
                 (GENERATE_SERIES(1, b.VALUE) d
                  JOIN UNNEST([20]) e ON true) ON true
            ORDER BY a.VALUE, b.VALUE, d.VALUE]]
        local stmt = assert(box.prepare(query))
        for _ = 1, 2 do
            t.assert_equals(stmt:execute().rows, {
                {0, box.NULL, box.NULL}, {1, 1, 1},
                {2, 1, 1}, {2, 2, 1}, {2, 2, 2},
            })
        end
        stmt:unprepare()
    end)
end

g.test_iterator_graph_and_pseudocode = function(cg)
    for _, case in ipairs({
        {'SELECT * FROM GENERATE_SERIES(1, 3)', 1},
        {'SELECT a.VALUE, b.VALUE FROM GENERATE_SERIES(1, 2) a, ' ..
         'GENERATE_SERIES(1, a.VALUE) b', 2},
    }) do
        local rows = explain(cg, case[1])
        local addresses, rewinds, nexts = {}, {}, {}
        for _, row in ipairs(rows) do
            addresses[row.addr] = row
            if row.name == 'TFuncRewind' then
                rewinds[row.p1] = row
            elseif row.name == 'TFuncNext' then
                nexts[row.p1] = row
            end
        end
        local loops, max_depth = 0, 0
        for cursor, rewind in pairs(rewinds) do
            local next_row = nexts[cursor]
            t.assert(next_row)
            loops = loops + 1
            t.assert_str_contains(rewind.pseudocode, '.first(); IF empty')
            t.assert_str_contains(next_row.pseudocode, '.next(); IF found')
            for _, jump in ipairs({rewind, next_row}) do
                t.assert_str_contains(jump.pseudocode, 'GOTO ' .. jump.p2)
                t.assert(jump.graph:match('[<X]%s*$'))
                t.assert(addresses[jump.p2].graph:match('[>X]%s*$'))
            end
            t.assert_gt(rewind.p2, next_row.addr)
            t.assert_gt(next_row.p2, rewind.addr)
            t.assert_lt(next_row.p2, next_row.addr)
            local body = addresses[next_row.p2]
            local depth = #body.pseudocode:match('^%s*')
            t.assert_equals(depth,
                            #next_row.pseudocode:match('^%s*') + 2)
            max_depth = math.max(max_depth, depth)
        end
        t.assert_equals(loops, case[2])
        t.assert_equals(max_depth, 2 * case[2])
    end
end

g.test_exact_iterator_counts = function(cg)
    for _, case in ipairs({
        {'SELECT * FROM GENERATE_SERIES(1, 3)', 1, 3, 3},
        {'SELECT * FROM GENERATE_SERIES(1, 3) LIMIT 1', 1, 0, 1},
        {'SELECT * FROM GENERATE_SERIES(3, 1)', 1, 0, 0},
        {'SELECT * FROM GENERATE_SERIES(1, 3) LIMIT 0', 0, 0, 0},
    }) do
        local _, totals = explain(cg, case[1])
        t.assert_equals(totals.TFuncRewind, case[2])
        t.assert_equals(totals.TFuncNext, case[3])
        t.assert_equals(totals.ResultRow, case[4])
    end
end

g.test_prepared_explain_runs = function(cg)
    cg.server:exec(function()
        for _, case in ipairs({
            {'', {TFuncRewind = 3, TFuncNext = 9, ResultRow = 9}},
            {' LIMIT 1', {TFuncRewind = 3, TFuncNext = 0, ResultRow = 3}},
        }) do
            local stmt = assert(box.prepare([[EXPLAIN (
                analyze {'mode': 'hits', 'round': false, 'runs': 3}, opcode)
                SELECT * FROM GENERATE_SERIES(1, 3)]] .. case[1]))
            for _ = 1, 2 do
                local result = assert(stmt:execute())
                local columns = {}
                for i, meta in ipairs(result.metadata) do
                    columns[meta.name] = i
                end
                local counts = {}
                for _, row in ipairs(result.rows) do
                    local name = row[columns.opcode]:match('^%s*(.-)%s*$')
                    if case[2][name] ~= nil then
                        counts[name] = (counts[name] or 0) +
                            tonumber(row[columns.hits])
                    end
                end
                t.assert_equals(counts, case[2])
            end
            stmt:unprepare()
        end
    end)
end
