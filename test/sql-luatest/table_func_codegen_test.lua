local t = require('luatest')
local server = require('luatest.server')

local g = t.group('table_func_codegen')

g.before_all(function(cg)
    cg.server = server:new({alias = 'table-func-codegen'})
    cg.server:start()
    cg.server:exec(function()
        assert(box.execute([[SET SESSION "sql_seq_scan" = true]]))
        assert(box.execute('CREATE TABLE tf_main' ..
                           '(id INT PRIMARY KEY, n INT, x INT)'))
        assert(box.execute('CREATE INDEX tf_n ON tf_main(n)'))
        assert(box.execute('INSERT INTO tf_main VALUES(1,1,1),(2,2,2)'))
        assert(box.execute('CREATE TABLE tf_source' ..
                           '(id INT PRIMARY KEY, k INT)'))
        assert(box.execute('CREATE INDEX tf_k ON tf_source(k)'))
        assert(box.execute('INSERT INTO tf_source VALUES(1,1),(2,2)'))
        box.schema.func.create('TF_COUNTER', {
            language = 'Lua', returns = 'integer', exports = {'SQL'},
            body = [[function()
                _G.tf_calls = _G.tf_calls + 1
                return _G.tf_calls
            end]],
        })
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

local function check(cg, first_id, membership)
    cg.server:exec(function(id, is_in)
        for _, source in ipairs({'tf_source s',
                                  'tf_source s INDEXED BY tf_k'}) do
            for _, nested in ipairs({false, true}) do
                local group = '(GENERATE_SERIES(s.K,s.K) g ' ..
                              'JOIN GENERATE_SERIES(1,1) h ON true)'
                if nested then
                    group = '(' .. group ..
                            ' JOIN GENERATE_SERIES(1,1) j ON true)'
                end
                local condition = is_in and 's.K > 0' or 's.ID=t.ID'
                local subquery = 'SELECT g.VALUE FROM ' .. source .. ', ' ..
                                 group .. ' WHERE ' .. condition
                local operator = is_in and ' IN ' or ' = '
                local query = 'SELECT t.ID FROM tf_main t WHERE ' ..
                              '(t.ID=' .. id .. ' OR t.N=2) AND t.X' ..
                              operator .. '(' .. subquery .. ') ORDER BY t.ID'
                local plan = assert(box.execute('EXPLAIN QUERY PLAN ' .. query))
                local scans, secondary = 0, false
                for _, row in ipairs(plan.rows) do
                    if row[4]:find('SEARCH TABLE TF_MAIN', 1, true) then
                        scans = scans + 1
                        secondary = secondary or row[4]:find('TF_N', 1, true)
                    end
                end
                t.assert_equals(scans, 2)
                t.assert(secondary)
                local ops = assert(box.execute('EXPLAIN (opcode) ' .. query))
                local coroutine_found = false
                for _, row in ipairs(ops.rows) do
                    if row[2]:match('^%s*(.-)%s*$') == 'InitCoroutine' then
                        coroutine_found = true
                    end
                end
                t.assert(coroutine_found)
                local stmt = assert(box.prepare(query))
                local expected = id == 1 and {{1}, {2}} or {{2}}
                for _ = 1, 2 do
                    t.assert_equals(stmt:execute().rows, expected)
                end
                stmt:unprepare()
            end
        end
    end, {first_id, membership})
end

g.test_first_or_branch_is_empty = function(cg)
    check(cg, 10, false)
end

g.test_both_or_branches_execute = function(cg)
    check(cg, 1, false)
end

g.test_in_subquery_in_or_branches = function(cg)
    check(cg, 10, true)
    check(cg, 1, true)
end

g.test_argument_initialization_in_each_generation = function(cg)
    cg.server:exec(function()
        for _, cached in ipairs({false, true}) do
            local argument = cached and '(SELECT TF_COUNTER())' or
                             'TF_COUNTER()'
            local query = 'SELECT t.ID FROM tf_main t WHERE ' ..
                '(t.ID=1 OR t.N=2) AND t.X=(SELECT g.VALUE + 0 * u.VALUE ' ..
                'FROM tf_source s, (GENERATE_SERIES(s.K,s.K) g ' ..
                'JOIN UNNEST([' .. argument .. ']) u ON true) ' ..
                'WHERE s.ID=t.ID) ORDER BY t.ID'
            rawset(_G, 'tf_calls', 0)
            local stmt = assert(box.prepare(query))
            t.assert_equals(_G.tf_calls, 0)
            for run = 1, 2 do
                t.assert_equals(stmt:execute().rows, {{1}, {2}})
                t.assert_equals(_G.tf_calls, run * (cached and 1 or 2))
            end
            stmt:unprepare()
        end
        rawset(_G, 'tf_calls', nil)
    end)
end
