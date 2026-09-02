local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a STRING,
                                      b STRING);]])
        box.execute([[INSERT INTO t VALUES (1, 'x', 'y'), (2, 'p', 'q');]])
    end)
end)

-- Server:stop() fails on any LeakSanitizer report in the instance stderr.
-- Until the instance shutdown is complete (see the lj_BC_FUNCC comment in
-- asan/lsan.supp), an ASAN build running with the SQL LSan profile reports
-- unrelated leaks as well, so only the SQL ones are checked here.
g.after_all(function()
    local ok, err = pcall(g.server.stop, g.server)
    if ok then
        return
    end
    err = tostring(err)
    if not err:find('Memory leak during process execution', 1, true) then
        error(err)
    end
    g.server:save_artifacts()
    t.assert_not_str_contains(err, 'src/box/sql/', false,
                              'LSan reported a leak in SQL')
end)

-- sqlWhereBegin() allocates WhereInfo before updateAccumulator() emits the
-- bytecode of the aggregates. MAX() and MIN() need a collation for their
-- argument, and a concatenation of two operands with different explicit
-- collations has none, so the parse is aborted right there. sqlSelect() used
-- to return through select_end without calling sqlWhereEnd().
g.test_max_with_illegal_collation_mix = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res, err = box.execute(
                [[SELECT max(a COLLATE "binary" || b COLLATE "unicode")
                  FROM t;]])
            t.assert_equals(res, nil)
            t.assert_equals(err.message, 'Illegal mix of collations')
        end
    end)
end

g.test_min_with_illegal_collation_mix = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res, err = box.execute(
                [[SELECT min(a COLLATE "unicode" || b COLLATE "binary")
                  FROM t;]])
            t.assert_equals(res, nil)
            t.assert_equals(err.message, 'Illegal mix of collations')
        end
    end)
end

-- A query that generates its bytecode completely still frees WhereInfo in
-- sqlWhereEnd(), so a double free would show up here under ASAN.
g.test_aggregate_without_error = function()
    g.server:exec(function()
        for _ = 1, 20 do
            local res = box.execute([[SELECT max(a), min(b) FROM t;]])
            t.assert_equals(res.rows, {{'x', 'q'}})
        end
    end)
end
