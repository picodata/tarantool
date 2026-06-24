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

-- A descending part actually orders rows: select() and the iterators
-- return them largest-first, and a desc range scan walks down.
gd.test_desc_select_order = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned', sort_order = 'desc'}}})
        for i = 1, 5 do s:insert({i}) end
        t.assert_equals(s:select(), {{5}, {4}, {3}, {2}, {1}})
        t.assert_equals(s.index.pk:min(), {5}, 'min is the desc-first key')
        t.assert_equals(s.index.pk:max(), {1}, 'max is the desc-last key')
        -- GE in descending order walks from 3 down.
        t.assert_equals(s.index.pk:select({3}, {iterator = 'GE'}),
                        {{3}, {2}, {1}})
    end, {cg.params.engine})
end

-- Altering a part from asc to desc rebuilds the index into the new
-- physical order, and back again.
gd.test_alter_reorders = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false,
                                         parts = {{2, 'unsigned'}}})
        for i = 1, 4 do s:insert({i, i}) end
        t.assert_equals(sk:select(), {{1, 1}, {2, 2}, {3, 3}, {4, 4}})
        sk:alter({parts = {{2, 'unsigned', sort_order = 'desc'}}})
        t.assert_equals(sk:select(), {{4, 4}, {3, 3}, {2, 2}, {1, 1}})
        sk:alter({parts = {{2, 'unsigned', sort_order = 'asc'}}})
        t.assert_equals(sk:select(), {{1, 1}, {2, 2}, {3, 3}, {4, 4}})
    end, {cg.params.engine})
end

-- A desc secondary key shares its field with the asc primary key. The
-- merged cmp_def keeps the secondary's desc order on that field, while
-- the appended pk suffix (asc) breaks ties among equal secondary keys.
-- A full-tuple read via the secondary still resolves through the pk.
gd.test_desc_sk_asc_pk_merge = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}, {2, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false,
            parts = {{2, 'unsigned', sort_order = 'desc'}}})
        -- field 2 takes values 1 and 2, each with several pk tie-breakers.
        s:insert({10, 2}) s:insert({20, 2}) s:insert({30, 1})
        s:insert({40, 1}) s:insert({50, 2})
        -- Ordered by field 2 desc, then by the asc pk suffix (1, 2) asc.
        t.assert_equals(sk:select(), {
            {10, 2}, {20, 2}, {50, 2},
            {30, 1}, {40, 1},
        })
        -- A point lookup on the desc secondary still returns full tuples.
        t.assert_equals(sk:select({2}), {{10, 2}, {20, 2}, {50, 2}})
    end, {cg.params.engine})
end

-- A descending nullable part sorts NULLs last. Tarantool treats NULL as
-- the smallest value (NULLs first when ascending), so reversing the order
-- moves them to the end -- the SQLite/PostgreSQL default for DESC. Ties
-- among equal keys (including among NULLs) break by the ascending pk.
gd.test_desc_nullable_nulls_last = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false, parts = {
            {2, 'unsigned', is_nullable = true, sort_order = 'desc'}}})
        s:insert({1, 2})
        s:insert({2, box.NULL})
        s:insert({3, 1})
        s:insert({4, box.NULL})
        t.assert_equals(sk:select(), {
            {1, 2}, {3, 1},            -- values, descending
            {2, box.NULL}, {4, box.NULL}, -- NULLs last, pk-ascending
        })
    end, {cg.params.engine})
end

-- A descending part whose field is absent from a shorter tuple
-- (has_optional_parts): the absent field is treated as NULL, so it sorts
-- last under descending order, same as an explicit NULL.
gd.test_desc_optional = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false, parts = {
            {3, 'unsigned', is_nullable = true, sort_order = 'desc'}}})
        s:insert({1, 'a', 2})
        s:insert({2, 'b'})       -- field 3 absent -> optional NULL
        s:insert({3, 'c', 1})
        t.assert_equals(sk:select(), {{1, 'a', 2}, {3, 'c', 1}, {2, 'b'}})
    end, {cg.params.engine})
end

-- A descending part addressed by a JSON path.
gd.test_desc_json_path = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false, parts = {
            {field = 2, type = 'unsigned', path = 'x', sort_order = 'desc'}}})
        s:insert({1, {x = 2}})
        s:insert({2, {x = 1}})
        s:insert({3, {x = 3}})
        t.assert_equals(sk:select(),
                        {{3, {x = 3}}, {1, {x = 2}}, {2, {x = 1}}})
    end, {cg.params.engine})
end

