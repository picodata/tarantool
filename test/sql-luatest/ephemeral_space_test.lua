local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'master'})
    g.server:start()
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

-- A space created by OP_OpenTEphemeral is owned by nothing until
-- OP_IteratorOpen binds it to a cursor. DELETE, UPDATE and INSERT used to
-- emit the two opcodes far apart, so an error raised by an opcode in
-- between left the ephemeral space behind.
g.test_delete_with_error_in_where = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE td (id INT PRIMARY KEY, s STRING);]])
        box.execute([[INSERT INTO td VALUES (1, 'x'), (2, 'y');]])
        for _ = 1, 20 do
            local res, err = box.execute(
                [[DELETE FROM td WHERE CAST(s AS INTEGER) > 0;]])
            t.assert_equals(res, nil)
            t.assert_str_contains(err.message, 'Type mismatch')
        end
    end)
end

g.test_update_with_error_in_where = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE tu (id INT PRIMARY KEY, a INT,
                                       s STRING);]])
        box.execute([[INSERT INTO tu VALUES (1, 1, 'x'), (2, 2, 'y');]])
        for _ = 1, 20 do
            local res, err = box.execute(
                [[UPDATE tu SET a = 10 WHERE CAST(s AS INTEGER) > 0;]])
            t.assert_equals(res, nil)
            t.assert_str_contains(err.message, 'Type mismatch')
        end
    end)
end

-- INSERT materializes the SELECT into an ephemeral space only when the
-- destination space is read by that SELECT or a trigger is fired.
g.test_insert_with_error_in_select = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE tn (id INT PRIMARY KEY, a INT,
                                       s STRING);]])
        box.execute([[INSERT INTO tn VALUES (1, 1, 'x'), (2, 2, 'y');]])
        for _ = 1, 20 do
            local res, err = box.execute(
                [[INSERT INTO tn SELECT id + 10, CAST(s AS INTEGER), s
                  FROM tn;]])
            t.assert_equals(res, nil)
            t.assert_str_contains(err.message, 'Type mismatch')
        end
    end)
end

-- The ONEPASS branches turn both opcodes into OP_Noop, and a successful
-- INSERT ... SELECT runs the moved OP_IteratorOpen. Guards for the bytecode
-- layout rather than leak reproducers.
g.test_one_pass_delete_and_update = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE tp (id INT PRIMARY KEY, a INT);]])
        box.execute([[INSERT INTO tp VALUES (1, 1), (2, 2), (3, 3);]])
        local res = box.execute([[UPDATE tp SET a = 10 WHERE id = 1;]])
        t.assert_equals(res.row_count, 1)
        res = box.execute([[DELETE FROM tp WHERE id = 2;]])
        t.assert_equals(res.row_count, 1)
        res = box.execute([[SELECT id, a FROM tp ORDER BY id;]])
        t.assert_equals(res.rows, {{1, 10}, {3, 3}})
    end)
end

g.test_insert_from_self_select = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE ti (id INT PRIMARY KEY, a INT);]])
        box.execute([[INSERT INTO ti VALUES (1, 1), (2, 2);]])
        local res = box.execute([[INSERT INTO ti SELECT id + 10, a
                                  FROM ti;]])
        t.assert_equals(res.row_count, 2)
        res = box.execute([[SELECT id FROM ti ORDER BY id;]])
        t.assert_equals(res.rows, {{1}, {2}, {11}, {12}})
    end)
end
