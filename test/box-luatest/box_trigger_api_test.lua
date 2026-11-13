local t = require('luatest')
local server = require('luatest.server')

-- Commit and rollback triggers walk the statements of the transaction
-- through the exported statement accessors. The trigger lists have no Lua
-- surface, so the C trigger API is driven through FFI.
local g = t.group('box_txn_stmt_iteration')

g.before_all(function(cg)
    cg.server = server:new({alias = 'stmt_iteration'})
    cg.server:start()
    cg.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        ffi.cdef([[
            struct rlist { struct rlist *prev; struct rlist *next; };
            struct trigger {
                struct rlist link;
                struct rlist run_links;
                int (*run)(struct trigger *, void *);
                void *data;
                void (*destroy)(struct trigger *);
            };
            struct space *space_by_id(uint32_t id);
            struct rlist *box_space_on_replace(struct space *space);
            struct rlist *box_txn_on_commit(struct txn *txn);
            struct rlist *box_txn_on_rollback(struct txn *txn);
            void box_trigger_create(struct trigger *trigger,
                                    int (*run)(struct trigger *, void *),
                                    void *data,
                                    void (*destroy)(struct trigger *));
            void box_trigger_add(struct rlist *list, struct trigger *trigger);
            struct txn_stmt *box_txn_stmt_next(struct txn_stmt *stmt);
            uint32_t box_txn_stmt_space_id(struct txn_stmt *stmt);
            box_tuple_t *box_txn_stmt_old_tuple(struct txn_stmt *stmt);
            box_tuple_t *box_txn_stmt_new_tuple(struct txn_stmt *stmt);
        ]])
        local C = ffi.C

        local test = box.schema.space.create('test')
        test:create_index('pk')
        box.schema.space.create('other'):create_index('pk')
        test:on_replace(function(_, new)
            if new ~= nil and new[1] == 13 then
                box.error(box.error.ILLEGAL_PARAMS, 'unlucky key')
            end
        end)

        local function decode(tuple)
            if tuple == nil then
                return box.NULL
            end
            local size = tonumber(C.box_tuple_bsize(tuple))
            local buf = ffi.new('char[?]', size)
            C.box_tuple_to_buf(tuple, buf, size)
            return (msgpack.decode(ffi.cast('char *', buf), size))
        end
        local function walk(stmt)
            local stmts = {}
            while stmt ~= nil do
                table.insert(stmts, {
                    tonumber(C.box_txn_stmt_space_id(stmt)),
                    decode(C.box_txn_stmt_old_tuple(stmt)),
                    decode(C.box_txn_stmt_new_tuple(stmt)),
                })
                stmt = C.box_txn_stmt_next(stmt)
            end
            return stmts
        end

        -- What the triggers of the last transaction saw: the walk from
        -- the event.
        local seen = {}
        local armed_txn
        -- The triggers and the callbacks are reached from C after this
        -- function returns, so they have to outlive it.
        local keepalive = {}
        local function on_end(kind)
            return ffi.cast('int (*)(struct trigger *, void *)',
                function(_, event)
                    -- An error raised from a callback would crash the
                    -- server, so it is recorded instead.
                    local ok, err = pcall(walk,
                        ffi.cast('struct txn_stmt *', event))
                    seen[kind] = ok and err or tostring(err)
                    armed_txn = nil
                    return 0
                end)
        end
        keepalive.commit = ffi.new('struct trigger')
        keepalive.rollback = ffi.new('struct trigger')
        keepalive.run_commit = on_end('commit')
        keepalive.run_rollback = on_end('rollback')
        -- Arm the transaction from an on_replace trigger of space test,
        -- the only place that hands out the transaction, once per
        -- transaction.
        keepalive.arm = ffi.cast('int (*)(struct trigger *, void *)',
            function(_, event)
                if armed_txn ~= nil then
                    return 0
                end
                armed_txn = ffi.cast('struct txn *', event)
                C.box_trigger_create(keepalive.commit, keepalive.run_commit,
                                     nil, nil)
                C.box_trigger_add(C.box_txn_on_commit(armed_txn),
                                  keepalive.commit)
                C.box_trigger_create(keepalive.rollback,
                                     keepalive.run_rollback, nil, nil)
                C.box_trigger_add(C.box_txn_on_rollback(armed_txn),
                                  keepalive.rollback)
                return 0
            end)
        keepalive.on_replace = ffi.new('struct trigger')
        C.box_trigger_create(keepalive.on_replace, keepalive.arm, nil, nil)
        C.box_trigger_add(C.box_space_on_replace(C.space_by_id(test.id)),
                          keepalive.on_replace)
        rawset(_G, 'stmt_iteration_keepalive', keepalive)
        rawset(_G, 'stmt_iteration_seen', function()
            local s = seen
            seen = {}
            return s
        end)
        -- The space ids the triggers of the last transaction saw.
        rawset(_G, 'stmt_iteration_space_ids', function(kind)
            local space_ids = {}
            for _, stmt in ipairs(seen[kind]) do
                table.insert(space_ids, stmt[1])
            end
            seen = {}
            return space_ids
        end)
    end)
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.before_each(function(cg)
    cg.server:exec(function()
        box.space.test:truncate()
        box.space.other:truncate()
        _G.stmt_iteration_seen()
    end)
end)