-- A descending multikey part: every array element is a key, and the keys
-- are walked largest-first.
gd.test_desc_multikey = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false, parts = {
            {field = 2, type = 'unsigned', path = '[*]', sort_order = 'desc'}}})
        s:insert({1, {3, 1}})
        s:insert({2, {2}})
        -- flattened keys 3, 1 (tuple 1) and 2 (tuple 2); descending: 3, 2, 1
        t.assert_equals(sk:select(), {{1, {3, 1}}, {2, {2}}, {1, {3, 1}}})
    end, {cg.params.engine})
end

-- Mixed directions across parts (desc, asc, desc): each part's sign is
-- applied independently, which is exactly what the per-part comparator
-- (not a whole-result negate) is for.
gd.test_mixed_sort_order = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{4, 'unsigned'}}})
        local sk = s:create_index('sk', {parts = {
            {1, 'unsigned', sort_order = 'desc'},
            {2, 'unsigned', sort_order = 'asc'},
            {3, 'unsigned', sort_order = 'desc'},
        }})
        local id = 0
        for i = 1, 2 do
            for j = 1, 2 do
                for k = 1, 2 do
                    id = id + 1
                    s:insert({i, j, k, id})
                end
            end
        end
        -- field1 desc, then field2 asc, then field3 desc.
        t.assert_equals(sk:select(), {
            {2, 1, 2, 6}, {2, 1, 1, 5}, {2, 2, 2, 8}, {2, 2, 1, 7},
            {1, 1, 2, 2}, {1, 1, 1, 1}, {1, 2, 2, 4}, {1, 2, 1, 3},
        })
    end, {cg.params.engine})
end

-- Descending on a number part orders the float extremes correctly: the
-- hint reversal (HINT_MAX - hint) must keep +inf first and -inf last.
gd.test_desc_number_infinities = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'number', sort_order = 'desc'}}})
        s:insert({math.huge})
        s:insert({-math.huge})
        s:insert({1e100})
        t.assert_equals(s:select(), {{math.huge}, {1e100}, {-math.huge}})
    end, {cg.params.engine})
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

-- A functional index does not support descending sort order: the function
-- supplies the key and thus its order, so a descending part is redundant
-- and rejected at definition time.
gr.test_func_index_desc_rejected = function(cg)
    cg.server:exec(function()
        box.schema.func.create('sort_order_extract', {
            body = 'function(t) return {t[2]} end',
            is_deterministic = true,
            is_sandboxed = true,
        })
        local s = box.schema.space.create('test')
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        t.assert_error_msg_contains(
            'Functional index does not support descending sort order',
            function()
                s:create_index('fi', {func = 'sort_order_extract',
                    parts = {{1, 'unsigned', sort_order = 'desc'}}})
            end)
        box.schema.func.drop('sort_order_extract')
    end)
end

-- Changing a part's sort order changes physical order, so the index must be
-- rebuilt rather than updated in place. test_alter_reorders checks the
-- resulting order; this isolates the rebuild *decision*: the alter is
-- observed to enter the build path via ERRINJ_BUILD_INDEX, while an alter
-- that leaves sort order unchanged does not. Debug-build only.
local grb = t.group('sort_order.rebuild', t.helpers.matrix({
    engine = {'memtx', 'vinyl'},
}))

grb.before_all(function(cg)
    t.tarantool.skip_if_not_debug()
    cg.server = server:new()
    cg.server:start()
end)

grb.after_all(function(cg)
    cg.server:drop()
end)

grb.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then box.space.test:drop() end
    end)
end)

grb.test_alter_sort_order_requires_rebuild = function(cg)
    cg.server:exec(function(engine)
        local s = box.schema.space.create('test', {engine = engine})
        s:create_index('pk', {parts = {{1, 'unsigned'}}})
        local sk = s:create_index('sk', {unique = false,
                                         parts = {{2, 'unsigned'}}})
        for i = 1, 5 do s:insert({i, i}) end

        -- ERRINJ_BUILD_INDEX fails the build of the index with this iid.
        box.error.injection.set('ERRINJ_BUILD_INDEX', sk.id)
        -- Flipping to desc requires a rebuild, so it enters the build path
        -- and trips the injection.
        t.assert_error_msg_contains('build index', function()
            sk:alter({parts = {{2, 'unsigned', sort_order = 'desc'}}})
        end)
        -- Re-stating the same (asc) order changes nothing, so no rebuild is
        -- triggered and the injection is never reached.
        sk:alter({parts = {{2, 'unsigned', sort_order = 'asc'}}})
        box.error.injection.set('ERRINJ_BUILD_INDEX', -1)
    end, {cg.params.engine})
end
