local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-graph'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        box.execute([[CREATE TABLE s (id INT PRIMARY KEY, x INT);]])
        box.execute([[CREATE TRIGGER tr AFTER DELETE ON s FOR EACH ROW
                      BEGIN SELECT RAISE(ABORT, 'no') WHERE old.x > 0;
                      END;]])
        -- Returns the graph and the opcode of each instruction. Only
        -- Debug builds put OP_Explain into EXPLAIN, so it is left out.
        -- No jump goes to or from it in the statements below.
        rawset(_G, 'jump_graph', function(sql)
            local lines = {}
            sql = 'EXPLAIN (graph, opcode) ' .. sql
            for _, row in ipairs(box.execute(sql).rows) do
                local opcode = row[3]
                if opcode ~= 'Explain' then
                    table.insert(lines, row[1] .. ' ' .. opcode)
                end
            end
            return lines
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- The graph is a facet of EXPLAIN: plain EXPLAIN does not have it. With
-- the facet, the graph is the first column, and the graph alone comes with
-- the pseudocode. EXPLAIN QUERY PLAN does not have it.
g.test_columns = function()
    g.server:exec(function()
        local function names(sql)
            local result = {}
            for _, meta in ipairs(box.execute(sql).metadata) do
                table.insert(result, meta.name .. ' ' .. meta.type)
            end
            return result
        end
        t.assert_equals(names([[EXPLAIN SELECT a FROM t;]]), {
            'addr integer', 'pseudocode text',
        })
        t.assert_equals(names([[EXPLAIN (graph) SELECT a FROM t;]]), {
            'graph text', 'addr integer', 'pseudocode text',
        })
        t.assert_equals(names([[EXPLAIN (graph, opcode) SELECT a FROM t;]]), {
            'graph text', 'addr integer', 'opcode text', 'p1 integer',
            'p2 integer', 'p3 integer', 'p4 text', 'p5 text',
        })
        t.assert_equals(names([[EXPLAIN (graph, pseudocode)
                                SELECT a FROM t;]]), {
            'graph text', 'addr integer', 'pseudocode text',
        })
        t.assert_equals(names([[EXPLAIN QUERY PLAN SELECT a FROM t;]]), {
            'selectid integer', 'order integer', 'from integer',
            'detail text',
        })
    end)
end

-- A jump goes from "<" to ">", forward or backward. The lines of forward
-- jumps are box-drawing characters. The lines of backward jumps are dots:
-- "." at the target, "`" at the source and ":" between them. A shorter
-- jump is nearer to the addresses. A row that is a jump source and a
-- target ends with "X".
g.test_loop = function()
    g.server:exec(function()
        t.assert_equals(_G.jump_graph([[SELECT a FROM t WHERE a > 1;]]), {
            ' ╭────< Init',
            '.·····> OpenSpace',
            ':│      IteratorOpen',
            ':│╭───< Rewind',
            ':││.··> Column',
            ':││:╭─< Le',
            ':││:│   Copy',
            ':││:│   ResultRow',
            ':││`┴─X Next',
            ':│╰───> Halt',
            ':╰────> Integer',
            '`·····< Goto',
        })
    end)
end

-- All jumps to one address share a lane. A horizontal line goes over the
-- vertical lines it does not link to. A lane is ":" below its target:
-- only backward jumps go there.
g.test_shared_lane = function()
    g.server:exec(function()
        local sql = [[SELECT CASE ? WHEN 1 THEN 'a' WHEN 2 THEN 'b'
                      ELSE 'c' END;]]
        t.assert_equals(_G.jump_graph(sql), {
            ' ╭────< Init',
            '.···┬─X Ne',
            ':│  │   String8',
            ':│╭───< Goto',
            ':││╭┴─X Ne',
            ':│││    String8',
            ':│├───< Goto',
            ':││╰──> String8',
            ':│╰───> ApplyType',
            ':│      ResultRow',
            ':│      Halt',
            ':╰────> Variable',
            ':       Integer',
            ':       Integer',
            '`·····< Goto',
        })
    end)
end

-- A jump to the next instruction is not drawn. Here it is the only jump,
-- so the graph is empty.
g.test_next_instruction = function()
    g.server:exec(function()
        local rows = box.execute([[EXPLAIN (graph, opcode) SELECT 1;]]).rows
        t.assert_equals({rows[1][3], rows[1][5]}, {'Init', 1})
        for _, row in ipairs(rows) do
            t.assert_equals(row[1], '', row[3])
        end
    end)
end

-- A comparison that gives a value stores it in the register P2 and does
-- not jump, so it has no line. Here the registers 2, 3 and 4 are also
-- addresses of the program.
g.test_stored_comparison = function()
    g.server:exec(function()
        local sql = [[SELECT a = 1, a < 2, a >= 3 FROM t;]]
        t.assert_equals(_G.jump_graph(sql), {
            ' ╭───< Init',
            '.····> OpenSpace',
            ':│     IteratorOpen',
            ':│╭──< Rewind',
            ':││.·> Column',
            ':││:   Eq',
            ':││:   Lt',
            ':││:   Ge',
            ':││:   ResultRow',
            ':││`·< Next',
            ':│╰──> Halt',
            ':╰───> Integer',
            ':      Integer',
            ':      Integer',
            '`····< Goto',
        })
    end)
end

-- A seek by equality skips the instruction after it when it finds a row:
-- that instruction is only for the next iterations. The skip is a jump
-- over one instruction. A seek that is not by equality has no such jump.
g.test_seek_skip = function()
    g.server:exec(function()
        t.assert_equals(_G.jump_graph([[SELECT a FROM t WHERE id = 5;]]), {
            '      Init',
            '      OpenSpace',
            '      IteratorOpen',
            '      Integer',
            '╭─┬─< SeekGE',
            '├.··X IdxGT',
            '│:╰─> Column',
            '│:    ResultRow',
            '│`··< Next',
            '╰───> Halt',
        })
        t.assert_equals(_G.jump_graph([[SELECT a FROM t WHERE id >= 5;]]), {
            '     Init',
            '     OpenSpace',
            '     IteratorOpen',
            '     Integer',
            '╭──< SeekGE',
            '│.·> Column',
            '│:   ResultRow',
            '│`·< Next',
            '╰──> Halt',
        })
    end)
end

-- OP_SequenceTest jumps on the first row of a sort that an index does in
-- part. Here it jumps over the check for a new group, to OP_Move.
g.test_sequence_test = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE q (id INT PRIMARY KEY, a INT, b INT);]])
        box.execute([[CREATE INDEX qa ON q(a);]])
        local lines = _G.jump_graph([[SELECT a, b FROM q ORDER BY a, b;]])
        box.execute([[DROP TABLE q;]])
        t.assert_equals(lines, {
            '        Init',
            '        SorterOpen',
            '        Noop',
            '        OpenSpace',
            '        IteratorOpen',
            '╭─────< Rewind',
            '│.····> Column',
            '│:      Copy',
            '│:      Column',
            '│:      MakeRecord',
            '│: ╭──< SequenceTest',
            '│: │    Compare',
            '│: │╭─< Jump',
            '│:╭───< Gosub',
            '│:│││   ResetSorter',
            '│:│╰──> Move',
            '│:│ ╰─> SorterInsert',
            '│`····< Next',
            '╰─┼───X Gosub',
            '  │╭──< Goto',
            '  ╰─┬─X Once',
            '   ││   OpenPseudo',
            '   ├┴─X SorterSort',
            '   │.·> SorterData',
            '   │:   Column',
            '   │:   Column',
            '   │:   ResultRow',
            '   │`·< SorterNext',
            '   │  · Return',
            '   ╰──> Halt',
        })
    end)
