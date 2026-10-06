local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-pseudocode'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT, s STRING);]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TRIGGER tr AFTER INSERT ON u FOR EACH ROW
                      BEGIN SELECT 1; END;]])
        -- Returns the result of EXPLAIN with the opcodes and the
        -- pseudocode.
        rawset(_G, 'explain', function(sql)
            return box.execute('EXPLAIN (opcode, pseudocode) ' .. sql)
        end)
        -- Returns "opcode: pseudocode" for each instruction. Only Debug
        -- builds put OP_Explain into EXPLAIN, so it is left out. It
        -- moves the addresses, so the jump targets are replaced by "N".
        rawset(_G, 'pseudocode', function(sql)
            local res = _G.explain(sql)
            local opcode_no, pseudocode_no
            for i, meta in ipairs(res.metadata) do
                if meta.name == 'opcode' then
                    opcode_no = i
                elseif meta.name == 'pseudocode' then
                    pseudocode_no = i
                end
            end
            local lines = {}
            for _, row in ipairs(res.rows) do
                local opcode = row[opcode_no]
                local text = row[pseudocode_no]:gsub('^%s+', '')
                text = text:gsub('GOTO %d+', 'GOTO N')
                text = text:gsub('START AT %d+', 'START AT N')
                if opcode ~= 'Explain' then
                    table.insert(lines, opcode .. ': ' .. text)
                end
            end
            return lines
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The last column of EXPLAIN is "pseudocode", and it is a text.
g.test_column = function()
    g.server:exec(function()
        local metadata = box.execute([[EXPLAIN SELECT a FROM t;]]).metadata
        t.assert_equals(metadata[#metadata],
                        {name = 'pseudocode', type = 'text'})
    end)
end

-- The pseudocode shows what an instruction does with its operands:
-- registers, cursors, and the names of spaces, indexes, columns, types
-- and functions. An opcode can have more than one synopsis: OP_Variable
-- shows the name of a parameter only if the parameter has it.
g.test_operands = function()
    g.server:exec(function()
        local sql = [[SELECT ?, :name, abs(a), a + 1, s || 'x',
                             CAST(a AS STRING) FROM t WHERE id = 5;]]
        t.assert_equals(_G.pseudocode(sql), {
            'Init: START AT N',
            "OpenSpace: r[1] = space::open('T')",
            'IteratorOpen: c[1] = ' ..
            "r[1].space().index('pk_unnamed_T_1').cursor()",
            'Integer: r[2] = 5',
            'SeekGE: c[1].seek_ge(r[2]); IF none THEN GOTO N END',
            'IdxGT: IF c[1].row().key() > r[2] THEN GOTO N END',
            'Variable: r[3] = parameter(1)',
            'Variable: r[4] = parameter(2, :name)',
            "Column: r[9] = c[1].row().column('T.A')",
            'ApplyType: r[9] = r[9].coerce(integer)',
            'BuiltinFunction: r[5] = ABS(r[9])',
            "Column: r[9] = c[1].row().column('T.A')",
            'Add: r[6] = r[10] + r[9]',
            "Column: r[11] = c[1].row().column('T.S')",
            'Concat: r[7] = r[11] + r[12]',
            'SCopy: r[8] = shallow r[9]',
            'Cast: r[8] = r[8].cast(string)',
            'ResultRow: OUTPUT r[3..8]',
            'Next: c[1].next(); IF found THEN GOTO N END',
            'Halt: HALT',
            'Integer: r[10] = 1',
            "String8: r[12] = 'x'",
            'Goto: GOTO N',
        })
    end)
end

-- The comment of the code generator comes after "#", in all builds. It is
-- on the instruction that it describes: here on the check of the LIMIT
-- value, not on the halt of the error that comes after it.
g.test_comment = function()
    g.server:exec(function()
        local lines = _G.pseudocode([[SELECT a FROM t LIMIT 2;]])
        t.assert_items_include(lines, {
            'MustBeInt: r[1] = r[1].to_int_precise() OR GOTO N  ' ..
            '# LIMIT counter',
            'Halt: HALT WITH ERROR',
        })
    end)
end

-- A trigger program is listed after the main program. OP_Program has
-- the name of the trigger, and the comments tell where the trigger
-- program starts and ends. OP_SetDiag has the text of its error.
g.test_trigger_program = function()
    g.server:exec(function()
        local sql = [[INSERT INTO u VALUES (1, 2);]]
        t.assert_equals(_G.pseudocode(sql), {
            'Init: START AT N',
            "OpenSpace: r[5] = space::open('U')",
            'Null: r[1] = NULL',
            'Integer: r[2] = 1',
            'Integer: r[3] = 2',
            'NotNull: IF r[2] IS NOT NULL THEN GOTO N END',
            "SetDiag: vm::set_error(159, 'Failed to execute SQL statement: " ..
            "NOT NULL constraint failed: U.ID')",
            'Halt: HALT WITH ERROR',
            'ApplyType: r[2..3] = r[2..3].coerce(integer,integer)',
            'MakeRecord: r[4] = make_row(r[2..3])',
            'IdxInsert: r[5].space().insert(r[4])',
            "Program: program('TR').run(args_base=-2); IF ignored THEN " ..
            'GOTO N END  # call: TR.default',
            'Halt: HALT',
            'TTransaction: txn::begin_or_savepoint()',
            'Goto: GOTO N',
            'Init: START AT N  # start: TR.default (AFTER INSERT ON U)',
            'Integer: r[1] = 1',
            'Halt: HALT  # end: TR.default',
        })
    end)
end

-- An instruction that the code generator cancels has no comment: here the
-- index gives the order, so the sort table is not opened.
g.test_cancelled_instruction = function()
    g.server:exec(function()
        local lines = _G.pseudocode([[SELECT a FROM t ORDER BY id;]])
        t.assert_items_include(lines, {'Noop: nop'})
        for _, line in ipairs(lines) do
            t.assert_not_str_contains(line, 'sort table')
        end
    end)
end

-- The name of a FROM subquery in a comment is the same in each run: it is
-- a number in the statement, not an address.
g.test_subquery_name = function()
    g.server:exec(function()
        local sql = [[SELECT x FROM (SELECT a AS x FROM t LIMIT 5)
                      WHERE x > 1;]]
        t.assert_items_include(_G.pseudocode(sql), {
            'Yield: RESUME r[1] + 1 OR GOTO N  # next row of (subquery:1)',
        })
    end)
end

-- A comment that is not the name of a column comes after "#" too: the
-- instruction shows the number of the column that it reads.
g.test_comment_is_not_name = function()
    g.server:exec(function()
        local sql = [[SELECT a + 1 FROM t ORDER BY s LIMIT 2;]]
        t.assert_items_include(_G.pseudocode(sql), {
            "Column: r[3] = c[2].row().column('T.A')",
            'Column: r[7] = c[1].row().column(2)  # COLUMN_1',
        })
    end)
end

-- An argument of a function that takes a value of any type has the type
-- "any" in OP_ApplyType.
g.test_any_type = function()
    g.server:exec(function()
        local sql = [[SELECT count(a) FROM t;]]
        t.assert_items_include(_G.pseudocode(sql), {
            'ApplyType: r[1] = r[1].coerce(any)',
        })
    end)
end

-- A text that is too long is cut on a character boundary.
g.test_long_text = function()
    g.server:exec(function()
        local utf8 = require('utf8')
        -- The string has characters of 2 bytes. With one of the two
        -- prefixes, the limit of the text is in the middle of a character.
        for _, prefix in ipairs({'', 'x'}) do
            local sql = ([[SELECT '%s%s';]]):format(prefix,
                                                    ('\u{436}'):rep(300))
            for _, row in ipairs(_G.explain(sql).rows) do
                for _, value in ipairs(row) do
                    if type(value) == 'string' then
                        t.assert_not_equals(utf8.len(value), nil)
                    end
                end
            end
        end
    end)
end

-- The column "p4" of OP_Blob is a text in all cases. Binary data is a hex
-- literal, and "..." is at its end if it is too long. MsgPack is decoded,
-- and a long text of it is cut on a character boundary.
g.test_blob = function()
    g.server:exec(function()
        local utf8 = require('utf8')
        local function blobs(sql)
            local res = _G.explain(sql)
            local opcode_no, p4_no
            for i, meta in ipairs(res.metadata) do
                if meta.name == 'opcode' then
                    opcode_no = i
                elseif meta.name == 'p4' then
                    p4_no = i
                end
            end
            local result = {}
            for _, row in ipairs(res.rows) do
                if row[opcode_no] == 'Blob' then
                    table.insert(result, row[p4_no])
                end
            end
            return result
        end
        t.assert_equals(blobs([[SELECT x'ff00aa41', x'';]]),
                        {"x'FF00AA41'", "x''"})
        local long = blobs(([[SELECT x'%s';]]):format(('ab'):rep(200)))[1]
        t.assert_equals(#long, 255)
        t.assert_equals(long:sub(1, 6), "x'ABAB")
        t.assert_equals(long:sub(-5), 'AB...')

        local sql = [[CREATE TABLE c (id INT PRIMARY KEY, a%s INT, "%s" INT);]]
        -- The name has characters of 2 bytes. With one of the two
        -- prefixes, the limit of the text is in the middle of a character.
        for _, prefix in ipairs({'', 'x'}) do
            local format = blobs(sql:format(prefix, ('\u{436}'):rep(200)))[2]
            t.assert_str_contains(format, '[{"name": "ID", "type": "integer"')
            t.assert_not_equals(utf8.len(format), nil)
            t.assert_ge(#format, 254)
        end
    end)
end

-- The pseudocode of OP_Explain is the line of the query plan that the
-- instruction holds, after "#". The column "p4" has the same line. Only
-- Debug builds put OP_Explain into EXPLAIN, so other builds have nothing to
-- check here.
g.test_query_plan_line = function()
    g.server:exec(function()
        local sql = [[SELECT a FROM t WHERE id = 5;]]
        local plan = box.execute('EXPLAIN QUERY PLAN ' .. sql).rows
        t.assert_equals(#plan, 1)
        local res = _G.explain(sql)
        local opcode_no, p4_no, pseudocode_no
        for i, meta in ipairs(res.metadata) do
            if meta.name == 'opcode' then
                opcode_no = i
            elseif meta.name == 'p4' then
                p4_no = i
            elseif meta.name == 'pseudocode' then
                pseudocode_no = i
            end
        end
        local lines = {}
        local details = {}
        for _, row in ipairs(res.rows) do
            if row[opcode_no] == 'Explain' then
                table.insert(lines, (row[pseudocode_no]:gsub('^%s+', '')))
                table.insert(details, row[p4_no])
            end
        end
        t.skip_if(#lines == 0, 'the build does not put OP_Explain into EXPLAIN')
        t.assert_equals(lines, {'# ' .. plan[1][4]})
        t.assert_equals(details, {plan[1][4]})
        t.assert_str_contains(lines[1], '# SEARCH TABLE T USING PRIMARY KEY')
    end)
end
