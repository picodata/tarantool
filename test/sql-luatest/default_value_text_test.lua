local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'default-value-text'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

-- A comment that follows a literal default value is not in the text of
-- the default value.
g.test_comment_after_literal = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (
                          id INT PRIMARY KEY,
                          a TEXT DEFAULT 'abc' /* comment */,
                          b INT DEFAULT -1 -- comment
                          , c DECIMAL DEFAULT +4.0 /* another comment */,
                          d INT DEFAULT 5   NOT NULL,
                          e BOOLEAN DEFAULT true /* comment */ NOT NULL,
                          f INT DEFAULT NULL -- comment
                          );]])
        local format = box.space.T:format()
        t.assert_equals(format[2].sql_default, "'abc'")
        t.assert_equals(format[3].sql_default, "-1")
        t.assert_equals(format[4].sql_default, "+4.0")
        t.assert_equals(format[5].sql_default, "5")
        t.assert_equals(format[6].sql_default, "true")
        t.assert_equals(format[7].sql_default, "NULL")
        box.execute([[INSERT INTO t(id) VALUES (1);]])
        local decimal = require('decimal')
        t.assert_equals(box.execute([[SELECT * FROM t;]]).rows,
                        {{1, 'abc', -1, decimal.new('4.0'), 5, true, nil}})
        box.execute([[DROP TABLE t;]])
    end)
end

-- The text of a default value in parentheses is all that is between the
-- parentheses, without the spaces at its ends.
g.test_expression_in_parentheses = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (
                          id INT PRIMARY KEY,
                          a INT DEFAULT (  5  ),
                          b INT DEFAULT ( 1 + 2 /* comment */ ) /* c */,
                          c INT DEFAULT (abs(-7)),
                          d INT DEFAULT (4 -- comment
                                        ));]])
        local format = box.space.T:format()
        t.assert_equals(format[2].sql_default, "5")
        t.assert_equals(format[3].sql_default, "1 + 2 /* comment */")
        t.assert_equals(format[4].sql_default, "abs(-7)")
        t.assert_equals(format[5].sql_default, "4 -- comment")
        box.execute([[INSERT INTO t(id) VALUES (1);]])
        t.assert_equals(box.execute([[SELECT * FROM t;]]).rows,
                        {{1, 5, 3, 7, 4}})
        box.execute([[DROP TABLE t;]])
    end)
end