end

-- OP_Jump goes to the addresses in P1, P2 and P3. Here P1 and P3 are the
-- next instruction, so only the jump to P2 is drawn. The jump of Return
-- is not known before the run, so it is not drawn: Return has a middle dot.
g.test_three_way_jump = function()
    g.server:exec(function()
        t.assert_equals(_G.jump_graph([[SELECT a FROM t GROUP BY a;]]), {
            '        Init',
            '        SorterOpen',
            '        Integer',
            '        Integer',
            '        Null',
            '╭─────< Gosub',
            '│       OpenSpace',
            '│       IteratorOpen',
            '│  ╭──< Rewind',
            '│  │.·> Column',
            '│  │:   MakeRecord',
            '│  │:   SorterInsert',
            '│  │`·< Next',
            '│  ╰──> OpenPseudo',
            '│╭────< SorterSort',
            '││ .··> SorterData',
            '││ :    Column',
            '││ :    Compare',
            '││ :╭─< Jump',
            '││ :│   Move',
            '││╭───< Gosub',
            '│├────< IfPos',
            '├─────< Gosub',
            '│││:╰─> Column',
            '│││:    Integer',
            '│││`··< SorterNext',
            '││├───< Gosub',
            '│├────< Goto',
            '│││     Integer',
            '│││   · Return',
            '││╰─┬─X IfPos',
            '││  │ · Return',
            '││  ╰─> Copy',
            '││      ResultRow',
            '││    · Return',
            '╰─────> Null',
            ' │    · Return',
            ' ╰────> Halt',
        })
    end)
