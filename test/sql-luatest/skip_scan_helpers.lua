local t = require('luatest')

local M = {}

function M.sorted(rows)
    table.sort(rows, function(a, b)
        for i = 1, #a do
            if a[i] ~= b[i] then
                if a[i] == box.NULL then return true end
                if b[i] == box.NULL then return false end
                return a[i] < b[i]
            end
        end
        return false
    end)
    return rows
end

-- Identify the named space/index cursor, not an IN or sorting cursor.
function M.assert_direction(sql, space, index, reverse, params)
    local result, err = box.execute('EXPLAIN (opcode) ' .. sql, params or {})
    t.assert(result, tostring(err))
    local spaces, cursor = {}, nil
    for _, row in ipairs(result.rows) do
        if row[2] == 'OpenSpace' then
            spaces[row[3]] = row[4]
        elseif row[2] == 'IteratorOpen' and
               spaces[row[5]] == space.id and row[4] == index.id then
            t.assert_equals(cursor, nil, 'ambiguous index cursor: ' .. sql)
            cursor = row[3]
        end
    end
    t.assert_not_equals(cursor, nil, 'missing index cursor: ' .. sql)
    local forward, backward = false, false
    for _, row in ipairs(result.rows) do
        if row[3] == cursor then
            forward = forward or row[2] == 'Next'
            backward = backward or row[2] == 'Prev'
        end
    end
    t.assert_equals({forward, backward}, {not reverse, reverse}, sql)
    return result.rows, cursor
end

function M.plan(sql, params)
    local result, err = box.execute('EXPLAIN QUERY PLAN ' .. sql, params or {})
    t.assert(result, tostring(err))
    local rows = {}
    for _, row in ipairs(result.rows) do table.insert(rows, row[4]) end
    return table.concat(rows, '\n')
end

function M.assert_search(sql, key, params)
    local plan = M.plan(sql, params)
    t.assert_str_contains(plan, 'SEARCH TABLE')
    t.assert_str_contains(plan, key)
end

-- An independent filter, with neither a secondary search nor skip-scan.
function M.primary_rows(space, predicate, params)
    local sql = ('SELECT id FROM "%s" INDEXED BY "%s" WHERE %s')
                :format(space.name, space.index[0].name, predicate)
    t.assert_str_contains(M.plan(sql, params), 'SCAN TABLE')
    return M.sorted(assert(box.execute(sql, params or {})).rows)
end

return M
