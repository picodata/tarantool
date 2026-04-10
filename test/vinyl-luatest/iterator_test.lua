local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then
            box.space.test:drop()
        end
    end)
end)

--
-- Randomized iterator test on a multi-page, multi-LCP-group run.
-- Inserts sequential keys 1..N with a payload big enough to
-- produce ~40 pages (2-3 LCP groups at LCP_GROUP_MAX=16) when
-- page_size is small.  Then runs 1000 random (iterator, key)
-- queries and compares the first returned tuple against the
-- trivially computed expected result.
--
g.test_random_iterator_on_multi_group_run = function(cg)
    local N = 200
    cg.server:exec(function(N)
        local seed = math.floor(require('fiber').time() * 1e6)
        math.randomseed(seed)
        local payload = string.rep('x', 50)
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {page_size = 256})
        for i = 1, N do
            s:replace{i, payload}
        end
        box.snapshot()

        local itypes = {'GE', 'GT', 'LE', 'LT', 'EQ', 'REQ'}
        for _ = 1, 1000 do
            local itype = itypes[math.random(#itypes)]
            local k = math.random(0, N + 1)
            local result = s:select({k}, {iterator = itype, limit = 1})
            local first = result[1]

            local exp_key
            if itype == 'GE' then
                if k <= N then exp_key = math.max(k, 1) end
            elseif itype == 'GT' then
                if k < N then exp_key = math.max(k + 1, 1) end
            elseif itype == 'LE' then
                if k >= 1 then exp_key = math.min(k, N) end
            elseif itype == 'LT' then
                if k > 1 then exp_key = math.min(k - 1, N) end
            elseif itype == 'EQ' or itype == 'REQ' then
                if k >= 1 and k <= N then exp_key = k end
            end

            if exp_key == nil then
                t.assert_equals(first, nil,
                    ('seed=%d %s(%d): expected nil'):format(seed, itype, k))
            else
                t.assert_equals(first[1], exp_key,
                    ('seed=%d %s(%d)'):format(seed, itype, k))
            end
        end
    end, {N})
end

--
-- Same randomized approach on a non-unique secondary index with
-- random-sized duplicate groups.  Each SK value repeats between
-- 1 and 48 times, so some groups fit in a single page while
-- others span multiple LCP groups.  A pre-filled Lua table
-- serves as the oracle for expected results.
--
g.test_random_iterator_on_secondary_with_duplicates = function(cg)
    cg.server:exec(function()
        local seed = math.floor(require('fiber').time() * 1e6)
        math.randomseed(seed)
        local payload = string.rep('x', 50)
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {page_size = 256})
        s:create_index('sk', {parts = {{field = 2, type = 'unsigned'}},
                              unique = false, page_size = 256})

        -- Build data with random-sized duplicate groups and
        -- fill an oracle table sorted by (sk_val, pk).
        local oracle = {}
        local pk = 1
        local sk_val = 0
        local N = 500
        while pk <= N do
            local count = math.random(1, 48)
            for _ = 1, count do
                if pk > N then break end
                s:replace{pk, sk_val, payload}
                table.insert(oracle, {pk, sk_val})
                pk = pk + 1
            end
            sk_val = sk_val + 1
        end
        local max_sk = oracle[#oracle][2]
        box.snapshot()

        -- Oracle search: scan the sorted table for the first
        -- (or last) row matching the iterator predicate.
        local function oracle_search(itype, k)
            if itype == 'GE' then
                for _, row in ipairs(oracle) do
                    if row[2] >= k then return row end
                end
            elseif itype == 'GT' then
                for _, row in ipairs(oracle) do
                    if row[2] > k then return row end
                end
            elseif itype == 'LE' then
                for i = #oracle, 1, -1 do
                    if oracle[i][2] <= k then return oracle[i] end
                end
            elseif itype == 'LT' then
                for i = #oracle, 1, -1 do
                    if oracle[i][2] < k then return oracle[i] end
                end
            elseif itype == 'EQ' then
                for _, row in ipairs(oracle) do
                    if row[2] == k then return row end
                end
            elseif itype == 'REQ' then
                for i = #oracle, 1, -1 do
                    if oracle[i][2] == k then return oracle[i] end
                end
            end
            return nil
        end

        local itypes = {'GE', 'GT', 'LE', 'LT', 'EQ', 'REQ'}
        for _ = 1, 1000 do
            local itype = itypes[math.random(#itypes)]
            local k = math.random(0, max_sk + 1)
            local result = s.index.sk:select({k},
                {iterator = itype, limit = 1})
            local first = result[1]
            local exp = oracle_search(itype, k)

            local label = ('seed=%d %s(%d) on sk'):format(seed, itype, k)
            if exp == nil then
                t.assert_equals(first, nil, label .. ': expected nil')
            else
                t.assert_equals(first[1], exp[1], label .. ': pk')
                t.assert_equals(first[2], exp[2], label .. ': sk')
            end
        end
    end)
end
