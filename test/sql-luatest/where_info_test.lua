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

g.after_all(function()
    require('test.lsan').stop(g.server, {'src/box/sql/'})
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
