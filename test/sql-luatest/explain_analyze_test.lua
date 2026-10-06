local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze'})
    g.server:start()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        for i = 1, 10 do
            box.space.T:insert({i, i})
        end
        -- Returns the names of the columns of EXPLAIN (analyze ...) that
        -- are before the address, or the error message.
        rawset(_G, 'measure_columns', function(options)
            local sql = ([[EXPLAIN (ANALYZE %s) SELECT a FROM t;]])
            local res, err = box.execute(sql:format(options))
            if res == nil then
                return err.message
            end
            local names = {}
            for _, meta in ipairs(res.metadata) do
                if meta.name == 'addr' then
                    break
                end
                table.insert(names, meta.name)
            end
            return names
        end)
    end)
    -- A build that cannot sample the instructions gives an error for the
    -- default mode of EXPLAIN ANALYZE, so these tests are not for it.
    local can_sample = g.server:exec(function()
        local _, err = box.execute([[EXPLAIN ANALYZE SELECT 1;]])
        return err == nil or err.message:find('cannot sample', 1, true) == nil
    end)
    t.skip_if(not can_sample, 'the build cannot sample the instructions')
end)

g.after_all(function()
    g.server:stop()
end)

-- EXPLAIN ANALYZE has the columns of EXPLAIN after its measurements, and
-- other facets can be next to the facet. It samples by default.
g.test_columns = function()
    g.server:exec(function()
        local function names(sql)
            local result = {}
            for _, meta in ipairs(box.execute(sql).metadata) do
                table.insert(result, meta.name)
            end
            return result
        end
        t.assert_equals(names([[EXPLAIN ANALYZE SELECT a FROM t;]]),
                        {'samples', 'addr', 'pseudocode'})
        t.assert_equals(names([[EXPLAIN (ANALYZE) SELECT a FROM t;]]),
                        {'samples', 'addr', 'pseudocode'})
        t.assert_equals(names([[EXPLAIN (ANALYZE, opcode) SELECT a FROM t;]]),
                        {'samples', 'addr', 'opcode', 'p1', 'p2', 'p3', 'p4',
                         'p5'})
        t.assert_equals(names([[EXPLAIN (ANALYZE, graph) SELECT a FROM t;]]),
                        {'samples', 'graph', 'addr', 'pseudocode'})
    end)
end

-- The mode is one value or a list of values. The columns have the same
-- order for any order of the list.
g.test_mode = function()
    g.server:exec(function()
        t.assert_equals(_G.measure_columns([[{'mode': 'hits'}]]),
                        {'hits'})
        t.assert_equals(_G.measure_columns([[{'mode': 'samples'}]]),
                        {'samples'})
        t.assert_equals(_G.measure_columns([[{'mode': ['hits']}]]),
                        {'hits'})
        t.assert_equals(_G.measure_columns([[{'mode': ['hits', 'samples']}]]),
                        {'hits', 'samples'})
        t.assert_equals(_G.measure_columns([[{'mode': ['samples', 'hits']}]]),
                        {'hits', 'samples'})
        -- 'all' is all the modes, alone and in a list.
        t.assert_equals(_G.measure_columns([[{'mode': 'all'}]]),
                        {'hits', 'samples'})
        t.assert_equals(_G.measure_columns([[{'mode': ['all', 'hits']}]]),
                        {'hits', 'samples'})
    end)
end

-- A list after ANALYZE is the short form of the list of the modes.
g.test_mode_short = function()
    g.server:exec(function()
        t.assert_equals(_G.measure_columns([=[['hits']]=]), {'hits'})
        t.assert_equals(_G.measure_columns([=[['samples', 'hits']]=]),
                        {'hits', 'samples'})
        t.assert_equals(_G.measure_columns([=[['all']]=]),
                        {'hits', 'samples'})
        t.assert_str_contains(_G.measure_columns([=[['kek']]=]),
                              "EXPLAIN option 'mode' must be 'hits'")
        t.assert_str_contains(_G.measure_columns('[]'), 'Syntax error')
    end)
end