end

-- Yield, Return and EndCoroutine jump to an address from a register,
-- which is not known before the run. Such an instruction has a middle dot
-- if it has no arrow: here the first Yield. The second Yield also jumps to
-- its P2, and EndCoroutine is a jump target, so they have arrows.
g.test_computed_jump = function()
    g.server:exec(function()
        local sql = [[INSERT INTO t SELECT id + 100, a FROM t;]]
        t.assert_equals(_G.jump_graph(sql), {
            ' ╭────< Init',
            '.·····> OpenSpace',
            ':│╭───< InitCoroutine',
            ':││     OpenSpace',
            ':││     IteratorOpen',
            ':││╭──< Rewind',
            ':│││.·> Column',
            ':│││:   Add',
            ':│││:   Column',
            ':│││: · Yield',
            ':│││`·< Next',
            ':││╰──> EndCoroutine',
            ':│╰───> OpenTEphemeral',
            ':│      IteratorOpen',
            ':│ ╭.·X Yield',
            ':│ │:   NextIdEphemeral',
            ':│ │:   Copy',
            ':│ │:   ApplyType',
            ':│ │:   MakeRecord',
            ':│ │:   IdxInsert',
            ':│ │`·< Goto',
            ':│╭┴──X Rewind',
            ':││.··> Null',
            ':││:    Column',
            ':││:    Column',
            ':││:╭─< NotNull',
            ':││:│   SetDiag',
            ':││:│   Halt',
            ':││:╰─> ApplyType',
            ':││:    MakeRecord',
            ':││:    IdxInsert',
            ':││`··< Next',
            ':│╰───> Close',
            ':│      Halt',
            ':╰────> TTransaction',
            ':       Integer',
            '`·····< Goto',
        })
    end)
end

