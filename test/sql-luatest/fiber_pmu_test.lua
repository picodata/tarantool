local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'fiber-pmu'})
    g.server:start()
    g.server:exec(function()
        local ffi = require('ffi')
        ffi.cdef([[
            void cord_pmu_start(void);
            void cord_pmu_stop(void);
            size_t fiber_pmu_read(const struct fiber *fiber,
                                  uint64_t *values, size_t count);
            struct fiber *fiber_find(uint64_t fid);
        ]])
        -- The values of enum fiber_pmu_counter.
        local names = {'instructions', 'opcodes', 'read', 'written',
                       'returned'}
        ffi.C.cord_pmu_start()
        -- Returns the counters of a fiber, the current one by default.
        local function pmu(fid)
            local f = fid ~= nil and ffi.C.fiber_find(fid) or nil
            local values = ffi.new('uint64_t[?]', #names)
            t.assert_equals(ffi.C.fiber_pmu_read(f, values, #names), #names)
            local res = {}
            for i = 1, #names do
                res[names[i]] = tonumber(values[i - 1])
            end
            return res
        end
        rawset(_G, 'pmu', pmu)
        -- Runs a function and returns the counters that it adds, without
        -- the instructions.
        rawset(_G, 'delta', function(f)
            local before = pmu()
            f()
            local after = pmu()
            local res = {}
            for i = 2, #names do
                res[names[i]] = after[names[i]] - before[names[i]]
            end
            return res
        end)
        -- Runs an SQL statement, checks it and returns the counters that
        -- it adds.
        rawset(_G, 'sql_delta', function(sql)
            return _G.delta(function()
                local _, err = box.execute(sql)
                t.assert_equals(err, nil, sql)
            end)
        end)
        box.execute([[CREATE TABLE t (a INT PRIMARY KEY, b INT);]])
        for i = 1, 10 do
            box.space.T:insert({i, i % 3})
        end
    end)
end)

g.after_all(function()
    g.server:drop()
end)

-- Check the rows that SQL queries read and return. The rows of the
-- ephemeral space of ORDER BY are not counted.
g.test_sql_select = function()
    g.server:exec(function()
        local d = _G.sql_delta([[SELECT * FROM t;]])
        t.assert_equals({d.read, d.returned, d.written}, {10, 10, 0})
        d = _G.sql_delta([[SELECT * FROM t WHERE a = 3;]])
        t.assert_equals({d.read, d.returned, d.written}, {1, 1, 0})
        d = _G.sql_delta([[SELECT b FROM t ORDER BY b DESC LIMIT 3;]])
        t.assert_equals({d.read, d.returned, d.written}, {10, 3, 0})
        d = _G.sql_delta([[SELECT * FROM t WHERE a > 100;]])
        t.assert_equals({d.read, d.returned, d.written}, {0, 0, 0})
    end)
end

-- Check the rows that SQL statements write. A delete that finds no row
-- is not counted.
g.test_sql_dml = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE w (a INT PRIMARY KEY, b INT);]])
        local d = _G.sql_delta([[INSERT INTO w VALUES (1, 1), (2, 2), (3, 3);]])
        t.assert_equals({d.written, d.returned}, {3, 0})
        -- The scan reads the rows 1, 2 and 3, and stops at 3. Then the
        -- update finds each of the 2 rows by its key again.
        d = _G.sql_delta([[UPDATE w SET b = 0 WHERE a < 3;]])
        t.assert_equals({d.read, d.written}, {5, 2})
        d = _G.sql_delta([[DELETE FROM w WHERE a = 100;]])
        t.assert_equals({d.read, d.written}, {0, 0})
        d = _G.sql_delta([[DELETE FROM w;]])
        t.assert_equals({d.read, d.written}, {3, 3})
        box.execute([[DROP TABLE w;]])
    end)
end

-- Check the opcodes of SQL statements: the same statement always has the
-- same count, a better plan has a smaller count.
g.test_sql_opcodes = function()
    g.server:exec(function()
        local scan = _G.sql_delta([[SELECT * FROM t WHERE b = 1;]]).opcodes
        t.assert_gt(scan, 0)
        t.assert_equals(_G.sql_delta([[SELECT * FROM t WHERE b = 1;]]).opcodes,
                        scan)
        local seek = _G.sql_delta([[SELECT * FROM t WHERE a = 1;]]).opcodes
        t.assert_lt(seek, scan)
    end)
end