-- A commit trigger walks the statements in the order they were executed,
-- each with its space and its tuples.
g.test_commit = function(cg)
    cg.server:exec(function()
        local test, other = box.space.test.id, box.space.other.id
        box.space.test:insert{1}
        _G.stmt_iteration_seen()
        box.begin()
        box.space.other:insert{2}
        box.space.test:replace{1, 'a'}
        box.space.test:delete{1}
        box.commit()
        local stmts = {
            {other, box.NULL, {2}},
            {test, {1}, {1, 'a'}},
            {test, {1, 'a'}, box.NULL},
        }
        t.assert_equals(_G.stmt_iteration_seen(), {commit = stmts})
    end)
end

-- Statements rolled back to a savepoint, or by a failed on_replace
-- trigger, are no longer in the transaction, and such a partial rollback
-- runs no rollback trigger.
g.test_partial_rollback = function(cg)
    cg.server:exec(function()
        local test, other = box.space.test.id, box.space.other.id
        box.begin()
        box.space.test:insert{1}
        local savepoint = box.savepoint()
        box.space.other:insert{2}
        box.space.test:insert{3}
        box.rollback_to_savepoint(savepoint)
        t.assert_error_covers({code = box.error.ILLEGAL_PARAMS},
                              box.space.test.insert, box.space.test, {13})
        box.space.other:insert{4}
        box.commit()
        local stmts = {
            {test, box.NULL, {1}},
            {other, box.NULL, {4}},
        }
        t.assert_equals(_G.stmt_iteration_seen(), {commit = stmts})
    end)
end

-- A rollback trigger walks the statements newest first.
g.test_rollback = function(cg)
    cg.server:exec(function()
        local test, other = box.space.test.id, box.space.other.id
        box.begin()
        box.space.test:insert{1}
        box.space.other:insert{2}
        box.space.test:replace{1, 'a'}
        box.rollback()
        t.assert_equals(_G.stmt_iteration_seen(), {rollback = {
            {test, {1}, {1, 'a'}},
            {other, box.NULL, {2}},
            {test, box.NULL, {1}},
        }})
    end)
end

-- A yield between statements aborts a memtx transaction that runs without
-- MVCC. The rollback trigger walks the statements newest first.
g.test_rollback_on_yield = function(cg)
    cg.server:exec(function()
        local fiber = require('fiber')
        local test, other = box.space.test.id, box.space.other.id
        box.begin()
        box.space.test:insert{1}
        box.space.other:insert{2}
        fiber.sleep(0)
        box.rollback()
        t.assert_equals(_G.stmt_iteration_seen(), {rollback = {
            {other, box.NULL, {2}},
            {test, box.NULL, {1}},
        }})
    end)
end

-- The rollback undoes the statements before the rollback trigger runs.
-- The undo of a DDL statement frees the space object that the later
-- statements of the transaction point to, but the trigger still gets
-- the space id of each statement.
g.test_space_id_on_rollback_after_rename = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('ddl')
        s:create_index('pk')
        local ddl, test = s.id, box.space.test.id
        box.begin()
        box.space.test:insert{1}
        s:rename('ddl_renamed')
        box.space.ddl_renamed:insert{1}
        box.rollback()
        local space_ids = _G.stmt_iteration_space_ids('rollback')
        s:drop()
        t.assert_equals(space_ids, {ddl, box.schema.SPACE_ID, test})
    end)
end

-- The same for a space created in the transaction.
g.test_space_id_on_rollback_after_create = function(cg)
    cg.server:exec(function()
        local test = box.space.test.id
        box.begin()
        box.space.test:insert{1}
        local s = box.schema.space.create('ddl')
        s:create_index('pk')
        s:insert{1}
        local ddl = s.id
        box.rollback()
        t.assert_equals(box.space.ddl, nil)
        local space_ids = _G.stmt_iteration_space_ids('rollback')
        t.assert_equals(space_ids, {
            ddl, box.schema.INDEX_ID, box.schema.SPACE_ID, test,
        })
    end)
end