-- With a list of addresses, the graph shows only the jumps that start or
-- end at them. An instruction without an arrow that starts or ends a jump
-- that is not shown has a middle dot.
g.test_lines = function()
    g.server:exec(function()
        local function graph(lines, sql)
            local result = {}
            sql = ('EXPLAIN (graph %s, opcode) %s'):format(lines, sql)
            for _, row in ipairs(box.execute(sql).rows) do
                local opcode = row[3]
                if opcode ~= 'Explain' then
                    table.insert(result, row[1] .. ' ' .. opcode)
                end
            end
            return result
        end
        local sql = [[SELECT a FROM t WHERE a > 1;]]
        -- The lines are addresses, and OP_Explain of a Debug build
        -- moves them, so find them in the listing.
        local addr = {}
        for _, row in ipairs(box.execute('EXPLAIN (opcode) ' .. sql).rows) do
            addr[row[2]] = row[1]
        end
        t.assert_equals(graph(('[%d]'):format(addr.Rewind), sql), {
            '  · Init',
            '  · OpenSpace',
            '    IteratorOpen',
            '╭─< Rewind',
            '│ · Column',
            '│ · Le',
            '│   Copy',
            '│   ResultRow',
            '│ · Next',
            '╰─> Halt',
            '  · Integer',
            '  · Goto',
        })
        local lines = ('[%d, %d]'):format(addr.Next, addr.Goto)
        t.assert_equals(graph(lines, sql), {
            '    · Init',
            '.···> OpenSpace',
            ':     IteratorOpen',
            ':   · Rewind',
            ':.··> Column',
            '::╭─< Le',
            '::│   Copy',
            '::│   ResultRow',
            ':`┴─X Next',
            ':   · Halt',
            ':   · Integer',
            '`···< Goto',
        })
        -- With an empty list, the graph shows no jumps, only the dots.
        t.assert_equals(graph('[]', sql), {
            ' · Init',
            ' · OpenSpace',
            '   IteratorOpen',
            ' · Rewind',
            ' · Column',
            ' · Le',
            '   Copy',
            '   ResultRow',
            ' · Next',
            ' · Halt',
            ' · Integer',
            ' · Goto',
        })
        for _, lines in ipairs({'[1]', '[]'}) do
            local _, err = box.execute(([[EXPLAIN (opcode %s)
                                          SELECT 1;]]):format(lines))
            t.assert_str_contains(err.message,
                                  "EXPLAIN facet 'opcode' takes no lines")
        end
        -- A line that is not an address of the program selects nothing.
        t.assert_equals(graph('[9999]', sql), graph('[]', sql))
    end)
end

-- A prepared statement keeps its lines when a new schema makes its program
-- shorter: a line that is not in the new program selects nothing.
g.test_lines_after_schema_change = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE r (id INT PRIMARY KEY, c INT);]])
        local sql = [[SELECT id FROM r WHERE c = 1;]]
        local rows = box.execute('EXPLAIN (opcode) ' .. sql).rows
        local last = rows[#rows][1]
        local stmt = box.prepare(('EXPLAIN (graph [%d]) %s'):format(last, sql))
        t.assert_equals(#stmt:execute().rows, last + 1)
        box.execute([[CREATE INDEX rc ON r (c);]])
        local res, err = stmt:execute()
        t.assert_equals(err, nil)
        t.assert_lt(#res.rows, last + 1)
        stmt:unprepare()
        box.execute([[DROP TABLE r;]])
    end)
end

-- A trigger program is listed after the main program. Its addresses
-- start from 0 again, and it has a graph of its own.
g.test_trigger_program = function()
    g.server:exec(function()
        local lines = _G.jump_graph([[DELETE FROM s WHERE id = 1;]])
        local first = #lines
        while not lines[first]:find(' Init$') do
            first = first - 1
        end
        t.assert(first > 1)
        t.assert_equals({unpack(lines, first)}, {
            '    Init',
            '    Param',
            '    Integer',
            '╭─< Le',
            '│   SetDiag',
            '│   Halt',
            '╰─> Halt',
        })
        -- The lines are addresses of the main program: with lines, the
        -- trigger program shows no jumps, only their ends.
        lines = {}
        local sql = [[EXPLAIN (graph [0], opcode) DELETE FROM s WHERE id = 1;]]
        for _, row in ipairs(box.execute(sql).rows) do
            table.insert(lines, row[1] .. ' ' .. row[3])
        end
        t.assert_equals({unpack(lines, #lines - 6)}, {
            '   Init',
            '   Param',
            '   Integer',
            ' · Le',
            '   SetDiag',
            '   Halt',
            ' · Halt',
        })
    end)
end