-- A value that is not a mode is an error, alone and in a list. Only the
-- mode takes a list.
g.test_mode_errors = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'mode' must be 'hits', 'samples', " ..
                    "'all' or a list of them"
        for _, options in ipairs({[[{'mode': 'both'}]], [[{'mode': 5}]],
                                  [[{'mode': ['hits', 'kek']}]]}) do
            t.assert_str_contains(_G.measure_columns(options), msg, false,
                                  options)
        end
        t.assert_str_contains(_G.measure_columns([[{'freq': ['samples']}]]),
                              "EXPLAIN option 'freq' takes no list")
        t.assert_str_contains(
            _G.measure_columns([[{'mode': ['hits'], 'freq': 10}]]),
            "EXPLAIN option 'freq' needs mode 'samples'")
    end)
end

-- An unknown option is an error that lists the options, also when its
-- value is a list.
g.test_unknown_option = function()
    g.server:exec(function()
        local msg = "Unknown EXPLAIN option 'kek' of facet 'analyze': " ..
                    "the options are 'freq', 'mode'"
        t.assert_str_contains(_G.measure_columns([[{'kek': 1}]]), msg)
        t.assert_str_contains(_G.measure_columns([[{'kek': ['hits']}]]), msg)
    end)
end

-- The count is the number of times that an instruction ran, and the
-- statement keeps its changes.
g.test_count = function()
    g.server:exec(function()
        local res = box.execute([[EXPLAIN (ANALYZE {'mode': 'hits'}, opcode)
                                  INSERT INTO t SELECT id + 10, a FROM t;]])
        t.assert_equals(tonumber(res.rows[1][1]), 1)
        local counts = {}
        for _, row in ipairs(res.rows) do
            if row[3]:find('IdxInsert') then
                table.insert(counts, tonumber(row[1]))
            end
        end
        t.assert_items_include(counts, {10})
        t.assert_equals(box.space.T:count(), 20)
    end)
end

