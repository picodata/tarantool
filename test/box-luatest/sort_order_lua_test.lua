-- Wiring of a key part's sort_order through the Lua surface: it can be
-- specified on index creation and via the key_def module, it is
-- persisted to _index, and it is shown back on the index object and in
-- key_def:totable(). This does not test that descending order changes
-- iteration -- the comparator still ignores it; that is a separate step.
--
-- The create/alter/restart cases run on both engines: only vinyl walks
-- key_def_find_pk_in_cmp_def, where a part's sort_order has to be carried
-- through key_def_dump_parts rather than read from uninitialized memory.
-- The boundary-rejection cases reject before the engine is involved, so
-- they run once.

local server = require('luatest.server')
local t = require('luatest')

-- Schema mutations: meaningful on both engines.
local gd = t.group('sort_order.ddl', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

gd.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

gd.after_all(function(cg)
    cg.server:drop()
end)

gd.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then box.space.test:drop() end
    end)
end)

-- A descending part is accepted, persisted to _index verbatim, and shown
-- on the index object. Ascending parts keep the previous representation
-- (no sort_order field), so existing indexes are unaffected. A secondary
-- index is created too: on vinyl that triggers the pk-from-cmp_def
-- extraction, which must carry sort_order through dump_parts.
gd.test_index_parts = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        local pk = s:create_index('pk', {parts = {
            {1, 'unsigned', sort_order = 'desc'},
            {2, 'unsigned', sort_order = 'asc'},
            {3, 'unsigned'},
        }})
        t.assert_equals(pk.parts[1].sort_order, 'desc')
        t.assert_equals(pk.parts[2].sort_order, nil, 'asc omitted')
        t.assert_equals(pk.parts[3].sort_order, nil, 'default omitted')
        local sk = s:create_index('sk', {parts = {
            {2, 'unsigned', sort_order = 'desc'},
        }})
        t.assert_equals(sk.parts[1].sort_order, 'desc')
        -- Stored verbatim in _index.
        local stored = box.space._index:get{s.id, pk.id}[6]
        t.assert_equals(stored[1].sort_order, 'desc')
        t.assert_equals(stored[2].sort_order, 'asc')
        t.assert_equals(stored[3].sort_order, nil)
    end, {cg.params.engine})
end

-- A space's index can be altered to give a part descending order.
gd.test_alter = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk')
        s:create_index('sk', {parts = {{2, 'unsigned'}}})
        t.assert_equals(s.index.sk.parts[1].sort_order, nil)
        s.index.sk:alter({parts = {{2, 'unsigned', sort_order = 'desc'}}})
        t.assert_equals(s.index.sk.parts[1].sort_order, 'desc')
    end, {cg.params.engine})
end

-- The descending order is a property of the stored schema, so it
-- survives a snapshot and restart. On vinyl this confirms it comes back
-- from the replayed _index tuple, not just from a memtx snapshot.
gd.test_survives_restart = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned', sort_order = 'desc'}}})
        box.snapshot()
    end, {cg.params.engine})
    cg.server:restart()
    cg.server:exec(function()
        t.assert_equals(box.space.test.index.pk.parts[1].sort_order, 'desc')
    end)
end

-- Boundary rejection: undef and unknown strings are rejected before the
-- engine is chosen, so a single run covers it.
local gr = t.group('sort_order.reject')

gr.before_all(function(cg)
    cg.server = server:new()
    cg.server:start()
end)

gr.after_all(function(cg)
    cg.server:drop()
end)

gr.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then box.space.test:drop() end
    end)
end)

-- The key_def module accepts sort_order and emits it from totable, and
-- the table round-trips back into a new key_def. The module takes the
-- named part form ({fieldno = .., type = ..}).
gr.test_key_def_module = function(cg)
    cg.server:exec(function()
        local key_def = require('key_def')
        local kd = key_def.new({
            {fieldno = 1, type = 'unsigned', sort_order = 'desc'},
            {fieldno = 2, type = 'unsigned'},
        })
        local tt = kd:totable()
        t.assert_equals(tt[1].sort_order, 'desc')
        t.assert_equals(tt[2].sort_order, nil)
        t.assert_equals(key_def.new(tt):totable()[1].sort_order, 'desc')
    end)
end

-- An unknown sort_order is rejected, on both the key_def module and the
-- index DDL path.
gr.test_invalid = function(cg)
    cg.server:exec(function()
        local key_def = require('key_def')
        -- An unknown string is rejected while mapping it to the enum.
        t.assert_error_msg_contains('Unknown sort order: "up"', function()
            key_def.new({{fieldno = 1, type = 'unsigned', sort_order = 'up'}})
        end)
        -- 'undef' is an internal value, not user-settable; the module
        -- rejects it like an unknown string.
        t.assert_error_msg_contains('Unknown sort order: "undef"', function()
            key_def.new({{fieldno = 1, type = 'unsigned',
                          sort_order = 'undef'}})
        end)
        local s = box.schema.space.create('test')
        t.assert_error(function()
            s:create_index('pk', {parts = {{1, 'unsigned', sort_order = 'up'}}})
        end)
        -- The DDL path rejects 'undef' too (guarded in key_def_decode_parts).
        t.assert_error_msg_contains('unknown sort order', function()
            s:create_index('pk',
                {parts = {{1, 'unsigned', sort_order = 'undef'}}})
        end)
    end)
end

-- A raw insert into _index (bypassing schema.lua) with an undef part is
-- rejected when its parts are decoded -- undef can never reach stored schema.
gr.test_raw_index_insert = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test')
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        t.assert_error_msg_contains('unknown sort order', function()
            box.space._index:insert{
                s.id, 1, 'sk', 'tree', {unique = false},
                {{field = 0, type = 'unsigned', sort_order = 'undef'}}}
        end)
    end)
end
