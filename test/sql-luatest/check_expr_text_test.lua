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

-- A comment after the expression of a CHECK constraint is in the text of
-- the expression, and the constraint works.
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
        t.assert_equals(_G.check_text('check_T2_C1'),
                        'b > 0 -- b is positive')
        t.assert_equals(_G.check_text('check_T2_C2'), 'a > 0 /* a too */')
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
