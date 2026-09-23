local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'parenthesized-from-item'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t1(x INTEGER PRIMARY KEY, y INTEGER);]])
        box.execute([[CREATE TABLE t2(p INTEGER PRIMARY KEY, q INTEGER);]])
        box.execute([[INSERT INTO t1 VALUES (1, 10), (2, 20);]])
        box.execute([[INSERT INTO t2 VALUES (1, 11), (3, 33);]])
    end)
end)

-- Whatever a test leaves behind must not reach the next one, so it is
-- dropped here rather than at the end of the test, which a failed
-- assertion would not reach.
g.after_each(function()
    g.server:exec(function()
        box.execute([[DROP INDEX IF EXISTS t1y ON t1;]])
        box.execute([[SET SESSION "sql_seq_scan" = true;]])
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- Without an alias of its own, the parentheses keep the one inside.
g.test_alias = function()
    g.server:exec(function()
        local sql = [[SELECT u.x FROM t2 JOIN (t1 AS u) ON u.x = p;]]
        t.assert_equals(box.execute(sql).rows, {{1}})

        -- The alias of the parentheses hides the one inside.
        local _, err = box.execute([[SELECT u.x FROM (t1 AS u) AS w;]])
        t.assert_equals(err.message,
                        "Field 'X' was not found in space 'U' format")
    end)
end

-- The alias of the parentheses replaces that of the item inside, but its
-- hints and restrictions stay in force.
g.test_restrictions = function()
    g.server:exec(function()
        box.execute([[CREATE INDEX t1y ON t1(y);]])
        local pk = box.space.T1.index[0].name
        -- Without the hint, T1Y would be used to search by y. The hint
        -- forbids it, so the table is scanned instead.
        local explain = [[EXPLAIN QUERY PLAN SELECT * FROM
                          (t1 AS u INDEXED BY "%s") AS w WHERE y = 1;]]
        local plan = box.execute(explain:format(pk)).rows[1][4]
        t.assert_str_matches(plan, 'SCAN TABLE T1 AS W.*')

        local _, err = box.execute(
            [[SELECT * FROM (t1 INDEXED BY nope) AS w;]])
        t.assert_equals(err.message,
                        "No index 'NOPE' is defined in space 'T1'")

        _, err = box.execute([[SELECT * FROM (t1(1)) AS w;]])
        t.assert_equals(err.message, "'T1' is not a function")

        -- The ban on scanning the item without SEQSCAN stays in force too.
        box.execute([[SET SESSION "sql_seq_scan" = false;]])
        local not_allowed = "Scanning is not allowed for 'T1'"
        for _, sql in ipairs({
            [[SELECT * FROM (t1) AS w;]],
            [[SELECT * FROM SEQSCAN t2, (t1) AS w;]],
        }) do
            _, err = box.execute(sql)
            t.assert_not_equals(err, nil, sql)
            t.assert_equals(err.message, not_allowed, sql)
        end
        t.assert_equals(box.execute(
            [[SELECT * FROM (SEQSCAN t1) AS w ORDER BY 1;]]).rows,
            {{1, 10}, {2, 20}})
        -- A lookup by key is not a scan.
        t.assert_equals(box.execute(
            [[SELECT * FROM (t1) AS w WHERE x = 1;]]).rows, {{1, 10}})
    end)
end
