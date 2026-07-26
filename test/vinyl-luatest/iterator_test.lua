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

--
-- Multi-part (integer, datetime, integer) PK populated with
-- fully random data: the datetime column gives the page index
-- a cmp_def comparator that diverges from byte order. Test
-- should catch any non monotonic collation issue.
--
g.before_test('test_random_iterator_on_multi_part_datetime_pk', function(cg)
    cg.saved_vinyl_cache = cg.server:exec(function()
        local saved = box.cfg.vinyl_cache
        -- Force each seek through the run reader.
        box.cfg{vinyl_cache = 0}
        return saved
    end)
end)

g.after_test('test_random_iterator_on_multi_part_datetime_pk', function(cg)
    cg.server:exec(function(saved)
        box.cfg{vinyl_cache = saved}
    end, {cg.saved_vinyl_cache})
end)

g.test_random_iterator_on_multi_part_datetime_pk = function(cg)
    cg.server:exec(function()
        local datetime = require('datetime')
        local digest = require('digest')

        local seed = math.floor(require('fiber').time() * 1e6)
        math.randomseed(seed)

        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:format{
            {name = 'c1',  type = 'integer'},
            {name = 'c2',  type = 'datetime'},
            {name = 'c3',  type = 'integer'},
            {name = 'pad', type = 'string'},
        }
        -- Every row gets its own page because of string padding.
        s:create_index('pk', {
            parts = {{1, 'integer'}, {2, 'datetime'}, {3, 'integer'}},
            page_size = 256,
        })

        local N = 2000
        -- Datetime is stored little-endian, so byte 0 of the
        -- encoded value is the LSB of seconds -- the byte the
        -- LCP-of-first-and-last shortcut gets wrong. Stepping in
        -- 2-hour strides keeps 7200 mod 256 == 32, so the LSB
        -- cycles through only 8 of 256 values -- lifting the
        -- bytewise-LCP collision between LCP-group endpoints
        -- from ~1/256 (uniform random) to ~1/8 -- enough for
        -- N=2000 to catch the bug reliably.
        local TS_BASE = 1672531200  -- 2023-01-01 00:00:00 UTC
        local pad = digest.urandom(300)
        local oracle = {}
        local seen = {}
        while #oracle < N do
            local c1 = math.random(1, 10)
            local ts = TS_BASE + 7200 * math.random(0, 99)
            local c3 = math.random(1, 10)
            local skey = c1 .. ':' .. ts .. ':' .. c3
            if not seen[skey] then
                seen[skey] = true
                local c2 = datetime.new{timestamp = ts}
                s:insert{c1, c2, c3, pad}
                table.insert(oracle, {c1, c2, c3})
            end
        end
        box.snapshot()
        t.assert_equals(s.index.pk:stat().disk.pages, N)

        local function cmp(a, b)
            if a[1] ~= b[1] then return a[1] < b[1] and -1 or 1 end
            if a[2] ~= b[2] then return a[2] < b[2] and -1 or 1 end
            if a[3] ~= b[3] then return a[3] < b[3] and -1 or 1 end
            return 0
        end
        table.sort(oracle, function(a, b) return cmp(a, b) < 0 end)

        local function lower_bound(seek)
            local lo, hi = 1, #oracle + 1
            while lo < hi do
                local mid = math.floor((lo + hi) / 2)
                if cmp(oracle[mid], seek) < 0 then
                    lo = mid + 1
                else
                    hi = mid
                end
            end
            return lo
        end

        local function upper_bound(seek)
            local lo, hi = 1, #oracle + 1
            while lo < hi do
                local mid = math.floor((lo + hi) / 2)
                if cmp(oracle[mid], seek) <= 0 then
                    lo = mid + 1
                else
                    hi = mid
                end
            end
            return lo
        end

        local function oracle_search(itype, seek)
            if itype == 'GE' then
                return oracle[lower_bound(seek)]
            elseif itype == 'GT' then
                return oracle[upper_bound(seek)]
            elseif itype == 'LE' then
                return oracle[upper_bound(seek) - 1]
            elseif itype == 'LT' then
                return oracle[lower_bound(seek) - 1]
            elseif itype == 'EQ' or itype == 'REQ' then
                local i = lower_bound(seek)
                if oracle[i] ~= nil and cmp(oracle[i], seek) == 0 then
                    return oracle[i]
                end
                return nil
            end
        end

        local itypes = {'GE', 'GT', 'LE', 'LT', 'EQ', 'REQ'}
        for _ = 1, 1000 do
            local itype = itypes[math.random(#itypes)]
            local seek
            -- Half of the queries use oracle keys.
            if math.random(2) == 1 then
                seek = oracle[math.random(#oracle)]
            else
                local ts = TS_BASE + 7200 * math.random(0, 99)
                seek = {math.random(1, 10),
                        datetime.new{timestamp = ts},
                        math.random(1, 10)}
            end

            local result = s:select(seek, {iterator = itype, limit = 1})
            local first = result[1]
            local exp = oracle_search(itype, seek)
            local label = ('seed=%d %s'):format(seed, itype)
            if exp == nil then
                t.assert_equals(first, nil, label .. ': expected nil')
            else
                t.assert_equals(first[1], exp[1], label .. ': c1')
                t.assert_equals(first[2], exp[2], label .. ': c2')
                t.assert_equals(first[3], exp[3], label .. ': c3')
            end
        end
    end)
end

--
-- A reverse iterator with a partial key must return every row
-- matching the key, even when the matching rows span several
-- ranges, i.e. a range boundary falls inside the group of rows
-- sharing the key prefix. A reverse scan enters the range tree
-- at the last matching range and walks down; if it enters at
-- the first one instead, the rows in the later ranges are lost.
--
g.test_reverse_across_range_split = function(cg)
    cg.server:exec(function()
        local s = box.schema.create_space('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {{1, 'unsigned'}, {2, 'unsigned'}},
            range_size = 16 * 1024,
            page_size = 1024,
            run_count_per_level = 1,
        })
        local pad = string.rep('x', 400)
        for k = 1, 4 do
            for i = 1, 50 do
                s:insert({k, i, pad})
            end
            box.snapshot()
        end
        -- Wait for compaction to split the index into enough
        -- ranges that at least one boundary falls inside a
        -- 50-row key group.
        t.helpers.retrying({timeout = 60}, function()
            t.assert_ge(s.index.pk:stat().range_count, 4)
        end)
    end)

    local function check(cg)
        cg.server:exec(function()
            local s = box.space.test
            for k = 1, 4 do
                local forward = s:select({k}, {iterator = 'EQ'})
                t.assert_equals(#forward, 50)
                local reverse = s:select({k}, {iterator = 'REQ'})
                t.assert_equals(#reverse, 50)
                for i = 1, 50 do
                    t.assert_equals(reverse[i], forward[51 - i])
                end
                -- LE on the partial key starts after the whole
                -- group: the first row it returns is the group's
                -- last one.
                local le = s:select({k}, {iterator = 'LE', limit = 1})
                t.assert_equals(le[1], forward[50])
                -- LT on the partial key starts before the whole
                -- group: the first row it returns is the previous
                -- group's last one, if any.
                local lt = s:select({k}, {iterator = 'LT', limit = 1})
                if k > 1 then
                    t.assert_equals(lt[1][1], k - 1)
                    t.assert_equals(lt[1][2], 50)
                else
                    t.assert_equals(#lt, 0)
                end
            end
            local all = s:select({}, {iterator = 'LE'})
            t.assert_equals(#all, 200)
        end)
    end

    check(cg)
    -- Range bounds, including the split keys, travel through the
    -- metadata log on restart. Recheck on the recovered tree.
    cg.server:restart()
    check(cg)
end

--
-- A reverse scan with a partial key must not return tuples
-- matching the key prefix: LT {1} excludes every {1, *}. The
-- result must hold when the range tree is split at a boundary
-- extending the searched prefix, so that a slice's upper bound
-- ties with the search key on its common parts and the seek
-- is wrongly clamped to the bound.
--
g.test_reverse_partial_scan_after_split = function(cg)
    cg.server:exec(function()
        box.cfg{log_level = 'verbose'}
        local s = box.schema.space.create('test', {engine = 'vinyl'})
        s:create_index('pk', {
            parts = {{1, 'unsigned'}, {2, 'unsigned'}},
            range_size = 4 * 1024,
            page_size = 1024,
            run_count_per_level = 1,
        })
        local pad = string.rep('x', 256)
        s:replace{0, 1, pad}
        for _ = 1, 5 do
            for i = 1, 500 do s:replace{1, i, pad} end
            box.snapshot()
        end
        t.helpers.retrying({timeout = 120}, function()
            t.assert_ge(s.index.pk:stat().range_count, 2)
        end)
        -- A seek wrongly clamped to a slice bound can only
        -- return foreign rows while the slice's run physically
        -- extends past the bound: after a dump lands one run
        -- spanning all the split ranges, until the per-range
        -- compactions rewrite it into per-range runs. Make the
        -- state permanent instead of racing those compactions:
        -- raise run_count_per_level out of reach first, then
        -- dump, so the dump triggers no compaction at all. An
        -- option alter must not rebuild the index: a rebuild
        -- would start over with a single range.
        s.index.pk:alter({run_count_per_level = 10})
        t.assert_ge(s.index.pk:stat().range_count, 2)
        for i = 1, 500 do s:replace{1, i, pad} end
        box.snapshot()
        box.cfg{log_level = 'info'}
    end)

    -- Read the actual split boundary from the log instead of
    -- assuming where the split lands: the scenario needs a
    -- boundary extending the searched prefix, and a layout
    -- change moving the boundary must fail the test loudly
    -- rather than degrade it into a trivial pass. Any split
    -- key works: every one bounds some range.
    local split_key = cg.server:grep_log(
        'split range .* by key (%[%d+, %d+%])', 1024 * 1024)
    t.assert_is_not(split_key, nil)
    local b1, b2 = string.match(split_key, '%[(%d+), (%d+)%]')
    b1, b2 = tonumber(b1), tonumber(b2)
    -- The boundary must extend the prefix past its first key:
    -- a seek wrongly clamped to a {1, 1} boundary would return
    -- a correct result by accident.
    t.assert_equals(b1, 1)
    t.assert_ge(b2, 2)

    cg.server:exec(function(b1, b2)
        local s = box.space.test
        -- LT on the boundary's prefix must skip the whole
        -- group, entering below every {1, *} bound.
        t.assert_equals(s:select({b1}, {iterator = 'LT'}), {s:get{0, 1}})
        t.assert_equals(s:select({b1 - 1}, {iterator = 'GT'}),
                        s:select({b1}, {iterator = 'GE'}))
        -- LT on the exact boundary lands on its predecessor,
        -- the last key of the range below the split.
        local prev = s:select({b1, b2}, {iterator = 'LT', limit = 1})[1]
        t.assert_equals({prev[1], prev[2]}, {b1, b2 - 1})
    end, {b1, b2})
end
