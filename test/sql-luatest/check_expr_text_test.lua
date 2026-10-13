local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'check-expr-text'})
    g.server:start()
    g.server:exec(function()
        -- Returns the text of the expression of the CHECK constraint.
        rawset(_G, 'check_text', function(func_name)
            return box.space._func.index.name:get(func_name).body
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- A comment before the expression of a CHECK constraint is not in the
-- text of the expression, and the constraint works. The line comment is
-- important: the text is stored as one line.
g.test_comment_before_expression = function()
    g.server:exec(function()
        local _, err = box.execute([[
            CREATE TABLE t1 (
                a INT PRIMARY KEY,
                b INT CONSTRAINT c1 CHECK (
                    -- b is positive
                    b > 0),
                CONSTRAINT c2 CHECK ( /* a too */ a > 0));]])
        t.assert_equals(err, nil)
        _, err = box.execute([[ALTER TABLE t1 ADD CONSTRAINT c3 CHECK (
                                   -- a is small
                                   a < 10);]])
        t.assert_equals(err, nil)
        t.assert_equals(_G.check_text('check_T1_C1'), 'b > 0')
        t.assert_equals(_G.check_text('check_T1_C2'), 'a > 0')
        t.assert_equals(_G.check_text('check_T1_C3'), 'a < 10')
        _, err = box.execute([[INSERT INTO t1 VALUES (1, 0);]])
        t.assert_equals(err.message, "Check constraint 'C1' failed for " ..
                                     "field '2 (B)'")
        _, err = box.execute([[INSERT INTO t1 VALUES (0, 1);]])
        t.assert_equals(err.message, "Check constraint 'C2' failed for " ..
                                     "tuple")
        _, err = box.execute([[INSERT INTO t1 VALUES (10, 1);]])
        t.assert_equals(err.message, "Check constraint 'C3' failed for " ..
                                     "tuple")
        t.assert_equals(box.execute([[INSERT INTO t1 VALUES (1, 1);]]),
                        {row_count = 1})
    end)
end

-- A comment after the expression of a CHECK constraint is not in the text
-- of the expression, and the constraint works.
g.test_comment_after_expression = function()
    g.server:exec(function()
        local _, err = box.execute([[
            CREATE TABLE t2 (
                a INT PRIMARY KEY,
                b INT,
                CONSTRAINT c1 CHECK (b > 0 -- b is positive
                    ),
                CONSTRAINT c2 CHECK (a > 0 /* a too */ ));]])
        t.assert_equals(err, nil)
        t.assert_equals(_G.check_text('check_T2_C1'), 'b > 0')
        t.assert_equals(_G.check_text('check_T2_C2'), 'a > 0')
        _, err = box.execute([[INSERT INTO t2 VALUES (1, 0);]])
        t.assert_equals(err.message, "Check constraint 'C1' failed for " ..
                                     "tuple")
        _, err = box.execute([[INSERT INTO t2 VALUES (0, 1);]])
        t.assert_equals(err.message, "Check constraint 'C2' failed for " ..
                                     "tuple")
        t.assert_equals(box.execute([[INSERT INTO t2 VALUES (1, 1);]]),
                        {row_count = 1})
    end)
end

-- A comment in the middle of the expression of a CHECK constraint is not
-- in the text of the expression, and the part of the expression after the
-- comment works. The line comment is important: the text is stored as one
-- line.
g.test_comment_in_expression = function()
    g.server:exec(function()
        local _, err = box.execute([[
            CREATE TABLE t3 (
                a INT PRIMARY KEY,
                b INT CONSTRAINT c1 CHECK (b > 0 -- b is positive
                                           AND b < 10),
                CONSTRAINT c2 CHECK (a > 0 /* a is positive */ AND a < 10),
                CONSTRAINT c3 CHECK (a-- no space before the comment
                                     !=5));]])
        t.assert_equals(err, nil)
        _, err = box.execute([[ALTER TABLE t3 ADD CONSTRAINT c4 CHECK (
                                   a != 6 -- not six
                                   -- and not seven
                                   AND a != 7);]])
        t.assert_equals(err, nil)
        t.assert_equals(_G.check_text('check_T3_C1'), 'b > 0 AND b < 10')
        t.assert_equals(_G.check_text('check_T3_C2'), 'a > 0 AND a < 10')
        t.assert_equals(_G.check_text('check_T3_C3'), 'a !=5')
        t.assert_equals(_G.check_text('check_T3_C4'), 'a != 6 AND a != 7')
        for _, case in ipairs({
            {'1, 10', "Check constraint 'C1' failed for field '2 (B)'"},
            {'10, 1', "Check constraint 'C2' failed for tuple"},
            {'5, 1', "Check constraint 'C3' failed for tuple"},
            {'7, 1', "Check constraint 'C4' failed for tuple"},
        }) do
            _, err = box.execute(('INSERT INTO t3 VALUES (%s);')
                                 :format(case[1]))
            t.assert_equals(err.message, case[2], case[1])
        end
        t.assert_equals(box.execute([[INSERT INTO t3 VALUES (1, 1);]]),
                        {row_count = 1})
    end)
end

-- The text of a string literal that looks like a comment or has many
-- spaces stays in the text of the expression without changes.
g.test_comment_text_in_string = function()
    g.server:exec(function()
        local _, err = box.execute([[
            CREATE TABLE t4 (
                a INT PRIMARY KEY,
                s TEXT,
                CONSTRAINT c1 CHECK (s != '-- x'   AND
                                     s != '/* y */' AND s != 'a  b'));]])
        t.assert_equals(err, nil)
        t.assert_equals(_G.check_text('check_T4_C1'),
                        "s != '-- x' AND s != '/* y */' AND s != 'a  b'")
        for _, value in ipairs({'-- x', '/* y */', 'a  b'}) do
            _, err = box.execute([[INSERT INTO t4 VALUES (1, ?);]], {value})
            t.assert_equals(err.message,
                            "Check constraint 'C1' failed for tuple", value)
        end
        t.assert_equals(box.execute([[INSERT INTO t4 VALUES (1, 'a b');]]),
                        {row_count = 1})
    end)
end