-- Check that the rows of EXPLAIN and EXPLAIN ANALYZE are not counted as
-- returned. EXPLAIN does not run the statement.
g.test_sql_explain = function()
    g.server:exec(function()
        local d = _G.sql_delta([[EXPLAIN SELECT * FROM t;]])
        t.assert_equals(d, {opcodes = 0, read = 0, written = 0, returned = 0})
        d = _G.sql_delta([[EXPLAIN (ANALYZE {'mode': 'hits'})
                           SELECT * FROM t;]])
        t.assert_equals({d.read, d.returned}, {10, 0})
        t.assert_gt(d.opcodes, 0)
    end)
end

-- Check the rows that the box API reads and writes. It does not run
-- opcodes and does not return SQL rows.
g.test_box_api = function()
    g.server:exec(function()
        local s = box.space.T
        local function rw(f)
            local d = _G.delta(f)
            t.assert_equals({d.opcodes, d.returned}, {0, 0})
            return {d.read, d.written}
        end
        t.assert_equals(rw(function() s:get(1) end), {1, 0})
        t.assert_equals(rw(function() s:get(100) end), {0, 0})
        t.assert_equals(rw(function() s.index[0]:min() end), {1, 0})
        t.assert_equals(rw(function() s.index[0]:max() end), {1, 0})
        -- The rows that select skips because of the offset are read.
        local opts = {offset = 1, limit = 2}
        t.assert_equals(rw(function() s:select({}, opts) end), {3, 0})
        t.assert_equals(rw(function() for _ in s:pairs() do end end), {10, 0})
        t.assert_equals(rw(function() s:insert({11, 0}) end), {0, 1})
        t.assert_equals(rw(function() s:replace({11, 1}) end), {0, 1})
        t.assert_equals(rw(function() s:update(11, {{'=', 2, 2}}) end), {0, 1})
        t.assert_equals(rw(function() s:update(100, {{'=', 2, 2}}) end),
                        {0, 0})
        t.assert_equals(rw(function() s:upsert({11, 0}, {{'+', 2, 1}}) end),
                        {0, 1})
        t.assert_equals(rw(function() s:delete(11) end), {0, 1})
        t.assert_equals(rw(function() s:delete(100) end), {0, 0})
    end)
end

-- Check that another fiber sees the counters of a statement that is
-- suspended in the middle, not only after the statement returns a row.
g.test_visible_during_yield = function()
    g.server:exec(function()
        local fiber = require('fiber')
        box.schema.func.create('NAP', {
            language = 'LUA',
            body = [[function(a) require('fiber').yield() return a end]],
            param_list = {'integer'},
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        local fid = fiber.self():id()
        local before = _G.pmu()
        local seen
        fiber.new(function() seen = _G.pmu(fid) end)
        local _, err = box.execute([[SELECT nap(a) FROM t WHERE a = 1;]])
        t.assert_equals(err, nil)
        local after = _G.pmu()
        t.assert_equals(seen.read - before.read, 1)
        t.assert_gt(seen.opcodes - before.opcodes, 0)
        t.assert_lt(seen.opcodes, after.opcodes)
        t.assert_equals(seen.returned - before.returned, 0)
        t.assert_equals(after.returned - before.returned, 1)
        box.schema.func.drop('NAP')
    end)
end

-- Check that the opcodes of an SQL statement that a function of another
-- SQL statement runs are counted once.
g.test_nested_statements = function()
    g.server:exec(function()
        local function create(name, body)
            box.schema.func.create(name, {
                language = 'LUA',
                body = body,
                param_list = {'integer'},
                returns = 'integer',
                exports = {'LUA', 'SQL'},
            })
        end
        create('PLAIN', [[function(a) return a end]])
        create('NESTED', [[function(a)
            return box.execute('SELECT COUNT(*) FROM t;').rows[1][1]
        end]])
        local outer = _G.sql_delta([[SELECT plain(a) FROM t WHERE a = 1;]])
        local inner = _G.sql_delta([[SELECT COUNT(*) FROM t;]])
        local nested = _G.sql_delta([[SELECT nested(a) FROM t WHERE a = 1;]])
        t.assert_gt(inner.opcodes, 0)
        t.assert_equals(nested.opcodes, outer.opcodes + inner.opcodes)
        t.assert_equals(nested.returned, outer.returned + inner.returned)
        box.schema.func.drop('PLAIN')
        box.schema.func.drop('NESTED')
    end)
end

-- Check that the counters do not count while they are stopped.
g.test_stop = function()
    g.server:exec(function()
        local ffi = require('ffi')
        ffi.C.cord_pmu_stop()
        local delta = _G.sql_delta([[SELECT * FROM t;]])
        t.assert_equals(delta, {opcodes = 0, read = 0, written = 0,
                                returned = 0})
        ffi.C.cord_pmu_start()
        t.assert_equals(_G.sql_delta([[SELECT * FROM t;]]).read, 10)
    end)
end