-- A measurement is a text that is aligned to the right in the width of
-- the name of its column, and in at least 5 characters.
g.test_count_alignment = function()
    g.server:exec(function()
        local res = box.execute([[EXPLAIN (ANALYZE ['hits', 'samples'])
                                  SELECT a FROM t;]])
        for _, row in ipairs(res.rows) do
            t.assert_str_matches(row[1], ' *[%d.]+%a?')
            t.assert_equals(#row[1], 5)
            t.assert_str_matches(row[2], ' *[%d.]+%a?')
            t.assert_equals(#row[2], #'samples')
        end
    end)
end

-- EXPLAIN ANALYZE runs the program that EXPLAIN shows: the two list the
-- same opcodes at the same addresses. The IN operator has an instruction
-- that only holds a comment, which only a statement under EXPLAIN has.
g.test_program_of_explain = function()
    g.server:exec(function()
        local function program(facets)
            local sql = [[EXPLAIN (%s, opcode)
                          SELECT a FROM t WHERE a IN (1, 2);]]
            local res = box.execute(sql:format(facets))
            local opcode_no
            for i, meta in ipairs(res.metadata) do
                if meta.name == 'opcode' then
                    opcode_no = i
                end
            end
            local lines = {}
            for _, row in ipairs(res.rows) do
                table.insert(lines, row[opcode_no - 1] .. ' ' .. row[opcode_no])
            end
            return lines
        end
        local lines = program('pseudocode')
        t.assert_equals(program([[ANALYZE {'mode': 'hits'}]]), lines)
        local noop_count = 0
        for _, line in ipairs(lines) do
            if line:find(' Noop$') then
                noop_count = noop_count + 1
            end
        end
        t.assert_equals(noop_count, 1)
    end)
end

-- The samples need a signal of the process. If another part of the
-- process uses the signal, the statement fails and does not run. Here the
-- test sets the action of the signal to "ignore".
g.test_sample_signal_in_use = function()
    t.skip_if(jit.os ~= 'Linux', 'needs the signals of Linux')
    g.server:exec(function()
        local ffi = require('ffi')
        ffi.cdef([[
            int __libc_current_sigrtmin(void);
            void *signal(int signum, void *handler);
        ]])
        local signo = ffi.C.__libc_current_sigrtmin()
        local sig_dfl = ffi.cast('void *', 0)
        local sig_ign = ffi.cast('void *', 1)
        local sql = [[EXPLAIN ANALYZE INSERT INTO t VALUES (100, 100);]]
        ffi.C.signal(signo, sig_ign)
        local res, err = box.execute(sql)
        local hits = box.execute([[EXPLAIN (ANALYZE {'mode': 'hits'})
                                   SELECT 1;]])
        -- The action of the signal is not changed.
        local action = ffi.C.signal(signo, sig_dfl)
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'EXPLAIN ANALYZE cannot ' ..
                              'sample the instructions')
        t.assert_equals(box.space.T:get({100}), nil)
        t.assert_gt(#hits.rows, 0)
        t.assert_equals(action, sig_ign)
        -- With the default action the statement runs, and the signal
        -- has the default action again after it.
        res, err = box.execute(sql)
        action = ffi.C.signal(signo, sig_dfl)
        box.space.T:delete({100})
        t.assert_equals(err, nil)
        t.assert_gt(#res.rows, 0)
        t.assert_equals(action, sig_dfl)
    end)
end

-- The time of the statements that a function of an instruction runs is
-- the time of this instruction, also when they are not in their own
-- instructions: here the function lists the program of EXPLAIN for half
-- a second of CPU time.
g.test_samples_of_nested_statements = function()
    g.server:exec(function()
        box.schema.func.create('INNER_EXPLAIN', {
            language = 'LUA',
            body = [[function()
                local clock = require('clock')
                local stmt = box.prepare('EXPLAIN (opcode, pseudocode) ' ..
                    'SELECT t1.a, count(*) FROM t AS t1 JOIN t AS t2 ' ..
                    'ON t1.a = t2.id GROUP BY t1.a ORDER BY 2;')
                local deadline = clock.proc() + 0.5
                while clock.proc() < deadline do
                    stmt:execute()
                end
                stmt:unprepare()
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        local res, err = box.execute([[EXPLAIN (ANALYZE, opcode)
                                       SELECT inner_explain();]])
        box.schema.func.drop('INNER_EXPLAIN')
        t.assert_equals(err, nil)
        local samples = 0
        for _, row in ipairs(res.rows) do
            if row[3]:find('Function') ~= nil then
                samples = samples + tonumber(row[1])
            end
        end
        -- 99 samples in a second.
        t.assert_ge(samples, 44)
        t.assert_le(samples, 60)
    end)
end

-- The frequency of the samples is an integer from 1 to 1000.
g.test_freq_value = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'freq' must be an integer from 1 to 1000"
        for _, value in ipairs({'0', '-1', '1.5', "'1'", '1001'}) do
            local columns = _G.measure_columns(("{'freq': %s}"):format(value))
            t.assert_str_contains(columns, msg, false, value)
        end
        t.assert_equals(_G.measure_columns("{'freq': 1}"), {'samples'})
        t.assert_equals(_G.measure_columns("{'freq': 1000}"), {'samples'})
    end)
end

-- EXPLAIN ANALYZE does not take the statements that control the
-- transaction or the session, and the statements that change the schema.
-- EXPLAIN without the facet shows their programs.
g.test_forbidden_statements = function()
    g.server:exec(function()
        local ctl = 'a statement that controls the transaction or the ' ..
                    'session'
        local ddl = 'a statement that changes the schema'
        local statements = {
            {ctl, [[START TRANSACTION;]]},
            {ctl, [[COMMIT;]]},
            {ctl, [[ROLLBACK;]]},
            {ctl, [[SAVEPOINT s;]]},
            {ctl, [[RELEASE SAVEPOINT s;]]},
            {ctl, [[RELEASE s;]]},
            {ctl, [[ROLLBACK TO SAVEPOINT s;]]},
            {ctl, [[ROLLBACK TO s;]]},
            {ctl, [[SET SESSION "sql_seq_scan" = false;]]},
            {ddl, [[CREATE TABLE c (id INT PRIMARY KEY);]]},
            {ddl, [[DROP TABLE t;]]},
            {ddl, [[CREATE VIEW v AS SELECT a FROM t;]]},
            {ddl, [[DROP VIEW w;]]},
            {ddl, [[CREATE INDEX i ON t(a);]]},
            {ddl, [[DROP INDEX j ON t;]]},
            {ddl, [[CREATE TRIGGER r AFTER INSERT ON t
                    FOR EACH ROW BEGIN SELECT 1; END;]]},
            {ddl, [[DROP TRIGGER q;]]},
            {ddl, [[ALTER TABLE t ADD COLUMN b INT;]]},
            {ddl, [[ALTER TABLE t ADD CONSTRAINT c
                    FOREIGN KEY (a) REFERENCES t(id);]]},
            {ddl, [[ALTER TABLE t ADD CONSTRAINT c CHECK (a > 0);]]},
            {ddl, [[ALTER TABLE t ADD CONSTRAINT c UNIQUE (a);]]},
            {ddl, [[ALTER TABLE t RENAME TO c;]]},
            {ddl, [[ALTER TABLE t DROP CONSTRAINT k;]]},
        }
        local prefixes = {
            [[EXPLAIN ANALYZE]],
            [[EXPLAIN (ANALYZE)]],
            [[EXPLAIN (opcode, ANALYZE {'mode': 'hits'})]],
            [[EXPLAIN (ANALYZE {'freq': 10})]],
        }
        box.execute([[CREATE VIEW w AS SELECT a FROM t;]])
        box.execute([[CREATE INDEX j ON t(a);]])
        box.execute([[CREATE TRIGGER q AFTER INSERT ON t
                      FOR EACH ROW BEGIN SELECT 1; END;]])
        box.execute([[ALTER TABLE t ADD CONSTRAINT k CHECK (a > 0);]])
        for _, statement in ipairs(statements) do
            local msg = 'EXPLAIN ANALYZE cannot run ' .. statement[1]
            for _, prefix in ipairs(prefixes) do
                local sql = prefix .. ' ' .. statement[2]
                local res, err = box.prepare(sql)
                t.assert_equals(res, nil, sql)
                t.assert_str_contains(err.message, msg, false, sql)
            end
            local res, err = box.prepare('EXPLAIN ' .. statement[2])
            t.assert_equals(err, nil, statement[2])
            res:unprepare()
        end
        box.execute([[ALTER TABLE t DROP CONSTRAINT k;]])
        box.execute([[DROP TRIGGER q;]])
        box.execute([[DROP INDEX j ON t;]])
        box.execute([[DROP VIEW w;]])
    end)
end

-- A forbidden statement does not run: here the transaction stays open.
g.test_forbidden_statement_does_not_run = function()
    g.server:exec(function()
        for _, statement in ipairs({'COMMIT', 'ROLLBACK'}) do
            box.begin()
            box.space.T:insert({100, 100})
            local res, err = box.execute('EXPLAIN ANALYZE ' .. statement)
            local is_in_txn = box.is_in_txn()
            box.rollback()
            t.assert_equals(res, nil)
            t.assert_str_contains(err.message, 'EXPLAIN ANALYZE cannot run')
            t.assert(is_in_txn)
        end
        t.assert_equals(box.space.T:get({100}), nil)
    end)
end

-- EXPLAIN ANALYZE takes TRUNCATE and PRAGMA.
g.test_truncate_and_pragma = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE tr (id INT PRIMARY KEY);]])
        box.space.TR:insert({1})
        local res, err = box.execute([[EXPLAIN (ANALYZE {'mode': 'hits'})
                                       TRUNCATE TABLE tr;]])
        local count = box.space.TR:count()
        box.execute([[DROP TABLE tr;]])
        t.assert_equals(err, nil)
        t.assert_gt(#res.rows, 0)
        t.assert_equals(count, 0)
        res, err = box.execute([[EXPLAIN ANALYZE PRAGMA table_info(t);]])
        t.assert_equals(err, nil)
        t.assert_gt(#res.rows, 0)
    end)
end

-- If the samples cannot start, the statement fails and does not run. Here
-- the limit of the pending signals of the process makes the creation of
-- the timer fail. A statement that does not sample runs.
g.test_sample_start_error = function()
    t.skip_if(jit.os ~= 'Linux', 'needs the signal limit of Linux')
    g.server:exec(function()
        local ffi = require('ffi')
        ffi.cdef([[
            struct test_rlimit { unsigned long cur; unsigned long max; };
            int getrlimit(int resource, struct test_rlimit *limit);
            int setrlimit(int resource, const struct test_rlimit *limit);
            unsigned int geteuid(void);
        ]])
        t.skip_if(ffi.C.geteuid() == 0, 'the limit is not for root')
        local RLIMIT_SIGPENDING = 11
        local limit = ffi.new('struct test_rlimit')
        t.assert_equals(ffi.C.getrlimit(RLIMIT_SIGPENDING, limit), 0)
        local saved = limit.cur
        local sql = [[EXPLAIN ANALYZE INSERT INTO t VALUES (100, 100);]]
        local stmt = box.prepare(sql)
        limit.cur = 0
        t.assert_equals(ffi.C.setrlimit(RLIMIT_SIGPENDING, limit), 0)
        local res, err = stmt:execute()
        local hits = box.execute([[EXPLAIN (ANALYZE {'mode': 'hits'})
                                   SELECT 1;]])
        limit.cur = saved
        t.assert_equals(ffi.C.setrlimit(RLIMIT_SIGPENDING, limit), 0)
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'EXPLAIN ANALYZE cannot ' ..
                              'sample the instructions')
        t.assert_equals(box.space.T:get({100}), nil)
        t.assert_gt(#hits.rows, 0)
        -- The statement runs again when the samples can start.
        res, err = stmt:execute()
        box.space.T:delete({100})
        t.assert_equals(err, nil)
        t.assert_gt(#res.rows, 0)
        -- The statement ran in its own transaction. Now it fails in a
        -- transaction of the user: the transaction stays open.
        box.begin()
        box.space.T:insert({101, 101})
        limit.cur = 0
        t.assert_equals(ffi.C.setrlimit(RLIMIT_SIGPENDING, limit), 0)
        res, err = stmt:execute()
        limit.cur = saved
        t.assert_equals(ffi.C.setrlimit(RLIMIT_SIGPENDING, limit), 0)
        local is_in_txn = box.is_in_txn()
        local row = box.space.T:get({101})
        box.rollback()
        stmt:unprepare()
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'EXPLAIN ANALYZE cannot ' ..
                              'sample the instructions')
        t.assert(is_in_txn)
        t.assert_equals(row, {101, 101})
    end)
end

-- The statement can drop its trigger while it runs, and another fiber can
-- drop it while the statement waits. The listing after the run does not
-- use the dropped trigger: it has its own copy of the name.
g.test_trigger_dropped_in_run = function()
    g.server:exec(function()
        local fiber = require('fiber')
        box.schema.func.create('DROP_TR', {
            language = 'LUA',
            body = [[function()
                box.execute('DROP TRIGGER tr;')
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        -- It does not read the database: a read and then a wait abort
        -- the transaction of the statement.
        box.schema.func.create('WAIT_NO_TR', {
            language = 'LUA',
            body = [[function()
                while not rawget(_G, 'is_tr_dropped') do
                    require('fiber').sleep(0.01)
                end
                return 1
            end]],
            returns = 'integer',
            exports = {'LUA', 'SQL'},
        })
        local function run(func)
            local sql = ([[EXPLAIN (ANALYZE {'mode': 'hits'}, opcode)
                           INSERT INTO t VALUES (100, %s());]]):format(func)
            local res, err = box.execute(sql)
            local trigger_count = box.space._trigger:count()
            box.space.T:delete({100})
            t.assert_equals(err, nil, func)
            t.assert_equals(trigger_count, 0, func)
            local p4
            for _, row in ipairs(res.rows) do
                if row[3] == 'Program' then
                    p4 = row[7]
                end
            end
            t.assert_equals(p4, 'trigger TR', func)
        end
        local create = [[CREATE TRIGGER tr AFTER INSERT ON t
                         FOR EACH ROW BEGIN SELECT 1; END;]]
        box.execute(create)
        run('DROP_TR')

        -- The fiber starts when the statement waits.
        box.execute(create)
        local f = fiber.new(function()
            box.execute([[DROP TRIGGER tr;]])
            rawset(_G, 'is_tr_dropped', true)
        end)
        f:set_joinable(true)
        run('WAIT_NO_TR')
        f:join()
        rawset(_G, 'is_tr_dropped', nil)
        box.schema.func.drop('DROP_TR')
        box.schema.func.drop('WAIT_NO_TR')
    end)
end
