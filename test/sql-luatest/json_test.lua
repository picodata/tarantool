local replica_set = require('luatest.replica_set')
local server = require('luatest.server')
local t = require('luatest')

-- Every JSON test, one group per area. All the groups but json_replication
-- share the one server started here, and each drops what its tests create,
-- so a group costs no server start of its own. To run one area only, pass
-- its group: luatest test/sql-luatest/json_test.lua json_cast
local json_server

t.before_suite(function()
    json_server = server:new({alias = 'json'})
    json_server:start()
end)

-- A failed start runs this too, and must not hide why it failed.
t.after_suite(function()
    if json_server ~= nil then
        json_server:drop()
    end
end)

--------------------------------------------------------------------------------
-- json_storage
--------------------------------------------------------------------------------

local g = t.group('json_storage')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'T_JSON'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- JSON type recognition in SQL schema.
g.test_json_type_in_schema = function()
    g.server:exec(function()
        box.execute([[
            CREATE TABLE t_json (
                id INT PRIMARY KEY,
                data1 JSON,
                name TEXT,
                meta MAP,
                data2 JSON
            )
        ]])
        local space = box.space.T_JSON
        t.assert_not_equals(space, nil)
        t.assert_equals(space:format()[2].type, 'json')
        t.assert_equals(space:format()[3].type, 'string')
        t.assert_equals(space:format()[4].type, 'map')
        t.assert_equals(space:format()[5].type, 'json')
    end)
end

-- Store a MAP literal as JSON and read it back normalized.
g.test_json_store_map_literal = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(res.metadata[1].type, 'json')
        -- Keys are normalized (sorted); tostring gives canonical JSON text.
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

g.test_json_store_array_literal = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, CAST([3, 1, 2] AS JSON))]=])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(res.rows[1][1]), '[3, 1, 2]')
    end)
end

g.test_json_store_nested = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[
            INSERT INTO t VALUES (1, CAST({'users': [{'name': 'Bob'}]} AS JSON))
        ]=])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(res.rows[1][1]),
                        '{"users": [{"name": "Bob"}]}')
    end)
end

g.test_json_typeof = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a': 1} AS JSON))]])
        local res = box.execute([[SELECT TYPEOF(data) FROM t WHERE id = 1]])
        t.assert_equals(res.rows[1][1], 'json')
    end)
end

-- Reject non-JSON ext types and non-string keys on insert. Nothing is
-- implicitly converted to JSON, so these are refused by the type system rather
-- than by the storage validator, and the message says so.
g.test_json_reject_non_json_types = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])

        local uuid = '11111111-1111-1111-1111-111111111111'
        local res, err = box.execute(
            "INSERT INTO t VALUES (1, CAST('" .. uuid .. "' AS UUID))")
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'to json')

        res, err = box.execute(
            [[INSERT INTO t VALUES (2, CAST('2026-01-01' AS DATETIME))]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'to json')

        res, err = box.execute([[INSERT INTO t VALUES (3, x'DEADBEEF')]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'to json')
    end)
end

-- An integer key is rejected by the cast itself: a JSON object keys on strings.
g.test_json_reject_integer_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local res, err = box.execute(
            [[INSERT INTO t VALUES (1, CAST({1: 'x'} AS JSON))]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'json')
    end)
end

-- QUOTE renders a JSON value as canonical JSON text (the same way it renders
-- MAP/ARRAY) instead of asserting on a non-null JSON value (debug) or returning
-- the literal string 'NULL' (release).
g.test_quote_json = function()
    g.server:exec(function()
        local res = box.execute([[SELECT QUOTE(CAST(42 AS JSON))]])
        t.assert_equals(res.rows[1][1], '42')

        res = box.execute([=[SELECT QUOTE(CAST({'b': 2, 'a': 1} AS JSON))]=])
        t.assert_equals(res.rows[1][1], '{"a": 1, "b": 2}')

        res = box.execute([[SELECT QUOTE(json_null())]])
        t.assert_equals(res.rows[1][1], 'null')
    end)
end

-- A bind reads a JSON cdata's bytes without encoding them, so it trusts them.
-- The value gets checked where it entered Lua instead: msgpack.decode()
-- refuses the wrong spelling, so no cdata a decoder hands out can carry one
-- into a bind, and nothing is stored.
g.test_json_bind_never_stores_unnormalized = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        -- {"b":2,"a":1} with keys unsorted, in its MP_EXT/MP_JSON envelope.
        t.assert_error_msg_contains('not in normal form', function()
            return msgpack.decode('\xc7\x07\x14\x82\xa1\x62\x02\xa1\x61\x01')
        end)
        t.assert_equals(box.space.T:count(), 0)
        box.execute([[DROP TABLE t]])
    end)
end

-- A JSON field default arrives from DDL, which is outside the cluster, so it
-- is normalized before it is stored. Two spellings of one document must give
-- one stored default.
g.test_json_field_default_must_be_normal = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function mk(raw)
            local j = ffi.new('struct mp_json', #raw)
            ffi.copy(j, raw, #raw)
            return j
        end
        -- A default travels inside the _space tuple, so the DDL write is
        -- what checks it: {"b": 1, "a": 2} with unsorted keys is refused.
        t.assert_error_msg_contains('not in normal form', function()
            box.schema.space.create('T', {format = {
                {name = 'id', type = 'unsigned'},
                {name = 'j', type = 'json',
                 default = mk('\x82\xa1b\x01\xa1a\x02')},
            }})
        end)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json',
             default = mk('\x82\xa1a\x02\xa1b\x01')},
        }})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:insert({1})
        t.assert_equals(tostring(s:get(1)[2]), '{"a": 2, "b": 1}')
        s:drop()
    end)
end

-- A nested MP_JSON inside a plain MAP column is normalized on the way in, so
-- ORDER BY over a subscript returns JSONB order and the read path does no
-- work. The assertion is about the STORED bytes: a read-side repair
-- would also produce sorted output here, and would be wrong.
g.test_json_nested_in_map_must_be_normal_on_write = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local unsorted = '\x82\xa1b\x01\xa1a\x02'
        local sorted = '\x82\xa1a\x02\xa1b\x01'
        local function mk(raw)
            local j = ffi.new('struct mp_json', #raw)
            ffi.copy(j, raw, #raw)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP)]])
        -- A MAP column promises nothing about what is inside it, but the
        -- encoder walks the whole value, so depth does not hide the payload.
        t.assert_error_msg_contains('not in normal form', function()
            box.space.T:insert({1, {k = mk(unsorted)}})
        end)
        box.space.T:insert({1, {k = mk(sorted)}})
        -- The stored bytes, not the rendered text: this is the whole test.
        local stored = msgpack.encode(box.space.T:get(1)[2].k)
        t.assert_str_contains(stored, sorted, false,
                              'stored verbatim, not repaired on read')
        local res = box.execute([[SELECT m['k'] FROM t ORDER BY 1]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 2, "b": 1}')
        box.execute([[DROP TABLE t]])
    end)
end

-- A non-minimal encoding is rejected on the way in rather than rewritten, so
-- the field map is always built from the bytes as sent and no shrink can leave
-- a later field's offset stale. The minimal spelling stores and indexes.
g.test_json_shrink_keeps_later_field_offsets = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json'},
            {name = 'tail', type = 'string'},
        }})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:create_index('sk', {parts = {3, 'string'}})
        -- A str8-encoded one-byte key is a non-minimal spelling: rejected,
        -- at decode and, for a forged cdata, at the write.
        local raw = '\x81\xd9\x01a\x01'
        t.assert_error_msg_contains('not in normal form', function()
            return msgpack.object_from_raw('\xc7' .. string.char(#raw) ..
                                           '\x14' .. raw)
        end)
        local ffi = require('ffi')
        local bad = ffi.new('struct mp_json', #raw)
        ffi.copy(bad, raw, #raw)
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, bad, 'tail-value'})
        end)
        -- Its minimal spelling stores, and the later field indexes correctly.
        local good = msgpack.object_from_raw('\xc7\x04\x14\x81\xa1a\x01')
        s:insert({1, good, 'tail-value'})
        t.assert_equals(s.index.sk:get({'tail-value'})[1], 1)
        t.assert_equals(tostring(s:get(1)[2]), '{"a": 1}')
        s:drop()
    end)
end

-- Where the value sits makes no difference: the check reads nothing from the
-- format, so a badly spelled value is refused wherever it is, described by the
-- format or not, at any depth. It goes in through msgpack.object_from_raw, so
-- no Lua serializer tidies it up on the way. The spelling {"b":1,"a":2} has
-- its keys in the wrong order.

--- Raw MP_EXT/MP_JSON for {"b":1,"a":2}, keys unsorted.
local RAW_UNSORTED = [[require('msgpack').object_from_raw(
    '\xc7\x07\x14\x82\xa1b\x01\xa1a\x02')]]

g.test_json_position_nested_in_map_column = function()
    g.server:exec(function(mk)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'm', type = 'map'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {k = loadstring('return ' .. mk)()}})
        end)
        s:drop()
    end, {RAW_UNSORTED})
end

g.test_json_position_nested_in_array_column = function()
    g.server:exec(function(mk)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'a', type = 'array'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {loadstring('return ' .. mk)()}})
        end)
        s:drop()
    end, {RAW_UNSORTED})
end

g.test_json_position_past_end_of_format = function()
    g.server:exec(function(mk)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, loadstring('return ' .. mk)()})
        end)
        s:drop()
    end, {RAW_UNSORTED})
end

g.test_json_position_undescribed_inside_described = function()
    g.server:exec(function(mk)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'data', type = 'any'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        -- The JSON-path part makes the format deep, so the validating tuple
        -- iterator walks the map field; "sibling" is not in the format.
        s:create_index('sk',
            {parts = {{field = 2, path = 'a', type = 'unsigned'}}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {a = 1, sibling = loadstring('return ' .. mk)()}})
        end)
        s:drop()
    end, {RAW_UNSORTED})
end

g.test_json_position_formatless_tuple = function()
    g.server:exec(function(mk)
        -- box.tuple.new trusts its bytes, so it is the Lua encoder in
        -- front of it that refuses this one.
        t.assert_error_msg_contains('not in normal form', function()
            box.tuple.new({1, loadstring('return ' .. mk)()})
        end)
    end, {RAW_UNSORTED})
end

-- A malformed subtype-20 payload is rejected where it arrives. The Lua
-- decoder looks inside an MP_JSON, so these bytes never become a
-- value; forged past it, the write refuses them under the same name.
g.test_json_malformed_rejected_by_the_perimeter = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        -- ext8, len 1, subtype 20, inner = a lone str32 marker whose claimed
        -- length the 1-byte payload cannot satisfy.
        local raw = '\xc7\x01\x14\xdb'
        -- The decode check refuses to build a value out of it at all.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpack.object_from_raw(raw)
        end)
        -- Forged past it, the write refuses it under the same name.
        local ffi = require('ffi')
        local obj = ffi.new('struct mp_json', 1)
        ffi.copy(obj, '\xdb', 1)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        local ok, err = pcall(s.insert, s, {1, obj})
        t.assert_not(ok)
        t.assert_str_contains(tostring(err), 'Invalid JSON value')
        t.assert_equals(s:count(), 0)
        s:drop()
    end)
end

-- A JSON index part is rejected on both engines, by the same check that
-- rejects ANY, ARRAY and MAP.
g.test_json_index_part_rejected = function()
    for _, engine_name in ipairs({'memtx', 'vinyl'}) do
        local ok, err = g.server:exec(function(engine)
            local s = box.schema.space.create('T', {engine = engine,
                format = {{name = 'id', type = 'unsigned'},
                          {name = 'j', type = 'json'}}})
            local ok, err = pcall(s.create_index, s, 'pk',
                                  {parts = {{2, 'json'}}})
            s:drop()
            return ok, tostring(err)
        end, {engine_name})
        t.assert_not(ok, engine_name .. ': a JSON index part is rejected')
        t.assert_str_contains(err, 'is not supported')
    end
end

-- JSON survives a restart byte for byte, on both engines.
-- Recovery performs no JSON walk of its own, so what comes back is what was
-- written; the vinyl half is what would catch a diag or region touch on the
-- reader-thread path.
g.test_json_survives_restart = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        for _, engine in ipairs({'memtx', 'vinyl'}) do
            local s = box.schema.space.create('R_' .. engine,
                {engine = engine, format = {
                    {name = 'id', type = 'unsigned'},
                    {name = 'j', type = 'json'}}})
            s:create_index('pk', {parts = {1, 'unsigned'}})
            -- Stored in normal form, the only form the boundary admits.
            local raw = msgpack.object_from_raw(
                '\xc7\x07\x14\x82\xa1a\x02\xa1b\x01')
            s:insert({1, raw})
            rawset(_G, 'before_' .. engine, msgpack.encode(s:get(1)))
        end
        box.snapshot()
    end)
    g.server:restart()
    g.server:exec(function()
        local msgpack = require('msgpack')
        for _, engine in ipairs({'memtx', 'vinyl'}) do
            local s = box.space['R_' .. engine]
            local after = msgpack.encode(s:get(1))
            t.assert_str_contains(after, '\x82\xa1a\x02\xa1b\x01', false,
                                  engine .. ': stored normalized')
            t.assert_equals(tostring(s:get(1)[2]), '{"a": 2, "b": 1}',
                            engine .. ': renders after restart')
            s:drop()
        end
    end)
end

--------------------------------------------------------------------------------
-- json_normalization
--------------------------------------------------------------------------------

local g = t.group('json_normalization')

g.before_all(function()
    g.server = json_server
end)

-- Render a stored JSON value back to canonical text via a SQL round-trip.
local function stored_json(value_sql)
    return g.server:exec(function(value_sql)
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(string.format(
            [[INSERT INTO t VALUES (1, CAST(%s AS JSON))]], value_sql))
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        local out = tostring(res.rows[1][1])
        box.execute([[DROP TABLE t]])
        return out
    end, {value_sql})
end

-- Object keys are sorted: length-first, then byte-by-byte.
g.test_json_keys_sorted = function()
    t.assert_equals(stored_json("{'b': 1, 'a': 2}"), '{"a": 2, "b": 1}')
end

g.test_json_keys_sorted_length_first = function()
    -- 'aa' (len 2) sorts after 'b' (len 1) despite 'aa' < 'b' bytewise.
    t.assert_equals(stored_json("{'aa': 1, 'b': 2}"), '{"b": 2, "aa": 1}')
end

-- Duplicate keys: last value wins.
g.test_json_duplicate_key_last_wins = function()
    t.assert_equals(stored_json("{'a': 1, 'a': 2}"), '{"a": 2}')
end

g.test_json_duplicate_key_interleaved = function()
    t.assert_equals(stored_json("{'a': 1, 'b': 9, 'a': 2}"), '{"a": 2, "b": 9}')
end

-- Empty containers round-trip.
g.test_json_empty_object = function()
    t.assert_equals(stored_json("{}"), '{}')
end

g.test_json_empty_array = function()
    t.assert_equals(stored_json("[]"), '[]')
end

--------------------------------------------------------------------------------
-- json_null
--------------------------------------------------------------------------------

local g = t.group('json_null')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- json_null() returns a JSON null value, distinct from SQL NULL.
g.test_json_null_basics = function()
    g.server:exec(function()
        local res = box.execute([[SELECT json_null()]])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), 'null')

        -- Unlike SQL NULL, JSON null is a present value.
        res = box.execute([[SELECT json_null() IS NULL]])
        t.assert_equals(res.rows[1][1], false)

        res = box.execute([[SELECT json_null() IS NOT NULL]])
        t.assert_equals(res.rows[1][1], true)
    end)
end

-- json_null() and SQL NULL are distinct, stored values.
g.test_json_null_vs_sql_null_storage = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, json_null())]])
        box.execute([[INSERT INTO t VALUES (2, NULL)]])
        local res = box.execute([[SELECT id, data IS NULL FROM t ORDER BY id]])
        t.assert_equals(#res.rows, 2)
        t.assert_equals(res.rows[1][2], false)  -- json_null() IS NOT NULL
        t.assert_equals(res.rows[2][2], true)   -- SQL NULL IS NULL
        -- The JSON-null row reads back as a JSON null value.
        local back = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(back.rows[1][1]), 'null')
        box.execute([[DROP TABLE t]])
    end)
end

-- JSON null satisfies NOT NULL and is a valid DEFAULT.
g.test_json_null_satisfies_not_null = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON NOT NULL)]])
        -- JSON null is a present value: it satisfies NOT NULL.
        local res = box.execute([[INSERT INTO t VALUES (1, json_null())]])
        t.assert_not_equals(res, nil)
        -- SQL NULL is rejected by NOT NULL.
        local r, err = box.execute([[INSERT INTO t VALUES (2, NULL)]])
        t.assert_equals(r, nil)
        t.assert_str_contains(err.message, 'NOT NULL')
        box.execute([[DROP TABLE t]])
    end)
end

g.test_json_null_default = function()
    g.server:exec(function()
        -- json_null() is a valid DEFAULT for a NOT NULL JSON column.
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY,
            data JSON NOT NULL DEFAULT (json_null()))]])
        box.execute([[INSERT INTO t (id) VALUES (1)]])
        local res = box.execute([[SELECT data IS NULL FROM t WHERE id = 1]])
        t.assert_equals(res.rows[1][1], false)  -- default is JSON null, present
        local back = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(back.rows[1][1]), 'null')
        box.execute([[DROP TABLE t]])
    end)
end

-- JSON null is a present value; it does not short-circuit WHERE/CASE.
g.test_json_null_not_short_circuit = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, json_null())]])
        box.execute([[INSERT INTO t VALUES (2, NULL)]])
        box.execute([[INSERT INTO t VALUES (3, CAST({'a': 1} AS JSON))]])

        -- IS NOT NULL keeps the JSON-null and object rows, drops only SQL NULL.
        local res = box.execute(
            [[SELECT id FROM t WHERE data IS NOT NULL ORDER BY id]])
        t.assert_equals(res.rows, {{1}, {3}})

        -- CASE sees JSON null as a value, SQL NULL as null.
        res = box.execute([[
            SELECT id, CASE WHEN data IS NULL THEN 'sqlnull' ELSE 'value' END
            FROM t ORDER BY id]])
        t.assert_equals(res.rows, {{1, 'value'}, {2, 'sqlnull'}, {3, 'value'}})
        box.execute([[DROP TABLE t]])
    end)
end

--------------------------------------------------------------------------------
-- json_nonsql
--------------------------------------------------------------------------------

local g = t.group('json_nonsql')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'T2', 'T3', 'TF'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- A JSON-bearing tuple decodes without "unsupported extension" and renders as
-- canonical JSON text via tostring (cdata __tostring).
g.test_json_tuple_decode = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
        local tuple = box.space.T:get(1)
        t.assert_equals(tostring(tuple[2]), '{"a": 1, "b": 2}')
        box.execute([[DROP TABLE t]])
    end)
end

-- The __tostring metamethod can be fetched from the registry and called on
-- anything, so it has to raise an error instead of trusting its argument.
g.test_json_tostring_wrong_arg = function()
    g.server:exec(function()
        local tostr = debug.getregistry()['struct mp_json'].__tostring
        for _, arg in ipairs({42, 'x', {}, box.NULL}) do
            t.assert_error_msg_content_equals(
                'expected json as the first argument', tostr, arg)
        end
    end)
end

-- Read a JSON value as a cdata and write it back: round-trips intact.
g.test_json_roundtrip = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
        local s = box.space.T
        local val = s:get(1)[2]
        -- Re-encode the cdata on the write path.
        s:replace({2, val})
        local back = s:get(2)[2]
        t.assert_equals(tostring(back), '{"a": 1, "b": 2}')
        box.execute([[DROP TABLE t]])
    end)
end

-- net.box read of a JSON-bearing tuple (C msgpack decode path).
g.test_json_netbox_read = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t2 (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t2 VALUES (1, CAST({'x': 5} AS JSON))]])
    end)
    local conn = g.server.net_box
    local tuple = conn.space.T2:get(1)
    t.assert_equals(tostring(tuple[2]), '{"x": 5}')
    g.server:exec(function() box.execute([[DROP TABLE t2]]) end)
end

-- net.box write-back round-trip: the client re-encodes the cdata itself
-- (msgpackffi on_encode), a different encoder from the server's C serializer
-- that test_json_roundtrip exercises, and the value survives intact.
g.test_json_netbox_roundtrip = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t3 (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t3 VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
    end)
    local conn = g.server.net_box
    local val = conn.space.T3:get(1)[2]
    -- Encoded client-side: a missing or wrong encoder would emit a plain
    -- MP_MAP (rejected by the column) or corrupt bytes, so a clean read-back
    -- proves the client encode path.
    conn.space.T3:replace({2, val})
    local back = conn.space.T3:get(2)[2]
    t.assert_equals(tostring(back), tostring(val))
    t.assert_equals(tostring(back), '{"a": 1, "b": 2}')
    g.server:exec(function() box.execute([[DROP TABLE t3]]) end)
end

-- Box-boundary validation: a hand-built, un-normalized MP_EXT/MP_JSON value is
-- rejected on write (subtype-triggered, so it also covers ANY columns).
g.test_json_rejects_unnormalized_handbuilt = function()
    g.server:exec(function()
        local ffi = require('ffi')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        -- inner = map {"b":2,"a":1} with keys NOT sorted -> not normalized.
        -- Rejected rather than repaired: a forged cdata is a producer that
        -- got it wrong, and fixing it for them would hide that.
        local inner = '\x82\xa1\x62\x02\xa1\x61\x01'
        local j = ffi.new('struct mp_json', #inner)
        ffi.copy(j, inner, #inner)
        t.assert_error_msg_contains('not in normal form', function()
            box.space.T:insert({1, j})
        end)
        -- Bytes that are no JSON value at all are rejected too.
        local bad = ffi.new('struct mp_json', 2)
        ffi.copy(bad, '\xc4\x00', 2) -- MP_BIN
        local ok, err = pcall(box.space.T.insert, box.space.T, {2, bad})
        t.assert_equals(ok, false)
        t.assert_str_contains(string.lower(tostring(err)), 'json')
        -- The normal spelling of the same document stores verbatim.
        local norm = ffi.new('struct mp_json', 7)
        ffi.copy(norm, '\x82\xa1\x61\x01\xa1\x62\x02', 7)
        box.space.T:insert({3, norm})
        t.assert_equals(tostring(box.space.T:get(3)[2]), '{"a": 1, "b": 2}')
        t.assert_equals(box.space.T:count(), 1)
        box.execute([[DROP TABLE t]])
    end)
end

g.test_json_any_column = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local s = box.schema.space.create('any_t')
        s:format({{name = 'id', type = 'unsigned'},
                  {name = 'v', type = 'any'}})
        s:create_index('p')

        -- Badly spelled JSON in an ANY column is refused too. The column
        -- type says nothing about what is inside it, so the encoder is what
        -- checks the value, and it checks the same way everywhere.
        local bad = '\x82\xa1\x62\x02\xa1\x61\x01'
        local jb = ffi.new('struct mp_json', #bad)
        ffi.copy(jb, bad, #bad)
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, jb})
        end)

        -- A normalized JSON value in an ANY column is accepted, reads as JSON.
        local good = '\x81\xa1\x61\x01' -- {"a":1}
        local jg = ffi.new('struct mp_json', #good)
        ffi.copy(jg, good, #good)
        s:insert({2, jg})
        t.assert_equals(tostring(s:get(2)[2]), '{"a": 1}')

        s:drop()
    end)
end

-- A bad JSON value nested inside an array/map field is rejected too: box
-- validation descends containers rather than only checking the field's top
-- type, or a later read/compare walks the value out of bounds.
g.test_json_rejects_unnormalized_nested_handbuilt = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local s = box.schema.space.create('nested_t')
        s:format({{name = 'id', type = 'unsigned'},
                  {name = 'v', type = 'any'}})
        s:create_index('p')

        -- Un-normalized JSON (keys not sorted): {"b":2,"a":1}.
        local bad = '\x82\xa1\x62\x02\xa1\x61\x01'
        local jb = ffi.new('struct mp_json', #bad)
        ffi.copy(jb, bad, #bad)

        -- Nested in an array, then nested in a map value: refused at both
        -- depths. The encoder walks the whole Lua value, so burying it does
        -- not get it past.
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {jb}})
        end)
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({2, {nested = jb}})
        end)
        t.assert_equals(s:count(), 0)

        -- A normalized value at the same depth is accepted and reads back.
        local good = '\x81\xa1\x61\x01' -- {"a":1}
        local jg = ffi.new('struct mp_json', #good)
        ffi.copy(jg, good, #good)
        s:insert({3, {jg}})
        t.assert_equals(tostring(s:get(3)[2][1]), '{"a": 1}')

        s:drop()
    end)
end

-- A JSON value passed to a Lua function called from SQL keeps its tag: it
-- arrives as the cdata rather than a plain table, and a JSON null stays a
-- present cdata rather than collapsing to SQL NULL.
g.test_json_arg_to_lua_func_keeps_tag = function()
    g.server:exec(function()
        box.schema.func.create('JSON_IS_JSON', {
            language = 'LUA',
            param_list = {'any'},
            returns = 'string',
            -- 'json' only for the JSON cdata; 'table'/'cdata' if the
            -- tag is lost (a decoded object, or box.NULL for a dropped
            -- JSON null).
            body = [[function(x)
                if require('ffi').istype('struct mp_json', x) then
                    return 'json'
                end
                return type(x)
            end]],
            exports = {'SQL'},
            is_deterministic = true})
        box.execute([[CREATE TABLE tf (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO tf VALUES (1, CAST({'a': 1} AS JSON))]])
        -- An object argument keeps its tag rather than decoding to a table.
        local r = box.execute(
            [[SELECT JSON_IS_JSON(data) FROM tf WHERE id = 1]])
        t.assert_equals(r.rows[1][1], 'json')
        -- A JSON null argument is a present JSON cdata, not SQL NULL
        -- (box.NULL).
        local r2 = box.execute([[SELECT JSON_IS_JSON(json_null())]])
        t.assert_equals(r2.rows[1][1], 'json')
        box.execute([[DROP TABLE tf]])
        box.schema.func.drop('JSON_IS_JSON')
    end)
end

-- JSON null is distinguishable from SQL/box.NULL at the client.
g.test_json_null_vs_box_null_client = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, json_null())]])
        box.execute([[INSERT INTO t VALUES (2, NULL)]])
        local jn = box.space.T:get(1)[2]
        local sn = box.space.T:get(2)[2]
        -- JSON null is a present cdata rendering as 'null'.
        t.assert_equals(tostring(jn), 'null')
        -- SQL NULL is box.NULL, distinct from the JSON-null cdata.
        t.assert_equals(sn, box.NULL)
        t.assert_not_equals(jn, box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- The inner value of an MP_EXT/MP_JSON is validated, or a crafted subtype-20
-- value reaches a cdata that a later tostring()/compare walks out of bounds.
-- These bytes are crafted directly because no SQL path produces them.
g.test_json_decode_validates_inner = function()
    g.server:exec(function()
        local msgpack = require('msgpack')

        -- ext8, len=1, subtype 20, inner = a lone MP_STR(str32) marker
        -- claiming a length the 1-byte payload cannot satisfy. The decode
        -- decode looks inside the payload and hands back nothing.
        local truncated = '\xc7\x01\x14\xdb'
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpack.decode(truncated)
        end)
        box.schema.space.create('T')
        box.space.T:create_index('pk')

        -- Msgpack that is structurally fine but written in the wrong order
        -- is refused there too, and called out as the spelling mistake it
        -- is. It has to be: a decoded value gets copied straight into a
        -- tuple, so decode is the last place anything can look at it.
        local unsorted = '\xc7\x07\x14\x82\xa1\x62\x02\xa1\x61\x01'
        t.assert_error_msg_contains('not in normal form', function()
            return msgpack.decode(unsorted)
        end)
        t.assert_equals(box.space.T:count(), 0)

        -- A valid, normalized inner still decodes and round-trips. The inner
        -- is 4 bytes, so the canonical envelope is fixext4 (0xd6), which is
        -- what re-encode produces.
        local good = '\xd6\x14\x81\xa1\x61\x01'
        local g2 = msgpack.decode(good)
        t.assert_equals(tostring(g2), '{"a": 1}')
        t.assert_equals(msgpack.encode(g2), good)
    end)
end

-- The msgpackffi decoder is pure Lua and never runs mp_check, so a subtype-20
-- value decodes into a JSON cdata over whatever bytes it holds. The encoders
-- refuse such a cdata on its way into box, and the renderer stops at the end
-- of it, so a malformed one is never read past.
g.test_json_msgpackffi_decode_is_unchecked = function()
    g.server:exec(function()
        local msgpackffi = require('msgpackffi')

        -- msgpackffi.decode is msgpackffi.decode_unchecked, and it cannot
        -- be anything else: its cdata form takes a bare 'char *' with no
        -- length, so there is nothing to stop a walk at the end. It is the
        -- read path (every Lua tuple field read goes through it), so it
        -- copies the payload and returns rather than checking or fixing.
        local truncated = '\xc7\x01\x14\xdb'
        local junk = msgpackffi.decode(truncated)
        -- What keeps that cdata out of cluster state is not this decoder but
        -- the encoder. The renderer refuses it too, since it cannot print it.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return tostring(junk)
        end)
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpackffi.encode(junk)
        end)

        -- A value that is merely spelled wrong is refused by the encoder,
        -- and the renderer prints it as it is.
        local unsorted = '\xc7\x07\x14\x82\xa1\x62\x02\xa1\x61\x01'
        t.assert_error_msg_contains('not in normal form', function()
            return msgpackffi.encode(msgpackffi.decode(unsorted))
        end)
        t.assert_equals(tostring(msgpackffi.decode(unsorted)),
                        '{"b": 2, "a": 1}')

        -- A valid, normalized inner decodes and round-trips through the same
        -- canonical fixext4 envelope the C encoder produces.
        local good = '\xd6\x14\x81\xa1\x61\x01' -- fixext4, subtype 20, {"a":1}
        local v = msgpackffi.decode(good)
        t.assert_equals(tostring(v), '{"a": 1}')
        t.assert_equals(msgpackffi.encode(v), good)
    end)
end

-- A JSON value may not contain a nested JSON value: subtype-20 inside
-- subtype-20 would recurse until the fiber stack is exhausted, so it is
-- rejected at the first nested level. No SQL path produces such bytes.
g.test_json_reject_json_in_json = function()
    g.server:exec(function()
        local msgpack = require('msgpack')

        -- ext8 len=3 subtype 20 wrapping fixext1 subtype 20 wrapping MP_UINT 0:
        -- JSON(JSON(0)), the minimal illegal nesting.
        --
        -- The decode check inspects the payload, and JSON is not one of the
        -- kinds a JSON value may hold, so it never becomes a cdata.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpack.decode('\xc7\x03\x14\xd4\x14\x00')
        end)
        -- Forged past it, the write refuses it under the same name.
        local ffi = require('ffi')
        local v = ffi.new('struct mp_json', 3)
        ffi.copy(v, '\xd4\x14\x00', 3)
        box.schema.space.create('T')
        box.space.T:create_index('pk')
        t.assert_error_msg_contains('Invalid JSON value', function()
            box.space.T:insert({1, v})
        end)
        t.assert_equals(box.space.T:count(), 0)
    end)
end

-- A JSON cdata forged via FFI holds arbitrary bytes. tostring() does not
-- check them for normal form, but the renderer stops at the end of the cdata,
-- so a malformed payload raises a Lua error instead of being read past. No
-- SQL path produces one, so forge it.
g.test_json_tostring_forged_cdata = function()
    g.server:exec(function()
        local ffi = require('ffi')
        -- Each payload is one the renderer has to refuse by itself:
        --  * MP_BIN is well-formed msgpack but not a JSON kind.
        --  * a lone map16 marker claims two length bytes it lacks, so a
        --    renderer that did not stop at the end would read past the cdata.
        for _, bytes in ipairs({
            '\xc4\x00',                     -- MP_BIN (bin8, len 0)
            '\xde',                         -- truncated map16 header
        }) do
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            t.assert_error_msg_contains('Invalid JSON', tostring, j)
        end
        -- Un-normalized but valid bytes are a cdata out of contract, which
        -- the renderer believes like any other consumer, so they print in
        -- the order they are in. The encoder is what refuses them.
        local unsorted = '\x82\xa1\x62\x02\xa1\x61\x01'
        local j = ffi.new('struct mp_json', #unsorted)
        ffi.copy(j, unsorted, #unsorted)
        t.assert_equals(tostring(j), '{"b": 2, "a": 1}')
        local sorted = '\x82\xa1\x61\x01\xa1\x62\x02'
        local n = ffi.new('struct mp_json', #sorted)
        ffi.copy(n, sorted, #sorted)
        t.assert_equals(tostring(n), '{"a": 1, "b": 2}')
    end)
end

-- A JSON value renders through every Lua serializer instead of aborting
-- (yaml/lua) or producing malformed output (json). The yaml encoder is the
-- console's default, so this is the very first thing a user hits.
g.test_json_lua_serializers = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
        local val = box.space.T:get(1)[2] -- JSON object cdata {"a":1,"b":2}

        -- json.encode emits the JSON value inline (valid JSON), not as a
        -- quoted string -- a JSON value is JSON.
        t.assert_equals(require('json').encode(val), '{"a": 1, "b": 2}')

        -- yaml.encode (the console's default output) renders the canonical
        -- JSON text without aborting.
        t.assert_str_contains(require('yaml').encode(val), '{"a": 1, "b": 2}')

        -- The console's "lua" output mode renders it as a valid, escaped Lua
        -- string literal (the JSON text's quotes must be backslash-escaped, or
        -- the emitted Lua is malformed).
        local lua_out = box.internal.format_lua_push(val)
        t.assert_str_contains(lua_out, [[{\"a\": 1, \"b\": 2}]])
        box.execute([[DROP TABLE t]])
    end)
end

-- The same forged cdata reaching a serializer rather than tostring(). Every
-- serializer renders through luaT_json_tostring(), and the msgpack encoder
-- checks; this covers each of them so a new one cannot quietly read past a
-- malformed cdata.
g.test_json_serializers_forged_cdata = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local encoders = {
            ['json'] = require('json').encode,
            ['yaml'] = require('yaml').encode,
            ['msgpack'] = require('msgpack').encode,
            ['lua'] = box.internal.format_lua_push,
        }
        for _, bytes in ipairs({
            '\xc4\x00',                     -- MP_BIN (bin8, len 0)
            '\xde',                         -- truncated map16 header
        }) do
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            for name, encode in pairs(encoders) do
                -- The console formatter reports the failure in its output
                -- rather than raising; the rest raise.
                local ok, res = pcall(encode, j)
                t.assert_str_contains(tostring(res), 'Invalid JSON value',
                                      false, name .. ' must reject')
                t.assert_equals(ok, name == 'lua', name .. ' raises')
            end
        end
        -- Un-normalized but valid bytes are refused by the msgpack encoder,
        -- under the other message, since that is the way into box. The text
        -- serializers render them in the order they are in.
        local unsorted = '\x82\xa1\x62\x02\xa1\x61\x01'
        local j = ffi.new('struct mp_json', #unsorted)
        ffi.copy(j, unsorted, #unsorted)
        t.assert_error_msg_contains('not in normal form',
                                    require('msgpack').encode, j)
        t.assert_equals(require('json').encode(j), '{"b": 2, "a": 1}')
        t.assert_str_contains(require('yaml').encode(j), '{"b": 2, "a": 1}')
        t.assert_str_contains(box.internal.format_lua_push(j),
                              [[{\"b\": 2, \"a\": 1}]])
        -- The normal spelling of the same document goes through all four.
        local sorted = '\x82\xa1\x61\x01\xa1\x62\x02'
        local n = ffi.new('struct mp_json', #sorted)
        ffi.copy(n, sorted, #sorted)
        t.assert_equals(require('json').encode(n), '{"a": 1, "b": 2}')
        t.assert_str_contains(require('yaml').encode(n), '{"a": 1, "b": 2}')
        t.assert_str_contains(box.internal.format_lua_push(n),
                              [[{\"a\": 1, \"b\": 2}]])
        local mp = require('msgpack')
        t.assert_equals(tostring(mp.decode(mp.encode(n))), '{"a": 1, "b": 2}')
    end)
end

-- A JSON value can be passed as a SQL bind parameter and round-trips. Before,
-- both the Lua bind path (execute.c) and the iproto bind path (bind.c) raised
-- ER_SQL_BIND_TYPE 'USERDATA'.
g.test_json_bind_lua = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        -- A JSON value from a query, bound back as a parameter (Lua path).
        local v = box.execute([[SELECT CAST(42 AS JSON)]]).rows[1][1]
        box.execute([[INSERT INTO t VALUES (1, ?)]], {v})
        t.assert_equals(tostring(box.space.T:get(1)[2]), '42')
        -- Bound JSON is usable in a predicate against a JSON column.
        local r = box.execute([[SELECT id FROM t WHERE data = ?]], {v})
        t.assert_equals(r.rows[1][1], 1)
        box.execute([[DROP TABLE t]])
    end)
end

g.test_json_bind_netbox = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t2 (id INT PRIMARY KEY, data JSON)]])
    end)
    local conn = g.server.net_box
    -- The client (msgpackffi) encodes the JSON cdata as an MP_EXT/MP_JSON
    -- parameter; the server's iproto bind path (bind.c) decodes it.
    local v = conn:execute([[SELECT CAST(7 AS JSON)]]).rows[1][1]
    conn:execute([[INSERT INTO t2 VALUES (1, ?)]], {v})
    t.assert_equals(tostring(conn.space.T2:get(1)[2]), '7')
    g.server:exec(function() box.execute([[DROP TABLE t2]]) end)
end

-- A JSON cdata bound through the Lua path is taken on trust: the bind reads
-- its bytes without encoding them, so nothing checks them there. What keeps a
-- badly spelled value out is wherever the cdata came from, and a script
-- normally reaches for msgpack.decode(). That refuses both kinds of mistake,
-- so neither can be carried into a bind; the right spelling decodes, binds and
-- stores.
g.test_json_bind_rejects_invalid = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        -- Un-normalized inner (keys not sorted): refused, and named as the
        -- spelling mistake it is rather than as a malformed value.
        t.assert_error_msg_contains('not in normal form', function()
            return msgpack.decode('\xc7\x07\x14\x82\xa1\x62\x02\xa1\x61\x01')
        end)
        -- Bytes that are no JSON value at all are refused under the other
        -- message.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpack.decode('\xc7\x02\x14\xc4\x00') -- MP_BIN
        end)
        -- The normal spelling of the same document decodes and binds.
        local sorted =
            msgpack.decode('\xc7\x07\x14\x82\xa1\x61\x01\xa1\x62\x02')
        box.execute([[INSERT INTO t VALUES (3, ?)]], {sorted})
        t.assert_equals(tostring(box.space.T:get(3)[2]), '{"a": 1, "b": 2}')
        t.assert_equals(box.execute([[SELECT count(*) FROM t]]).rows, {{1}})
        box.execute([[DROP TABLE t]])
    end)
end

-- A bad JSON value in a tuple field beyond the space format is rejected too:
-- box validation now checks trailing fields, not only those the format
-- describes (field 2 here is not in the format).
g.test_json_rejects_unnormalized_trailing_field = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local s = box.schema.space.create('trailing_t')
        s:format({{name = 'id', type = 'unsigned'}})
        s:create_index('p')
        -- Un-normalized JSON (keys not sorted) in a trailing field, which no
        -- format describes, is refused just as a described one is.
        local unsorted = ffi.new('struct mp_json', 7)
        ffi.copy(unsorted, '\x82\xa1\x62\x02\xa1\x61\x01', 7)
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, unsorted})
        end)
        -- Bytes that are no JSON value at all are rejected too.
        local bad = ffi.new('struct mp_json', 2)
        ffi.copy(bad, '\xc4\x00', 2)
        t.assert_error(function() s:insert({3, bad}) end)
        t.assert_equals(s:count(), 0)
        -- A normalized trailing JSON value is accepted and reads back.
        local good = ffi.new('struct mp_json', 4) -- {"a":1}
        ffi.copy(good, '\x81\xa1\x61\x01', 4)
        s:insert({2, good})
        t.assert_equals(tostring(s:get(2)[2]), '{"a": 1}')
        s:drop()
    end)
end

-- A Lua function called from SQL can return a JSON value: the return path
-- (port_lua_get_vdbemem) wraps and validates it instead of raising
-- "Unsupported type passed from Lua".
g.test_json_returned_from_lua_func = function()
    g.server:exec(function()
        box.schema.func.create('JSON_ID', {
            language = 'LUA',
            param_list = {'json'},
            returns = 'json',
            body = 'function(x) return x end',
            exports = {'SQL'},
            is_deterministic = true})
        local r = box.execute([[SELECT JSON_ID(CAST({'a': 1} AS JSON))]])
        t.assert_equals(tostring(r.rows[1][1]), '{"a": 1}')
        box.schema.func.drop('JSON_ID')
    end)
end

-- A bad JSON value at an undescribed position nested inside a described
-- container is rejected. A JSON-path index (data.a) makes the format deep, so
-- box validation walks the tuple with the format iterator, where a sibling key
-- not in the format was previously skipped without validation.
g.test_json_rejects_unnormalized_undescribed_nested_field = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local s = box.schema.space.create('deep_t')
        s:format({{name = 'id', type = 'unsigned'},
                  {name = 'data', type = 'any'}})
        s:create_index('p', {parts = {{1, 'unsigned'}}})
        -- The JSON-path part makes fields_depth > 1, so the validating tuple
        -- iterator (not the plain path) walks the map field.
        s:create_index('sk',
            {parts = {{field = 2, path = 'a', type = 'unsigned'}}})

        -- Un-normalized JSON (keys not sorted): {"b":2,"a":1}.
        local unsorted = ffi.new('struct mp_json', 7)
        ffi.copy(unsorted, '\x82\xa1\x62\x02\xa1\x61\x01', 7)
        -- "b" is a sibling of the described "a", absent from the format. It
        -- is refused all the same, so an undescribed position cannot hold a
        -- non-normalized value either.
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {a = 1, b = unsorted}})
        end)
        -- Bytes that are no JSON value at all are rejected there too.
        local bad = ffi.new('struct mp_json', 2)
        ffi.copy(bad, '\xc4\x00', 2)
        t.assert_error(function() s:insert({3, {a = 3, b = bad}}) end)
        t.assert_equals(s:count(), 0)

        -- A normalized value at the same undescribed spot is accepted.
        local good = ffi.new('struct mp_json', 4) -- {"a":1}
        ffi.copy(good, '\x81\xa1\x61\x01', 4)
        s:insert({2, {a = 2, b = good}})
        t.assert_equals(tostring(s:get(2)[2].b), '{"a": 1}')

        s:drop()
    end)
end

-- The same validation covers a map with a non-string key nested in a described
-- container: that key/value pair takes a separate skip branch in the iterator
-- (entry->field = NULL for a non-string key) and was likewise stored without
-- JSON validation.
g.test_json_rejects_unnormalized_nonstring_key_nested_field = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local s = box.schema.space.create('deep_k')
        s:format({{name = 'id', type = 'unsigned'},
                  {name = 'data', type = 'any'}})
        s:create_index('p', {parts = {{1, 'unsigned'}}})
        s:create_index('sk',
            {parts = {{field = 2, path = 'a', type = 'unsigned'}}})

        -- Un-normalized JSON (keys not sorted): {"b":2,"a":1}.
        local unsorted = ffi.new('struct mp_json', 7)
        ffi.copy(unsorted, '\x82\xa1\x62\x02\xa1\x61\x01', 7)
        -- Integer key 5 (non-string) carrying it: rejected all the same.
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, {a = 1, [5] = unsorted}})
        end)
        -- Bytes that are no JSON value at all are rejected there too.
        local bad = ffi.new('struct mp_json', 2)
        ffi.copy(bad, '\xc4\x00', 2)
        t.assert_error(function() s:insert({3, {a = 3, [5] = bad}}) end)
        t.assert_equals(s:count(), 0)

        -- A normalized value under the same non-string key is accepted.
        local good = ffi.new('struct mp_json', 4) -- {"a":1}
        ffi.copy(good, '\x81\xa1\x61\x01', 4)
        s:insert({2, {a = 2, [5] = good}})
        t.assert_equals(s:count(), 1)

        s:drop()
    end)
end

-- A forged cdata cannot produce a bad stored value: every way from Lua into
-- box refuses it. tostring() does not judge it and prints what it holds.
g.test_json_forged_cdata_is_rejected = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local msgpackffi = require('msgpackffi')
        local t = require('luatest')
        -- {"b": 1, "a": 2} with unsorted keys and a str8 key header.
        local raw = '\x82\xd9\x01b\x01\xa1a\x02'
        local json = ffi.new('struct mp_json', #raw)
        ffi.copy(json, raw, #raw)
        -- Both encoders and the write give the same answer about the same
        -- bytes. The renderer prints them as they are.
        t.assert_equals(tostring(json), '{"b": 1, "a": 2}')
        t.assert_error_msg_contains('not in normal form', function()
            return msgpackffi.encode(json)
        end)
        t.assert_error_msg_contains('not in normal form', function()
            return require('msgpack').encode(json)
        end)
        box.schema.space.create('T')
        box.space.T:create_index('pk')
        t.assert_error_msg_contains('not in normal form', function()
            box.space.T:insert({1, json})
        end)
        -- The normal spelling of the same document goes through all of them.
        local sorted_raw = '\x82\xa1a\x02\xa1b\x01'
        local sorted = ffi.new('struct mp_json', #sorted_raw)
        ffi.copy(sorted, sorted_raw, #sorted_raw)
        t.assert_equals(tostring(sorted), '{"a": 2, "b": 1}')
        t.assert_equals(tostring(msgpackffi.decode(
            msgpackffi.encode(sorted))), '{"a": 2, "b": 1}')
        box.space.T:insert({2, sorted})
        t.assert_equals(tostring(box.space.T:get(2)[2]), '{"a": 2, "b": 1}')
        t.assert_equals(box.space.T:count(), 1)
    end)
end

--------------------------------------------------------------------------------
-- json_ordering
--------------------------------------------------------------------------------

local g = t.group('json_ordering')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'U'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- ORDER BY over mixed JSON kinds follows the JSONB rank
-- null < string < number < bool < array < object, both ASC and DESC.
g.test_order_by_jsonb_rank = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        -- ids deliberately not in rank order; the comparator must drive it.
        s:insert({1, jraw('\x81\xa1\x61\x01')}) -- object {"a":1}  rank 5
        s:insert({2, jraw('\xc0')})             -- null            rank 0
        s:insert({3, jraw('\xc3')})             -- bool true       rank 3
        s:insert({4, jraw('\xa1\x78')})         -- string "x"      rank 1
        s:insert({5, jraw('\x91\x01')})         -- array [1]       rank 4
        s:insert({6, jraw('\x05')})             -- number 5        rank 2

        local asc = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(asc.rows, {{2}, {4}, {6}, {3}, {5}, {1}})

        local desc = box.execute([[SELECT id FROM t ORDER BY data DESC]])
        t.assert_equals(desc.rows, {{1}, {5}, {3}, {6}, {4}, {2}})
        box.execute([[DROP TABLE t]])
    end)
end

-- JSON strings order bytewise, matching jsonb value ordering under the C
-- collation. Length is not consulted first (that is jsonb's key storage rule,
-- not its value comparison).
g.test_order_by_string_bytewise = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\xa3\x61\x61\x61')}) -- "aaa" len 3
        s:insert({2, jraw('\xa1\x7a')})         -- "z"   len 1
        s:insert({3, jraw('\xa2\x62\x62')})     -- "bb"  len 2
        -- bytewise: "aaa" < "bb" < "z" (0x61 < 0x62 < 0x7a); length does not
        -- decide, so the longest sorts first here.
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{1}, {3}, {2}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Numbers order by value across negative, zero, fractional and
-- mixed representations (int and double).
g.test_order_by_numbers = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local function jbytes(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        local function jval(v) return jbytes(msgpack.encode(v)) end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jval(5)})      -- int 5
        s:insert({2, jval(-1.5)})   -- double -1.5
        s:insert({3, jval(0)})      -- int 0
        s:insert({4, jval(2.5)})    -- double 2.5
        -- value order: -1.5 < 0 < 2.5 < 5
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {3}, {4}, {1}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Arrays order by element count first, then element-by-element, matching jsonb
-- (an array with more elements sorts above one with fewer).
g.test_order_by_arrays = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\x91\x02')})         -- [2]
        s:insert({2, jraw('\x91\x01')})         -- [1]
        s:insert({3, jraw('\x92\x01\x01')})     -- [1,1]
        s:insert({4, jraw('\x92\x01\x09')})     -- [1,9]
        -- count-first: [1] < [2] (both 1 element) < [1,1] < [1,9] (2 elements).
        -- Under jsonb [2] sorts below [1,1] despite 2 > 1, because [1,1] is
        -- longer.
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {1}, {3}, {4}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Objects compare size-first, then keys, then values; keys written
-- in any order normalize to the same value.
g.test_order_by_objects = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\x81\xa1\x62\x01')})         -- {"b":1}
        s:insert({2, jraw('\x80')})                     -- {}
        s:insert({3, jraw('\x81\xa1\x61\x02')})         -- {"a":2}
        s:insert({4, jraw('\x82\xa1\x61\x01\xa1\x62\x01')}) -- {"a":1,"b":1}
        -- {} (size 0) < {"a":2} (key a) < {"b":1} (key b)
        --   < {"a":1,"b":1} (size 2)
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {3}, {1}, {4}})
        box.execute([[DROP TABLE t]])
    end)
end

-- When two objects of equal size have differing keys, the keys are compared
-- bytewise (jsonb value ordering), not length-first: "aa" < "b", so the object
-- with the longer key sorts first. jsonb stores keys length-first but still
-- compares them by value.
g.test_order_by_object_keys_bytewise = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\x81\xa1\x62\x01')})     -- {"b":1}
        s:insert({2, jraw('\x81\xa2\x61\x61\x01')}) -- {"aa":1}
        -- bytewise: {"aa":1} < {"b":1} ('a' < 'b'), despite "aa" being longer.
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {1}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Test =, <>, <, > operators between JSON values; reordered-equal objects.
g.test_comparison_operators = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a JSON, b JSON)]])
        -- reordered keys normalize equal.
        box.execute([[INSERT INTO t VALUES (1, CAST({'x':1,'y':2} AS JSON),
                                               CAST({'y':2,'x':1} AS JSON))]])
        -- distinct values.
        box.execute([[INSERT INTO t VALUES (2, CAST({'a':1} AS JSON),
                                               CAST({'a':2} AS JSON))]])
        local res = box.execute(
            [[SELECT id, a = b, a <> b, a < b, a > b FROM t ORDER BY id]])
        -- row 1: equal objects.
        t.assert_equals(res.rows[1], {1, true, false, false, false})
        -- row 2: {"a":1} < {"a":2}.
        t.assert_equals(res.rows[2], {2, false, true, true, false})
        box.execute([[DROP TABLE t]])
    end)
end

-- Nothing is converted to JSON to make a comparison work: a comparison follows
-- the same rule as an assignment, and a JSON operand only compares against
-- another JSON value. A map or array literal is refused exactly as it is
-- against another map, and a scalar is refused in either direction. The cast
-- form is what compares.
g.test_comparison_needs_a_cast = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute(
            [=[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]=])
        box.execute([==[INSERT INTO t VALUES (2, CAST([1, 2] AS JSON))]==])

        -- A container literal is not comparable, against JSON or anything
        -- else, in either operand order.
        local _, err = box.execute([=[SELECT j = {'a': 1} FROM t
                                      WHERE id = 1]=])
        t.assert_str_contains(err.message, 'comparable type')
        _, err = box.execute([=[SELECT {'a': 1} = j FROM t WHERE id = 1]=])
        t.assert_str_contains(err.message, 'comparable type')
        _, err = box.execute([=[SELECT {'a': 1} = {'a': 1}]=])
        t.assert_str_contains(err.message, 'comparable type')

        -- A scalar against JSON is a type error, both ways round.
        _, err = box.execute([[SELECT j = 1 FROM t WHERE id = 1]])
        t.assert_str_contains(err.message, 'to json')
        _, err = box.execute([[SELECT 1 = j FROM t WHERE id = 1]])
        t.assert_str_contains(err.message, 'to number')

        -- Cast, and it compares. Key order does not matter, and ordering
        -- works as well as equality.
        local res = box.execute([=[SELECT j = CAST({'a': 1, 'b': 2} AS JSON)
                                   FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], true)
        res = box.execute([=[SELECT CAST({'b': 2, 'a': 1} AS JSON) = j
                             FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], true)
        res = box.execute([==[SELECT j = CAST([1, 2] AS JSON) FROM t
                              WHERE id = 2]==])
        t.assert_equals(res.rows[1][1], true)
        res = box.execute([=[SELECT j < CAST({'z': 9} AS JSON) FROM t
                             WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], false)
    end)
end

-- Integral numbers are equal across representations
-- (int / double / decimal), and fractional value-equals compare equal.
g.test_option_d_numeric_equality = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local decimal = require('decimal')
        local function jbytes(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        -- A genuine MP_DOUBLE (msgpack folds integral Lua numbers to int).
        local function jdouble(x)
            local buf = ffi.new('double[1]', x)
            local le = ffi.string(buf, 8)
            return jbytes('\xcb' .. le:reverse())
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a JSON, b JSON)]])
        local s = box.space.T
        -- 1 (int) == 1.0 (double)
        s:insert({1, jbytes('\x01'), jdouble(1.0)})
        -- 1 (int) == 1.00 (decimal)
        s:insert({2, jbytes('\x01'),
                     jbytes(msgpack.encode(decimal.new('1.00')))})
        -- 1.0 (double) == 1.00 (decimal)
        s:insert({3, jdouble(1.0), jbytes(msgpack.encode(decimal.new('1.00')))})
        -- 2.5 (double) == 2.5 (decimal): fractional value-equal
        s:insert({4, jdouble(2.5), jbytes(msgpack.encode(decimal.new('2.5')))})
        -- 1 (int) < 2 (int): control
        s:insert({5, jbytes('\x01'), jbytes('\x02')})

        local res = box.execute(
            [[SELECT id, a = b, a < b, a > b FROM t ORDER BY id]])
        t.assert_equals(res.rows[1], {1, true, false, false})
        t.assert_equals(res.rows[2], {2, true, false, false})
        t.assert_equals(res.rows[3], {3, true, false, false})
        t.assert_equals(res.rows[4], {4, true, false, false})
        t.assert_equals(res.rows[5], {5, false, true, false})

        -- Integral numbers collapse under ORDER BY tiebreak (all data equal,
        -- so the secondary id sort decides).
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, data JSON)]])
        local su = box.space.U
        su:insert({3, jbytes(msgpack.encode(decimal.new('1.000')))})
        su:insert({1, jbytes('\x01')})
        su:insert({2, jdouble(1.0)})
        local r2 = box.execute([[SELECT id FROM u ORDER BY data, id]])
        t.assert_equals(r2.rows, {{1}, {2}, {3}})
        box.execute([[DROP TABLE t]])
        box.execute([[DROP TABLE u]])
    end)
end

-- A double counts as the decimal its shortest round-trip digits spell, as
-- when PostgreSQL turns a float8 into jsonb, whatever kind it meets. 2^53
-- as a double, an integer and a decimal used to be equal pairwise except
-- double vs decimal, which left DISTINCT and GROUP BY with no right answer.
g.test_numbers_equal_across_kinds_are_one_group = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES
            (1, CAST('9007199254740992e0' AS JSON)),
            (2, CAST('9007199254740992' AS JSON)),
            (3, CAST('9007199254740992.0' AS JSON)),
            (4, CAST('0.1e0' AS JSON)),
            (5, CAST('0.1' AS JSON)),
            (6, CAST('1152921504606846976e0' AS JSON)),
            (7, CAST('1152921504606847000' AS JSON))]])
        local r = box.execute([[SELECT COUNT(*) FROM t GROUP BY data
                                ORDER BY data]])
        t.assert_equals(r.rows, {{2}, {3}, {2}})
        r = box.execute([[SELECT COUNT(*) FROM (SELECT DISTINCT data FROM t)]])
        t.assert_equals(r.rows, {{3}})
        box.execute([[DROP TABLE t]])
    end)
end

-- A double renders with the fewest digits that read back as it, so its text
-- read back is equal to it. Fourteen digits, as before, lost the last ones.
g.test_double_text_reads_back_equal = function()
    g.server:exec(function()
        local cases = {
            {'1.0000000000000002e0', '1.0000000000000002'},
            {'9007199254740992e0', '9007199254740992'},
            {'0.1e0', '0.1'},
            {'1.7976931348623157e308', '1.7976931348623157e+308'},
            {'5e-324', '5e-324'},
        }
        for _, c in ipairs(cases) do
            local r = box.execute(([[SELECT CAST(j AS TEXT),
                                            CAST(CAST(j AS TEXT) AS JSON) = j
                                     FROM (SELECT CAST('%s' AS JSON) AS j)]])
                                  :format(c[1]))
            t.assert_equals(r.rows[1], {c[2], true}, c[1])
        end
    end)
end

-- Comparing a JSON value to a non-JSON scalar is a type error
-- unless explicitly cast.
g.test_json_vs_scalar_type_error = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a':1} AS JSON))]])
        -- box.execute returns (nil, err); also tolerate a raised error.
        local r, e = box.execute([[SELECT data = 5 FROM t]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')
        box.execute([[DROP TABLE t]])
    end)
end

-- A non-JSON operand that carries the MEM_Scalar flag (from CAST(x AS SCALAR)
-- or a value read from a SCALAR column) must still be a type error against
-- JSON, in either operand order and for every operator. Before the fix the
-- MEM_Scalar branch in mem_cmp() short-circuited to a class-rank comparison
-- ahead of the type-mismatch check, so JSON (the highest class) silently
-- sorted above every scalar and equality silently never matched. JSON is not
-- a member of the SCALAR domain, so the comparison is a type error.
g.test_json_vs_scalar_flagged_type_error = function()
    g.server:exec(function()
        -- CAST(x AS SCALAR) sets MEM_Scalar on the non-JSON side.
        local r, e = box.execute(
            [[SELECT CAST(1 AS SCALAR) < CAST({'a': 1} AS JSON)]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')

        -- Same comparison, operands reversed: still an error.
        r, e = box.execute(
            [[SELECT CAST({'a': 1} AS JSON) < CAST(1 AS SCALAR)]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')

        -- Equality must error too (before the fix it silently never matched).
        r, e = box.execute(
            [[SELECT CAST(1 AS SCALAR) = CAST({'a': 1} AS JSON)]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')

        r, e = box.execute(
            [[SELECT CAST(1 AS SCALAR) > CAST({'a': 1} AS JSON)]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')

        -- A value read from a SCALAR column carries the flag as well, so the
        -- WHERE predicate errors rather than silently never matching.
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, s SCALAR, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, 1, CAST({'a': 1} AS JSON))]])
        r, e = box.execute([[SELECT s = j FROM t]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')
        r, e = box.execute([[SELECT s < j FROM t]])
        t.assert_equals(r, nil)
        t.assert_str_contains(string.lower(e.message), 'type mismatch')
        box.execute([[DROP TABLE t]])
    end)
end

-- JSON null sorts first within JSON (its own value), ahead of all
-- non-null JSON values.
g.test_json_null_sorts_first = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\x81\xa1\x61\x01')}) -- object {"a":1}
        box.execute([[INSERT INTO t VALUES (2, json_null())]]) -- JSON null
        s:insert({3, jraw('\xa1\x78')})         -- string "x"
        -- JSON null < string < object
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {3}, {1}})
        box.execute([[DROP TABLE t]])
    end)
end

-- MP_FLOAT (single precision) is not a valid JSON number kind, and a
-- hand-built MP_EXT/MP_JSON carrying one is rejected before it reaches the
-- space.
-- A cdata handed to insert() is validated by luaL_tofield(), so the rejection
-- comes from there rather than box validation, which is why the message has
-- no field number. Box validation covers the same bytes over iproto.
--
g.test_mp_float_rejected_on_insert = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jbytes(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        -- Genuine big-endian MP_FLOAT (msgpack would fold an integral Lua
        -- number to int, so build the wire bytes directly).
        local function jfloat(x)
            local buf = ffi.new('float[1]', x)
            return jbytes('\xca' .. ffi.string(buf, 4):reverse())
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        -- Both a fractional and a large integral float are rejected: MP_FLOAT
        -- is simply not an accepted JSON number encoding.
        t.assert_error_msg_contains('Invalid JSON value', function()
            s:insert({1, jfloat(2.5)})
        end)
        t.assert_error_msg_contains('Invalid JSON value', function()
            s:insert({2, jfloat(4294967296.0)})
        end)
        t.assert_equals(box.execute([[SELECT count(*) FROM t]]).rows, {{0}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Empty-vs-nonempty container ordering for arrays -- an empty array has the
-- fewest elements, so under count-first ordering it sorts first (mirrors the
-- empty object case).
g.test_empty_array_orders_first = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        s:insert({1, jraw('\x91\x01')}) -- [1]
        s:insert({2, jraw('\x90')})     -- []
        s:insert({3, jraw('\x92\x01\x02')}) -- [1,2]
        -- [] (0 elements) < [1] (1) < [1,2] (2): count-first.
        local res = box.execute([[SELECT id FROM t ORDER BY data]])
        t.assert_equals(res.rows, {{2}, {1}, {3}})
        box.execute([[DROP TABLE t]])
    end)
end

-- The comparator matches object keys by position and has no way to report an
-- error, which is only safe because every value it sees is in normal form. So
-- two spellings of one document have to compare equal, and a badly spelled one
-- has to sort where its normal form does and not where its bytes happen to
-- put it.
g.test_ordering_is_over_normalized_values = function()
    g.server:exec(function()
        local msgpack = require('msgpack')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local s = box.space.T
        -- {"b":1,"a":2} with its keys out of order is refused; only the
        -- sorted spelling can be stored, so a stored value is always in
        -- normal form and ordering never meets a second spelling.
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, msgpack.object_from_raw(
                '\xc7\x07\x14\x82\xa1b\x01\xa1a\x02')})
        end)
        s:insert({1, msgpack.object_from_raw(
            '\xc7\x07\x14\x82\xa1a\x02\xa1b\x01')})
        -- A non-minimal integer encoding is likewise rejected; its minimal
        -- form sorts by value, not by the width it was spelled with.
        t.assert_error_msg_contains('not in normal form', function()
            -- uint8 5
            s:insert({3, msgpack.object_from_raw('\xd5\x14\xcc\x05')})
        end)
        s:insert({3, msgpack.object_from_raw('\xd4\x14\x05')})     -- 5
        s:insert({4, msgpack.object_from_raw('\xd4\x14\x03')})     -- 3
        local ord = box.execute(
            [[SELECT id FROM t WHERE id > 2 ORDER BY data]])
        t.assert_equals(ord.rows, {{4}, {3}}, '3 sorts before 5')
        box.execute([[DROP TABLE t]])
    end)
end

--------------------------------------------------------------------------------
-- json_subscript
--------------------------------------------------------------------------------

local g = t.group('json_subscript')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'U'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- Slice 1: object key access returns the keyed value as JSON.
g.test_subscript_object_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[
            INSERT INTO t VALUES (1, CAST({'name': 'Alice', 'age': 30} AS JSON))
        ]])
        local res = box.execute([=[SELECT data['name'] FROM t WHERE id = 1]=])
        -- JSON string scalar; tostring gives canonical JSON text (quoted).
        t.assert_equals(tostring(res.rows[1][1]), '"Alice"')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 2: array index is 0-based (PostgreSQL jsonb) and returns the element
-- as JSON.
g.test_subscript_array_index_0based = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, CAST([10, 20, 30] AS JSON))]=])
        local res = box.execute([=[SELECT data[0], data[1], data[2] FROM t]=])
        t.assert_equals(tostring(res.rows[1][1]), '10')
        t.assert_equals(tostring(res.rows[1][2]), '20')
        t.assert_equals(tostring(res.rows[1][3]), '30')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 3: the subscript result is JSON-typed (static + runtime).
g.test_subscript_result_is_json = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[
            INSERT INTO t VALUES (1, CAST({'key': {'nested': 'value'}} AS JSON))
        ]])
        -- Static type drives metadata (enables ORDER BY/chaining on
        -- subscripts).
        local res = box.execute([=[SELECT data['key'] FROM t WHERE id = 1]=])
        t.assert_equals(res.metadata[1].type, 'json')
        -- Runtime type via TYPEOF.
        local r2 = box.execute([=[SELECT TYPEOF(data['key']) FROM t]=])
        t.assert_equals(r2.rows[1][1], 'json')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 4: chained subscript is a single multi-key op walking intermediates
-- (0-based array step).
g.test_subscript_chained_multikey = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1,
            CAST({'users': [{'name': 'Bob'}, {'name': 'Carol'}]} AS JSON))]])
        local res = box.execute(
            [=[SELECT data['users'][0]['name'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(res.rows[1][1]), '"Bob"')
        local r2 = box.execute(
            [=[SELECT data['users'][1]['name'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r2.rows[1][1]), '"Carol"')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 5: deeply nested object access.
g.test_subscript_nested_object = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[
            INSERT INTO t VALUES (1, CAST({'a': {'b': {'c': 'deep'}}} AS JSON))
        ]])
        local res = box.execute(
            [=[SELECT data['a']['b']['c'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(res.rows[1][1]), '"deep"')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 6: a missing object key yields SQL NULL (absence), not JSON null.
g.test_subscript_missing_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'name': 'Alice'} AS JSON))]])
        local res = box.execute(
            [=[SELECT data['nonexistent'] FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 7: array index past the end yields SQL NULL; index 0 is the first
-- element (0-based).
g.test_subscript_array_out_of_range = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, CAST([1, 2, 3] AS JSON))]=])
        -- index 0 is the first element now.
        local r0 = box.execute([=[SELECT data[0] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r0.rows[1][1]), '1')
        -- one past the last valid index (0..2).
        local r3 = box.execute([=[SELECT data[3] FROM t WHERE id = 1]=])
        t.assert_equals(r3.rows[1][1], box.NULL)
        -- far past the end.
        local res = box.execute([=[SELECT data[100] FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 8: subscripting a scalar JSON value yields SQL NULL.
g.test_subscript_on_scalar = function()
    g.server:exec(function()
        local ffi = require('ffi')
        local function jraw(bytes)
            local j = ffi.new('struct mp_json', #bytes)
            ffi.copy(j, bytes, #bytes)
            return j
        end
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        -- Scalar JSON number 42 (0x2a), built directly as an mp_json cdata so
        -- the test does not depend on the cast path.
        box.space.T:insert({1, jraw('\x2a')})
        local res = box.execute([=[SELECT data['key'] FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 9: key-kind mismatch yields SQL NULL (object by index, array by key).
g.test_subscript_key_kind_mismatch = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a': 1} AS JSON))]])
        box.execute([=[INSERT INTO t VALUES (2, CAST([1, 2] AS JSON))]=])
        -- object subscripted by an integer index.
        local r1 = box.execute([=[SELECT data[1] FROM t WHERE id = 1]=])
        t.assert_equals(r1.rows[1][1], box.NULL)
        -- array subscripted by a string key.
        local r2 = box.execute([=[SELECT data['x'] FROM t WHERE id = 2]=])
        t.assert_equals(r2.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 10: a present JSON null element returns JSON null, distinct from SQL
-- NULL (IS NULL is false; tostring is 'null').
g.test_subscript_present_json_null = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'key': null} AS JSON))]])
        local res = box.execute(
            [=[SELECT data['key'] IS NULL FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], false)
        local r2 = box.execute([=[SELECT data['key'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r2.rows[1][1]), 'null')
        t.assert_not_equals(r2.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 11: subscript returns already-normalized bytes (nested keys stay sorted
-- length-first then byte-by-byte).
g.test_subscript_returns_normalized = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES
            (1, CAST({'outer': {'zz': 1, 'aa': 2, 'm': 3}} AS JSON))]])
        local res = box.execute([=[SELECT data['outer'] FROM t WHERE id = 1]=])
        -- normalized order: m (len 1), aa (len 2), zz (len 2, 'aa' < 'zz').
        t.assert_equals(tostring(res.rows[1][1]), '{"m": 3, "aa": 2, "zz": 1}')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 12: a subscript result flows through the sorter (ORDER BY data['k']).
g.test_subscript_order_by = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'value': 'string'} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, CAST({'value': 42} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST({'value': null} AS JSON))]])
        -- JSONB rank: null < string < number.
        local res = box.execute([=[SELECT id FROM t ORDER BY data['value']]=])
        t.assert_equals(res.rows, {{3}, {1}, {2}})
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 13: a parenthesized intermediate is materialized but still works.
g.test_subscript_parenthesized = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES
            (1, CAST({'users': [{'name': 'Bob'}]} AS JSON))]])
        local res = box.execute(
            [=[SELECT (data['users'])[0]['name'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(res.rows[1][1]), '"Bob"')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 14: walking past a missing key in a single op yields SQL NULL (the
-- intermediate SQL NULL is not re-subscripted as a value).
g.test_subscript_past_missing_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a': {'b': 1}} AS JSON))]])
        local res = box.execute(
            [=[SELECT data['missing']['b'] FROM t WHERE id = 1]=])
        t.assert_equals(res.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 15: subscripting a JSON operand that evaluated to SQL NULL (a nullable
-- JSON column holding SQL NULL) yields SQL NULL, not an error.
g.test_subscript_sql_null_operand = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, NULL)]])
        box.execute([[INSERT INTO t VALUES (2, CAST({'a': 42} AS JSON))]])
        -- SQL NULL row: subscript returns SQL NULL rather than erroring.
        local r1 = box.execute([=[SELECT data['a'] FROM t WHERE id = 1]=])
        t.assert_equals(r1.rows[1][1], box.NULL)
        -- The non-NULL row in the same column still subscripts normally.
        local r2 = box.execute([=[SELECT data['a'] FROM t WHERE id = 2]=])
        t.assert_equals(tostring(r2.rows[1][1]), '42')
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 16: subscripting a SQL NULL MAP/ARRAY column yields SQL NULL, just as a
-- JSON operand does; NULL propagation is not specific to JSON.
g.test_subscript_sql_null_non_json = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP, a ARRAY)]])
        box.execute([[INSERT INTO t VALUES (1, NULL, NULL)]])
        local r1 = box.execute([=[SELECT m['k'] FROM t WHERE id = 1]=])
        t.assert_equals(r1.rows[1][1], box.NULL)
        local r2 = box.execute([=[SELECT a[1] FROM t WHERE id = 1]=])
        t.assert_equals(r2.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Subscripting a bind that resolves to SQL NULL yields SQL NULL, like any other
-- NULL operand.
g.test_subscript_null_bind = function()
    g.server:exec(function()
        local r1 = box.execute([=[SELECT ?[1]]=], {box.NULL})
        t.assert_equals(r1.rows[1][1], box.NULL)
        local r2 = box.execute([=[SELECT ?['k']]=], {box.NULL})
        t.assert_equals(r2.rows[1][1], box.NULL)
    end)
end

-- Slice 17: a text array index is parsed to an integer (PostgreSQL text model);
-- unparseable or fractional text yields SQL NULL.
g.test_subscript_array_string_index = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, CAST([10, 20, 30] AS JSON))]=])
        local r0 = box.execute([=[SELECT data['0'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r0.rows[1][1]), '10')
        local r1 = box.execute([=[SELECT data['2'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r1.rows[1][1]), '30')
        -- trailing junk -> NULL.
        local r2 = box.execute([=[SELECT data['10kek'] FROM t WHERE id = 1]=])
        t.assert_equals(r2.rows[1][1], box.NULL)
        -- fractional text -> NULL.
        local r3 = box.execute([=[SELECT data['1.5'] FROM t WHERE id = 1]=])
        t.assert_equals(r3.rows[1][1], box.NULL)
        -- a value above INT64_MAX must not wrap negative and alias an
        -- element via the from-the-end rule; it is out of range -> NULL.
        local r4 = box.execute(
            [=[SELECT data['18446744073709551614'] FROM t WHERE id = 1]=])
        t.assert_equals(r4.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 18: negative array indices count from the end; past the start is NULL.
g.test_subscript_array_negative_index = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, CAST([10, 20, 30] AS JSON))]=])
        local rlast = box.execute([=[SELECT data[-1] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(rlast.rows[1][1]), '30')
        local rfirst = box.execute([=[SELECT data[-3] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(rfirst.rows[1][1]), '10')
        local roff = box.execute([=[SELECT data[-4] FROM t WHERE id = 1]=])
        t.assert_equals(roff.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

-- Slice 19: an integer subscript on an object is stringized and used as an
-- object key (full PostgreSQL text model); absent -> SQL NULL.
g.test_subscript_object_integer_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'0': 'zero', 'a': 1} AS JSON))]])
        -- integer 0 stringizes to key "0".
        local r0 = box.execute([=[SELECT data[0] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(r0.rows[1][1]), '"zero"')
        -- string "0" looks up the same key.
        local rs = box.execute([=[SELECT data['0'] FROM t WHERE id = 1]=])
        t.assert_equals(tostring(rs.rows[1][1]), '"zero"')
        -- absent numeric key -> SQL NULL.
        local r9 = box.execute([=[SELECT data[9] FROM t WHERE id = 1]=])
        t.assert_equals(r9.rows[1][1], box.NULL)
        box.execute([[DROP TABLE t]])
    end)
end

--------------------------------------------------------------------------------
-- json_cast
--------------------------------------------------------------------------------

local g = t.group('json_cast')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'U'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- TO JSON: BOOLEAN/INTEGER/DOUBLE scalars become JSON scalars; the result
-- reports type json.
g.test_cast_to_json_scalars = function()
    g.server:exec(function()
        local res = box.execute([[SELECT CAST(true AS JSON)]])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), 'true')

        res = box.execute([[SELECT CAST(42 AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '42')

        res = box.execute([[SELECT CAST(2.5 AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '2.5')

        res = box.execute([[SELECT CAST(CAST(7 AS UNSIGNED) AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '7')
    end)
end

-- TO JSON: a DECIMAL becomes a JSON number (fractional value preserved).
g.test_cast_to_json_decimal = function()
    g.server:exec(function()
        local res = box.execute([[SELECT CAST(CAST(1.5 AS DECIMAL) AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '1.5')
    end)
end

-- TO JSON: an ARRAY becomes a JSON array (element order preserved).
g.test_cast_to_json_array = function()
    g.server:exec(function()
        local res = box.execute([=[SELECT CAST([3, 1, 2] AS JSON)]=])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), '[3, 1, 2]')
    end)
end

-- TO JSON: a MAP becomes a JSON object, recursively normalized (keys sorted).
g.test_cast_to_json_map_normalized = function()
    g.server:exec(function()
        local res = box.execute([[SELECT CAST({'b': 2, 'a': 1} AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

-- TO JSON: types with no JSON representation are rejected. They encode to
-- MessagePack that is not a valid JSON value, so validation reports that.
g.test_cast_to_json_unsupported_errors = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT CAST(uuid() AS JSON)]])
        t.assert_str_contains(err.message, 'not a valid json')

        _, err = box.execute([[SELECT CAST(now() AS JSON)]])
        t.assert_str_contains(err.message, 'not a valid json')

        _, err = box.execute([[SELECT CAST((now() - now()) AS JSON)]])
        t.assert_str_contains(err.message, 'not a valid json')

        _, err = box.execute([[SELECT CAST(x'31' AS JSON)]])
        t.assert_str_contains(err.message, 'not a valid json')
    end)
end

-- TO JSON: a container whose own kind is representable but whose nested
-- content is not (here, a VARBINARY element/value) is reported as a nested
-- failure, distinct from the whole-value message above, so a castable
-- array/map is not blamed as if it were the uncastable part.
g.test_cast_to_json_nested_unsupported_errors = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT CAST([1, 2, x'31'] AS JSON)]])
        t.assert_str_contains(err.message, 'array value is not a valid json')
        t.assert_str_contains(err.message, 'element')

        _, err = box.execute([[SELECT CAST({'a': x'31'} AS JSON)]])
        t.assert_str_contains(err.message, 'map value is not a valid json')
        t.assert_str_contains(err.message, 'element')
    end)
end

-- TO JSON: a map with a non-string key is rejected by the same pass, and so
-- reports the nested-failure message rather than a separate normalization
-- one. One walk normalizes and rejects, so there is only one message left to
-- report from.
g.test_cast_to_json_non_string_key_error = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT CAST({1: 2} AS JSON)]])
        t.assert_str_contains(err.message, 'map value is not a valid json')
        t.assert_str_contains(err.message, 'element')
    end)
end

-- TO JSON: a SQL NULL stays a SQL NULL (it does not become a JSON null).
g.test_cast_null_to_json_is_sql_null = function()
    g.server:exec(function()
        local res = box.execute([[SELECT CAST(NULL AS JSON)]])
        t.assert_equals(res.rows[1][1], box.NULL)

        res = box.execute([[SELECT CAST(NULL AS JSON) IS NULL]])
        t.assert_equals(res.rows[1][1], true)
    end)
end

-- CAST(text AS JSON) parses the text as a JSON document, so an array- or
-- object-looking string becomes the structured value, and a quoted string
-- becomes a JSON string scalar.
g.test_cast_text_to_json_parses = function()
    g.server:exec(function()
        -- A quoted JSON string parses to a JSON string scalar.
        local res = box.execute([[SELECT CAST('"hello"' AS JSON)]])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), '"hello"')

        -- An array-looking string parses to a JSON array.
        res = box.execute([=[SELECT CAST('[1,2,3]' AS JSON)]=])
        t.assert_equals(tostring(res.rows[1][1]), '[1, 2, 3]')

        -- An object-looking string parses to a JSON object (keys sorted).
        res = box.execute([[SELECT CAST('{"b":2,"a":1}' AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')

        -- Scalar-looking strings parse to the matching JSON scalar.
        res = box.execute([[SELECT CAST('42' AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), '42')
        res = box.execute([[SELECT CAST('true' AS JSON)]])
        t.assert_equals(tostring(res.rows[1][1]), 'true')

        -- Bare (unquoted) text is not valid JSON, so it errors.
        local _, err = box.execute([[SELECT CAST('hello' AS JSON)]])
        t.assert_str_contains(err.message, 'Failed to parse JSON')
    end)
end

-- CAST(text AS JSON) can fail with a code other than ER_JSON_PARSE: an
-- out-of-range integer literal is ER_INT_LITERAL_MAX, and an over-precision
-- or over-magnitude decimal literal is ER_INVALID_DEC. A client keying on
-- 275 alone to mean "malformed document" would misclassify both.
g.test_cast_text_to_json_number_error_codes = function()
    g.server:exec(function()
        local _, err = box.execute(
            [[SELECT CAST('18446744073709551616' AS JSON)]])
        t.assert_str_contains(err.message, 'exceeds the supported range')

        _, err = box.execute([[SELECT CAST(
            '100000000000000000000000000000000000000000000000000.0'
            AS JSON)]])
        t.assert_str_contains(err.message, 'Invalid decimal')
    end)
end

-- FROM JSON: a JSON number reinterprets as every numeric SQL type.
g.test_from_json_number_reinterprets_as_numeric = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'n': 42} AS JSON))]])

        local res = box.execute([=[SELECT CAST(data['n'] AS INTEGER) FROM t]=])
        t.assert_equals(res.rows[1][1], 42)
        res = box.execute([=[SELECT CAST(data['n'] AS UNSIGNED) FROM t]=])
        t.assert_equals(res.rows[1][1], 42)
        res = box.execute([=[SELECT CAST(data['n'] AS DOUBLE) FROM t]=])
        t.assert_equals(res.rows[1][1], 42)
        res = box.execute([=[SELECT CAST(data['n'] AS NUMBER) FROM t]=])
        t.assert_equals(res.rows[1][1], 42)
        res = box.execute([=[SELECT CAST(data['n'] AS DECIMAL) FROM t]=])
        t.assert_equals(tostring(res.rows[1][1]), '42')
    end)
end

-- FROM JSON: a JSON bool reinterprets as BOOLEAN.
g.test_from_json_bool_reinterprets_as_boolean = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'b': true} AS JSON))]])
        local res = box.execute([=[SELECT CAST(data['b'] AS BOOLEAN) FROM t]=])
        t.assert_equals(res.rows[1][1], true)
    end)
end

-- FROM JSON: TEXT renders the whole value as canonical JSON text. Unlike the
-- scalar reinterpretations this is total, so every kind has a result and a
-- container is no exception.
g.test_from_json_to_text_serializes = function()
    g.server:exec(function()
        local cases = {
            {'"hi"', '"hi"'},
            {'"a\\"b"', '"a\\"b"'},
            {'42', '42'},
            {'1.5', '1.5'},
            {'true', 'true'},
            {'null', 'null'},
            {'{"b": 2, "a": 1}', '{"a": 1, "b": 2}'},
            {'[1, 2]', '[1, 2]'},
        }
        for _, case in ipairs(cases) do
            local res = box.execute(
                ("SELECT CAST(CAST('%s' AS JSON) AS TEXT)"):format(case[1]))
            t.assert_equals(res.metadata[1].type, 'string')
            t.assert_equals(res.rows[1][1], case[2])
        end

        local res = box.execute([[SELECT CAST(json_null() AS TEXT)]])
        t.assert_equals(res.rows[1][1], 'null')
    end)
end

-- The rendered text is the same text QUOTE() produces, and it parses back into
-- an equal JSON value: quotes are kept, so the round trip is exact and a JSON
-- string stays distinct from the number that prints the same.
g.test_from_json_to_text_round_trips = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST(CAST('{"b": 2, "a": 1}' AS JSON) AS TEXT)
                     = QUOTE(CAST('{"b": 2, "a": 1}' AS JSON))
        ]])
        t.assert_equals(res.rows[1][1], true)

        res = box.execute([[
            SELECT CAST(CAST(CAST('"1"' AS JSON) AS TEXT) AS JSON)
                     = CAST('"1"' AS JSON),
                   CAST(CAST(CAST('"1"' AS JSON) AS TEXT) AS JSON)
                     = CAST('1' AS JSON)
        ]])
        t.assert_equals(res.rows[1], {true, false})
    end)
end

-- A projection over a column holding several JSON kinds renders every row, so
-- the statement does not live or die on the rows it happens to read.
g.test_from_json_to_text_over_mixed_column = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST('"Bob"' AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, CAST('42' AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST('{"a": 1}' AS JSON))]])
        box.execute([[INSERT INTO t VALUES (4, json_null())]])
        local res = box.execute(
            [[SELECT CAST(data AS TEXT) FROM t ORDER BY id]])
        t.assert_equals(res.rows,
                        {{'"Bob"'}, {'42'}, {'{"a": 1}'}, {'null'}})

        -- The result is an ordinary TEXT value, usable as one.
        res = box.execute(
            [[SELECT CAST(data AS TEXT) || '!' FROM t WHERE id = 2]])
        t.assert_equals(res.rows[1][1], '42!')
    end)
end

-- FROM JSON: casting a JSON value to JSON is the identity.
g.test_from_json_to_json_identity = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'n': 42} AS JSON))]])
        local res = box.execute([=[SELECT CAST(data['n'] AS JSON) FROM t]=])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), '42')
    end)
end

-- FROM JSON is kind-strict: the inner kind must match the target.
g.test_from_json_mismatch_errors = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(
            {'n': 42, 'b': true, 's': 'hi', 'nul': null} AS JSON))]])

        local _, err = box.execute(
            [=[SELECT CAST(data['n'] AS BOOLEAN) FROM t]=])
        t.assert_equals(err.message,
                        'Type mismatch: can not convert json(42) to boolean')

        _, err = box.execute([=[SELECT CAST(data['b'] AS INTEGER) FROM t]=])
        t.assert_equals(err.message,
                        'Type mismatch: can not convert json(true) to integer')

        -- A JSON string does NOT loosely parse into a number.
        _, err = box.execute([=[SELECT CAST(data['s'] AS INTEGER) FROM t]=])
        t.assert_equals(err.message,
                        'Type mismatch: can not convert json("hi") to integer')

        -- A present JSON null is a value, not SQL NULL: it errors, not NULLs.
        _, err = box.execute([=[SELECT CAST(data['nul'] AS INTEGER) FROM t]=])
        t.assert_equals(err.message,
                        'Type mismatch: can not convert json(null) to integer')
    end)
end

-- Nothing is implicitly converted on assignment, container literals included.
-- Every source here is a SQL value that merely has a JSON counterpart, not a
-- JSON document, so storing one asks for the conversion with CAST.
g.test_nothing_converts_to_json_implicitly = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        for i, literal in ipairs({'42', 'true', '1.5', "{'a': 1}",
                                  '[10, 20]'}) do
            local res, err = box.execute(
                ('INSERT INTO t VALUES (%d, %s)'):format(i, literal))
            t.assert_equals(res, nil, literal)
            t.assert_str_contains(err.message, 'to json', false, literal)
        end
        t.assert_equals(box.execute([[SELECT count(*) FROM t]]).rows, {{0}})

        -- The cast is the way in, and it stores the matching JSON scalar.
        box.execute([[INSERT INTO t VALUES (1, CAST(42 AS JSON)),
                      (2, CAST(true AS JSON)), (3, CAST(1.5 AS JSON))]])
        local res = box.execute([[SELECT data FROM t ORDER BY id]])
        t.assert_equals(tostring(res.rows[1][1]), '42')
        t.assert_equals(tostring(res.rows[2][1]), 'true')
        t.assert_equals(tostring(res.rows[3][1]), '1.5')
    end)
end

-- Cast a container literal and it stores as a JSON container, subscriptable
-- by key and by index.
g.test_cast_container_literal_is_container = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a': 1} AS JSON))]])
        local res = box.execute([=[SELECT data['a'] FROM t]=])
        t.assert_equals(tostring(res.rows[1][1]), '1')

        box.execute([=[INSERT INTO t VALUES (2, CAST([10, 20] AS JSON))]=])
        local r2 = box.execute([=[SELECT data[0] FROM t WHERE id = 2]=])
        t.assert_equals(tostring(r2.rows[1][1]), '10')
    end)
end

-- Text is refused like every other source, and is the strongest case for the
-- rule: it would have to be parsed, and whether that succeeds depends on the
-- text. Implicit, a query over a TEXT column would live or die on the rows it
-- happens to read.
g.test_no_implicit_text_to_json = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])

        -- Well-formed JSON text is rejected just like anything else: this
        -- is a type rule, not a parse result.
        local res, err = box.execute([[INSERT INTO t VALUES (1, '{"a":1}')]])
        t.assert_equals(res, nil)
        t.assert_equals(err.message, 'Type mismatch: can not convert ' ..
                        'string(\'{"a":1}\') to json')

        res, err = box.execute([[INSERT INTO t VALUES (2, 'hello')]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'Type mismatch')

        -- A TEXT column is rejected the same way, at the same point.
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, s TEXT)]])
        box.execute([[INSERT INTO u VALUES (1, '{"a":1}')]])
        res, err = box.execute([[INSERT INTO t SELECT id, s FROM u]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'Type mismatch')

        t.assert_equals(box.execute([[SELECT count(*) FROM t]]).rows, {{0}})

        -- Both explicit forms still parse the text.
        box.execute([[INSERT INTO t VALUES (1, CAST('{"a":1}' AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, JSON_PARSE('{"b":2}'))]])
        local rows = box.execute([[SELECT data FROM t ORDER BY id]]).rows
        t.assert_equals(tostring(rows[1][1]), '{"a": 1}')
        t.assert_equals(tostring(rows[2][1]), '{"b": 2}')
    end)
end

-- IN against a JSON set: a STRING probe is a type error, not a per-row parse
-- attempt, whether it arrives as a literal, a bound parameter or a typed
-- column. An explicitly built probe still finds its match.
g.test_in_json_string_probe_is_type_error = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST('[1,2,3]' AS JSON))]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, s TEXT)]])
        box.execute([[INSERT INTO u VALUES (1, '[1,2,3]')]])

        -- A literal.
        local res, err = box.execute(
            [[SELECT '[1,2,3]' IN (SELECT j FROM t)]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message:lower(), 'type mismatch')

        -- A bound parameter has no declared type of its own, so nothing
        -- casts the probe and the JSON-typed ephemeral set rejects it
        -- itself. Still an error, in the index's wording rather than the
        -- type system's.
        res, err = box.execute([[SELECT ? IN (SELECT j FROM t)]], {'[1,2,3]'})
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message:lower(),
                              'does not match index part type')

        -- A typed column.
        res, err = box.execute([[SELECT s FROM u
                                  WHERE s IN (SELECT j FROM t)]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message:lower(), 'type mismatch')

        -- An explicit cast is the way to probe with text.
        local ok = box.execute(
            [[SELECT CAST('[1,2,3]' AS JSON) IN (SELECT j FROM t)]])
        t.assert_equals(ok.rows[1][1], true)
        ok = box.execute(
            [[SELECT JSON_PARSE('[9,9,9]') IN (SELECT j FROM t)]])
        t.assert_equals(ok.rows[1][1], false)
    end)
end

-- IN against a JSON set is a comparison, so it follows the comparison rule
-- rather than the assignment one: a scalar probe is a type error, exactly as
-- `= j` is. Through the assignment cast, `7 IN (SELECT j)` used to answer
-- true where `7 = j` errored.
g.test_in_json_scalar_probe_is_type_error = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(7 AS JSON))]])

        for _, probe in ipairs({'7', '8', 'true', '1.5', "x'07'"}) do
            local res, err = box.execute(
                ('SELECT %s IN (SELECT j FROM t)'):format(probe))
            t.assert_equals(res, nil, probe)
            t.assert_str_contains(err.message, 'to json', false, probe)
        end

        -- The cast is the way in, and then the lookup answers.
        local res = box.execute([[SELECT CAST(7 AS JSON) IN (SELECT j FROM t)]])
        t.assert_equals(res.rows[1][1], true)
        res = box.execute([[SELECT CAST(8 AS JSON) IN (SELECT j FROM t)]])
        t.assert_equals(res.rows[1][1], false)
    end)
end

-- JSON is not a SCALAR. An explicit CAST to SCALAR is rejected (like ARRAY/MAP
-- are), and a builtin that coerces its arguments to SCALAR (GREATEST/LEAST)
-- rejects a JSON argument rather than implicitly accepting it and ranking it
-- above every scalar.
g.test_json_is_not_scalar = function()
    g.server:exec(function()
        -- Explicit cast (mem_cast_explicit).
        local res, err = box.execute([[SELECT CAST(CAST(2 AS JSON) AS SCALAR)]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message:lower(), 'scalar')

        -- A builtin that coerces its arguments to SCALAR (GREATEST/LEAST) has
        -- no overload accepting JSON, so (as for MAP/ARRAY) it is rejected
        -- cleanly at prepare instead of ranking above every scalar mid-scan.
        res, err = box.execute([[SELECT GREATEST(1, CAST(2 AS JSON))]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message:lower(),
                              'wrong arguments for function greatest')
    end)
end

--------------------------------------------------------------------------------
-- json_compound
--------------------------------------------------------------------------------

local g = t.group('json_compound')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'U'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- UNION over a JSON column returns the distinct rows as well-formed JSON,
-- with no leaked envelope/internal bytes in the output.
g.test_union_distinct_rows = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST(1 AS JSON) UNION SELECT CAST(2 AS JSON) ORDER BY 1]])
        t.assert_equals(res.metadata[1].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'1', '2'})
    end)
end

-- UNION ALL keeps duplicates; the set operators apply set semantics.
g.test_union_all_preserves_duplicates = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST(1 AS JSON) UNION ALL SELECT CAST(1 AS JSON)]])
        t.assert_equals(#res.rows, 2)
        t.assert_equals(tostring(res.rows[1][1]), '1')
        t.assert_equals(tostring(res.rows[2][1]), '1')
    end)
end

-- Normalization-aware dedup across branches: {'a':1,'b':2} from one branch
-- deduplicates against {'b':2,'a':1} from the other under UNION.
g.test_union_dedup_normalized = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST({'a': 1, 'b': 2} AS JSON)
            UNION
            SELECT CAST({'b': 2, 'a': 1} AS JSON)]])
        t.assert_equals(#res.rows, 1)
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

-- INTERSECT applies set semantics across two JSON columns. No ORDER BY, so the
-- set operation runs through the ephemeral table (not the sorter): assert as
-- a set.
g.test_intersect = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(1 AS JSON)),
                      (2, CAST(2 AS JSON)), (3, CAST(3 AS JSON))]])
        box.execute([[INSERT INTO u VALUES (1, CAST(2 AS JSON)),
                      (2, CAST(3 AS JSON)), (3, CAST(4 AS JSON))]])
        local res = box.execute([[
            SELECT j FROM t INTERSECT SELECT j FROM u]])
        t.assert_equals(res.metadata[1].type, 'json')
        local set = {}
        for _, row in ipairs(res.rows) do
            set[tostring(row[1])] = true
        end
        t.assert_equals(#res.rows, 2)
        t.assert_equals(set, {['2'] = true, ['3'] = true})
    end)
end

-- EXCEPT applies set semantics across two JSON columns (ephemeral path).
g.test_except = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(1 AS JSON)),
                      (2, CAST(2 AS JSON)), (3, CAST(3 AS JSON))]])
        box.execute([[INSERT INTO u VALUES (1, CAST(2 AS JSON)),
                      (2, CAST(3 AS JSON)), (3, CAST(4 AS JSON))]])
        local res = box.execute([[
            SELECT j FROM t EXCEPT SELECT j FROM u]])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(#res.rows, 1)
        t.assert_equals(tostring(res.rows[1][1]), '1')
    end)
end

-- Value-equal but differently-encoded numbers still dedup under UNION: {'a':1}
-- (integer) and {'a':1.0} collapse to one row because equality is by value.
-- Numbers are preserved as written, so the surviving row's encoding is
-- order-dependent; assert only the row count.
g.test_union_numeric_value_equal_dedup_integral = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST({'a': 1} AS JSON)
            UNION
            SELECT CAST({'a': 1.0} AS JSON)]])
        t.assert_equals(#res.rows, 1)
    end)
end

-- Numeric dedup: {'a':1.5} (double) and {'a':1.50} (decimal) are value-equal,
-- so they dedup to one row (the surviving representation is arbitrary).
g.test_union_numeric_value_equal_dedup = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST({'a': 1.5} AS JSON)
            UNION
            SELECT CAST({'a': CAST(1.50 AS DECIMAL)} AS JSON)]])
        t.assert_equals(#res.rows, 1)
    end)
end

-- Distinct numeric values stay separate.
g.test_union_distinct_numbers_separate = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT CAST(1 AS JSON) UNION SELECT CAST(2 AS JSON)
            UNION SELECT CAST(1.5 AS JSON) UNION SELECT CAST(2.5 AS JSON)
            ORDER BY 1]])
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'1', '1.5', '2', '2.5'})
    end)
end

-- Mixed kinds in one compound column order and dedup by JSONB rules
-- (string < number < array < object).
g.test_union_mixed_kinds = function()
    g.server:exec(function()
        local res = box.execute([=[
            SELECT CAST(5 AS JSON) UNION SELECT CAST('"x"' AS JSON)
            UNION SELECT CAST([1] AS JSON) UNION SELECT CAST({'a': 1} AS JSON)
            ORDER BY 1]=])
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'"x"', '5', '[1]', '{"a": 1}'})
    end)
end

-- JSON null and SQL NULL across branches each form their own row.
g.test_union_json_null_vs_sql_null = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT json_null() UNION SELECT CAST(NULL AS JSON)]])
        t.assert_equals(#res.rows, 2)
        local sql_nulls, json_nulls = 0, 0
        for _, row in ipairs(res.rows) do
            if row[1] == box.NULL then
                sql_nulls = sql_nulls + 1
            elseif tostring(row[1]) == 'null' then
                json_nulls = json_nulls + 1
            end
        end
        t.assert_equals(sql_nulls, 1)
        t.assert_equals(json_nulls, 1)
    end)
end

-- A compound of a JSON branch and an INTEGER branch is a defined error,
-- not a crash and not a silent coercion.
g.test_compound_type_mismatch_error = function()
    g.server:exec(function()
        local _, err = box.execute([[
            SELECT CAST(1 AS JSON) UNION SELECT 2]])
        t.assert_not_equals(err, nil)
        t.assert_str_contains(err.message,
                              'JSON cannot be combined with a non-JSON type')
    end)
end

-- The JSON/non-JSON mismatch is a defined error for every compound operator,
-- not only the dedup ones. UNION ALL streams each branch straight to the
-- destination, so without a type check it would return a mix of JSON and
-- non-JSON rows under a JSON column instead of erroring.
g.test_compound_all_type_mismatch_error = function()
    g.server:exec(function()
        for _, sql in ipairs({
            [[SELECT CAST(1 AS JSON) UNION ALL SELECT 2]],
            [[SELECT 2 UNION ALL SELECT CAST(1 AS JSON)]],
            [[SELECT CAST(1 AS JSON) UNION ALL SELECT 'x']],
            [[SELECT CAST(1 AS JSON) EXCEPT SELECT 2]],
            [[SELECT CAST(1 AS JSON) INTERSECT SELECT 2]],
        }) do
            local _, err = box.execute(sql)
            t.assert_not_equals(err, nil, sql)
            t.assert_str_contains(
                err.message,
                'JSON cannot be combined with a non-JSON type', false, sql)
        end
    end)
end

-- A literal NULL branch adopts the column type, so it stays compatible with a
-- JSON branch under UNION ALL (NULL is not a conflicting concrete type).
g.test_compound_all_json_null_branch_ok = function()
    g.server:exec(function()
        local res = box.execute(
            [[SELECT CAST(1 AS JSON) UNION ALL SELECT NULL]])
        t.assert_equals(#res.rows, 2)
    end)
end

--------------------------------------------------------------------------------
-- json_ephemeral
--------------------------------------------------------------------------------

local g = t.group('json_ephemeral')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'U'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- GROUP BY groups normalization-equal JSON values together: an object differing
-- only in key order is one group.
g.test_group_by_normalized = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'a': 1, 'b': 2} AS JSON))]])
        box.execute(
            [[INSERT INTO t VALUES (2, CAST({'b': 2, 'a': 1} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST({'c': 3} AS JSON))]])
        local res = box.execute([[
            SELECT j, COUNT(*) FROM t GROUP BY j]])
        local counts = {}
        for _, row in ipairs(res.rows) do
            counts[tostring(row[1])] = row[2]
        end
        t.assert_equals(counts['{"a": 1, "b": 2}'], 2)
        t.assert_equals(counts['{"c": 3}'], 1)
        t.assert_equals(#res.rows, 2)
    end)
end

-- GROUP BY groups value-equal numbers by value: {'n':1} (integer) and {'n':1.0}
-- fall in one group even though their encodings differ.
g.test_group_by_value_equal_numbers = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'n': 1} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, CAST({'n': 1.0} AS JSON))]])
        local res = box.execute([[SELECT COUNT(*) FROM t GROUP BY j]])
        t.assert_equals(#res.rows, 1)
        t.assert_equals(res.rows[1][1], 2)
    end)
end

-- SELECT DISTINCT collapses normalization-equal JSON values.
g.test_distinct_collapses = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'a': 1, 'b': 2} AS JSON))]])
        box.execute(
            [[INSERT INTO t VALUES (2, CAST({'b': 2, 'a': 1} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST({'c': 3} AS JSON))]])
        local res = box.execute([[SELECT DISTINCT j FROM t ORDER BY 1]])
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'{"c": 3}', '{"a": 1, "b": 2}'})
    end)
end

-- JSON null forms its own group under GROUP BY, distinct from the SQL-NULL
-- group and from present values.
g.test_group_by_json_null_own_group = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, json_null())]])
        box.execute([[INSERT INTO t VALUES (2, json_null())]])
        box.execute([[INSERT INTO t VALUES (3, CAST(NULL AS JSON))]])
        box.execute([[INSERT INTO t VALUES (4, CAST(7 AS JSON))]])
        local res = box.execute([[SELECT j, COUNT(*) FROM t GROUP BY j]])
        -- Three groups: JSON null (2), SQL NULL (1), and 7 (1).
        t.assert_equals(#res.rows, 3)
        local json_null_count, sql_null_count, seven_count = 0, 0, 0
        for _, row in ipairs(res.rows) do
            if row[1] == box.NULL then
                sql_null_count = row[2]
            elseif tostring(row[1]) == 'null' then
                json_null_count = row[2]
            elseif tostring(row[1]) == '7' then
                seven_count = row[2]
            end
        end
        t.assert_equals(json_null_count, 2)
        t.assert_equals(sql_null_count, 1)
        t.assert_equals(seven_count, 1)
    end)
end

-- SELECT DISTINCT keeps JSON null and SQL NULL apart.
g.test_distinct_json_null_vs_sql_null = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, json_null())]])
        box.execute([[INSERT INTO t VALUES (2, CAST(NULL AS JSON))]])
        local res = box.execute([[SELECT DISTINCT j FROM t]])
        t.assert_equals(#res.rows, 2)
    end)
end

-- ORDER BY a JSON column sorts by JSONB rules through the sorter.
g.test_order_by_data = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(2 AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, CAST(1 AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST(3 AS JSON))]])
        local res = box.execute([[SELECT j FROM t ORDER BY j]])
        t.assert_equals(res.metadata[1].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'1', '2', '3'})
    end)
end

-- ORDER BY a subscript result (a JSON value) passes through the sorter.
g.test_order_by_subscript = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'k': 2} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (2, CAST({'k': 1} AS JSON))]])
        box.execute([[INSERT INTO t VALUES (3, CAST({'k': 3} AS JSON))]])
        local res = box.execute([=[SELECT j['k'] FROM t ORDER BY j['k']]=])
        t.assert_equals(res.metadata[1].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'1', '2', '3'})
    end)
end

-- A scalar subquery carries a JSON value out through a metadata-free context.
g.test_scalar_subquery = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST({'a': 1} AS JSON))]])
        local res = box.execute([[
            SELECT (SELECT j FROM t WHERE id = 1)]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1}')
    end)
end

-- IN (SELECT ...) builds an ephemeral set keyed on a JSON column.
g.test_in_select = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(1 AS JSON)),
                      (2, CAST(2 AS JSON)), (3, CAST(3 AS JSON))]])
        box.execute([[INSERT INTO u VALUES (1, CAST(2 AS JSON)),
                      (2, CAST(3 AS JSON))]])
        local res = box.execute([[
            SELECT id, j FROM t WHERE j IN (SELECT j FROM u) ORDER BY id]])
        t.assert_equals(res.metadata[2].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, row[1])
        end
        t.assert_equals(out, {2, 3})
    end)
end

-- IN (exprlist) builds an ephemeral set from a JSON value list.
g.test_in_exprlist = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES (1, CAST(1 AS JSON)),
                      (2, CAST(2 AS JSON)), (3, CAST(3 AS JSON))]])
        local res = box.execute([[
            SELECT id, j FROM t
            WHERE j IN (CAST(2 AS JSON), CAST(3 AS JSON)) ORDER BY id]])
        t.assert_equals(res.metadata[2].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, row[1])
        end
        t.assert_equals(out, {2, 3})
    end)
end

-- VALUES rows of JSON dedup and order correctly through DISTINCT.
g.test_values_dedup = function()
    g.server:exec(function()
        local res = box.execute([[
            SELECT DISTINCT * FROM
                (VALUES (CAST(1 AS JSON)), (CAST(1 AS JSON)),
                        (CAST(2 AS JSON)))
            ORDER BY 1]])
        t.assert_equals(res.metadata[1].type, 'json')
        local out = {}
        for _, row in ipairs(res.rows) do
            table.insert(out, tostring(row[1]))
        end
        t.assert_equals(out, {'1', '2'})
    end)
end

-- A CTE carries a JSON value in and back out.
g.test_cte = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'a': 1, 'b': 2} AS JSON))]])
        local res = box.execute([[
            WITH c AS (SELECT j FROM t) SELECT j FROM c]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

-- INSERT ... SELECT round-trips a JSON value into a JSON column
-- (re-validated by the box boundary).
g.test_insert_select = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[CREATE TABLE u (id INT PRIMARY KEY, j JSON)]])
        box.execute(
            [[INSERT INTO t VALUES (1, CAST({'b': 2, 'a': 1} AS JSON))]])
        box.execute([[INSERT INTO u SELECT id, j FROM t]])
        local res = box.execute([[SELECT j FROM u WHERE id = 1]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

--------------------------------------------------------------------------------
-- json_deferred
--------------------------------------------------------------------------------

local g = t.group('json_deferred')

g.before_all(function()
    g.server = json_server
end)

-- Drop tables/spaces a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'SI'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
        for _, name in ipairs({'mt_json', 'vt_json'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
    end)
end)

-- Deferred: a JSON column cannot be a PRIMARY KEY (SQL); the table is not
-- created.
g.test_sql_primary_key_on_json_rejected = function()
    g.server:exec(function()
        local _, err = box.execute(
            [[CREATE TABLE t (data JSON PRIMARY KEY)]])
        t.assert_not_equals(err, nil)
        local msg = string.lower(tostring(err))
        t.assert_str_contains(msg, 'json')
        t.assert_str_contains(msg, 'not supported')
        t.assert_equals(box.space.T, nil)
    end)
end

-- Deferred: a JSON column cannot carry a UNIQUE constraint (a secondary index).
g.test_sql_unique_on_json_rejected = function()
    g.server:exec(function()
        local _, err = box.execute(
            [[CREATE TABLE t (id INT PRIMARY KEY, j JSON UNIQUE)]])
        t.assert_not_equals(err, nil)
        t.assert_str_contains(string.lower(tostring(err)), 'json')
        t.assert_equals(box.space.T, nil)
    end)
end

-- Deferred: CREATE INDEX on a JSON column is rejected; the base table survives
-- but no index is built.
g.test_sql_secondary_index_on_json_rejected = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE si (id INT PRIMARY KEY, j JSON)]])
        local _, err = box.execute([[CREATE INDEX si_j ON si (j)]])
        t.assert_not_equals(err, nil)
        t.assert_str_contains(string.lower(tostring(err)), 'json')
        t.assert_equals(box.space.SI.index.SI_J, nil)
    end)
end

-- Deferred + uniform across engines: a JSON index key part is rejected on BOTH
-- memtx and vinyl, with the same error message (so neither engine silently
-- allows what the other forbids).
g.test_index_on_json_rejected_both_engines = function()
    g.server:exec(function()
        local function try_engine(engine, space_name)
            local s = box.schema.space.create(space_name, {engine = engine})
            s:format({{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}})
            s:create_index('p')
            local ok, err = pcall(s.create_index, s, 's',
                                  {parts = {{2, 'json'}}})
            t.assert_equals(ok, false)
            return tostring(err)
        end
        local memtx_err = try_engine('memtx', 'mt_json')
        local vinyl_err = try_engine('vinyl', 'vt_json')
        -- The reason (the message tail after the space name) is
        -- engine-independent.
        local memtx_reason = memtx_err:match(':%s*(.*)$')
        local vinyl_reason = vinyl_err:match(':%s*(.*)$')
        t.assert_equals(memtx_reason, "field type 'json' is not supported")
        t.assert_equals(vinyl_reason, "field type 'json' is not supported")
    end)
end

-- Vinyl PRIMARY KEY on JSON is rejected too (the primary index path, not just a
-- secondary).
g.test_vinyl_primary_key_on_json_rejected = function()
    g.server:exec(function()
        local s = box.schema.space.create('vt_json', {engine = 'vinyl'})
        s:format({{name = 'j', type = 'json'}})
        local ok, err = pcall(s.create_index, s, 'p', {parts = {{1, 'json'}}})
        t.assert_equals(ok, false)
        t.assert_str_contains(string.lower(tostring(err)), 'json')
    end)
end

--------------------------------------------------------------------------------
-- json_parse
--------------------------------------------------------------------------------

local g = t.group('json_parse')

g.before_all(function()
    g.server = json_server
end)

-- Drop any tables a test created, so a mid-test failure cannot cascade.
g.after_each(function()
    g.server:exec(function()
        if box.space.T ~= nil then
            box.space.T:drop()
        end
    end)
end)

-- JSON_PARSE parses text into a structured JSON value and reports type json.
g.test_json_parse_containers = function()
    g.server:exec(function()
        local res = box.execute([=[SELECT JSON_PARSE('[1,2,3]')]=])
        t.assert_equals(res.metadata[1].type, 'json')
        t.assert_equals(tostring(res.rows[1][1]), '[1, 2, 3]')

        -- Object keys are normalized (sorted).
        res = box.execute([[SELECT JSON_PARSE('{"b":2,"a":1}')]])
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')

        -- Nested containers round-trip.
        res = box.execute([=[SELECT JSON_PARSE('[{"x":[1,2]}]')]=])
        t.assert_equals(tostring(res.rows[1][1]), '[{"x": [1, 2]}]')
    end)
end

-- JSON_PARSE of scalar text yields the matching JSON scalar.
g.test_json_parse_scalars = function()
    g.server:exec(function()
        local res = box.execute([[SELECT JSON_PARSE('"hello"')]])
        t.assert_equals(tostring(res.rows[1][1]), '"hello"')

        res = box.execute([[SELECT JSON_PARSE('42')]])
        t.assert_equals(tostring(res.rows[1][1]), '42')

        res = box.execute([[SELECT JSON_PARSE('-5')]])
        t.assert_equals(tostring(res.rows[1][1]), '-5')

        res = box.execute([[SELECT JSON_PARSE('12.5')]])
        t.assert_equals(tostring(res.rows[1][1]), '12.5')

        res = box.execute([[SELECT JSON_PARSE('true')]])
        t.assert_equals(tostring(res.rows[1][1]), 'true')

        res = box.execute([[SELECT JSON_PARSE('null')]])
        -- A JSON null is a value, distinct from SQL NULL.
        t.assert_equals(tostring(res.rows[1][1]), 'null')
        t.assert_equals(res.rows[1][1] == box.NULL, false)
    end)
end

-- The number kind follows the lexical rule: a fractional literal is a JSON
-- number that reinterprets as DECIMAL, so JSON_PARSE feeds the kind-strict
-- cast.
g.test_json_parse_number_reinterprets = function()
    g.server:exec(function()
        local res = box.execute(
            [[SELECT CAST(JSON_PARSE('12.5') AS DECIMAL)]])
        t.assert_equals(tostring(res.rows[1][1]), '12.5')

        res = box.execute([[SELECT CAST(JSON_PARSE('42') AS INTEGER)]])
        t.assert_equals(res.rows[1][1], 42)
    end)
end

-- SQL NULL passes through as SQL NULL (the argument is not parsed).
g.test_json_parse_null_argument = function()
    g.server:exec(function()
        local res = box.execute([[SELECT JSON_PARSE(NULL)]])
        t.assert_equals(res.rows[1][1], box.NULL)
    end)
end

-- A JSON_PARSE result is a genuine JSON value: it stores in a JSON column and
-- subscripts like any other (0-based).
g.test_json_parse_result_is_real_json = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([=[INSERT INTO t VALUES (1, JSON_PARSE('[10,20,30]'))]=])
        local res = box.execute([=[SELECT data[1] FROM t]=])
        t.assert_equals(tostring(res.rows[1][1]), '20')
    end)
end

-- Malformed and structurally invalid text is a parse error (ER_JSON_PARSE).
g.test_json_parse_syntax_errors = function()
    g.server:exec(function()
        for _, text in ipairs({'hello', '', '[1,2', '{"a":}', '1 2',
                               '{"a" 1}'}) do
            local _, err = box.execute(
                [[SELECT JSON_PARSE(']] .. text .. [[')]])
            t.assert_not_equals(err, nil, text)
            t.assert_str_contains(err.message, 'Failed to parse JSON', false,
                                  text)
        end
    end)
end

-- RFC 8259 admits only %x20 and above unescaped inside a string, so a raw
-- control character is a parse error even though the shared cjson lexer takes
-- it as an ordinary byte for Lua's json.decode(). The escape spelling of the
-- same character is accepted and renders identically.
g.test_json_parse_raw_control_char = function()
    g.server:exec(function()
        for name, ch in pairs({LF = '\n', CR = '\r', TAB = '\t',
                               NUL_NEXT = '\1', US = '\31'}) do
            local _, err = box.execute([[SELECT JSON_PARSE(?)]],
                                       {'"a' .. ch .. 'b"'})
            t.assert_not_equals(err, nil, name)
            t.assert_str_contains(err.message, 'control character in string',
                                  false, name)
        end

        -- 0x20 is the first byte the grammar admits raw, and DEL is not a
        -- control character as far as JSON is concerned.
        local res = box.execute([[SELECT JSON_PARSE(?)]], {'"a b"'})
        t.assert_equals(tostring(res.rows[1][1]), '"a b"')
        res = box.execute([[SELECT JSON_PARSE(?)]], {'"a\127b"'})
        t.assert_equals(res.rows[1][1] ~= nil, true)

        -- Written as an escape it is accepted, and renders back as one.
        res = box.execute([[SELECT JSON_PARSE(?)]], {'"a\\nb"'})
        t.assert_equals(tostring(res.rows[1][1]), '"a\\nb"')

        -- Lua's json.decode() keeps taking the raw byte: only we are strict.
        t.assert_equals(require('json').decode('"a\nb"'), 'a\nb')
    end)
end

-- A zero byte reads as the end of the text inside the lexer, so a document
-- that stops at one is truncated rather than complete. A bound parameter can
-- carry a NUL, and this is the validation gate for the JSON type.
g.test_json_parse_embedded_zero_byte = function()
    g.server:exec(function()
        local texts = {'1\0garbage', '{"a":1}\0 {', '[1,2]\0', '1\0'}
        for _, text in ipairs(texts) do
            local _, err = box.execute([[SELECT JSON_PARSE(?)]], {text})
            t.assert_not_equals(err, nil, text)
            t.assert_str_contains(err.message, 'embedded zero byte', false,
                                  text)
        end

        -- The same text without the tail is still accepted.
        local res = box.execute([[SELECT JSON_PARSE(?)]], {'{"a":1}'})
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1}')

        -- CAST is the same gate, and it is the storage path.
        local _, err = box.execute([[SELECT CAST(? AS JSON)]],
                                   {'[1,2]\0trailing'})
        t.assert_str_contains(err.message, 'embedded zero byte')
    end)
end

-- An integer literal outside [int64_min, uint64_max] is a range error, exactly
-- like a SQL integer literal.
g.test_json_parse_integer_overflow = function()
    g.server:exec(function()
        local _, err = box.execute(
            [[SELECT JSON_PARSE('18446744073709551616')]])
        t.assert_str_contains(err.message, 'exceeds the supported range')

        _, err = box.execute([[SELECT JSON_PARSE('-9223372036854775809')]])
        t.assert_str_contains(err.message, 'exceeds the supported range')
    end)
end

-- A fractional literal whose magnitude, or whose significant-digit count,
-- exceeds the decimal range is ER_INVALID_DEC, exactly like a SQL decimal
-- literal.
g.test_json_parse_decimal_overflow = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT JSON_PARSE(
            '100000000000000000000000000000000000000000000000000.0')]])
        t.assert_str_contains(err.message, 'Invalid decimal')

        _, err = box.execute([[SELECT JSON_PARSE(
            '0.123456789012345678901234567890123456789')]])
        t.assert_str_contains(err.message, 'Invalid decimal')
    end)
end

-- A number that overflows to Inf (NaN/Inf are not valid JSON) is rejected.
g.test_json_parse_non_finite_rejected = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT JSON_PARSE('1e400')]])
        t.assert_str_contains(err.message, 'Failed to parse JSON')
        t.assert_str_contains(err.message, 'NaN or Inf')
    end)
end

--------------------------------------------------------------------------------
-- json_perimeter
--------------------------------------------------------------------------------

local socket = require('socket')
local msgpack = require('msgpack')

local g = t.group('json_perimeter')

g.before_all(function()
    g.server = json_server
    -- The raw IPROTO rows below connect as 'guest'.
    g.server:exec(function()
        pcall(box.schema.user.grant, 'guest', 'super')
    end)
end)

g.after_each(function()
    g.server:exec(function()
        for _, name in ipairs({'T', 'T2'}) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end
        for _, name in ipairs({'JSON_ID', 'JSON_MAP'}) do
            if box.func[name] ~= nil then
                box.schema.func.drop(name)
            end
        end
    end)
end)

-- Storage never holds badly spelled JSON, and nothing is ever quietly fixed up
-- on its producer's behalf. Every case below is a way into the system, and
-- every one REFUSES: a malformed value is called malformed, and one that is
-- merely written in the wrong order is called not in normal form, with the
-- offset of the byte that gives it away.
-- Only two things put a value into normal form, and neither is here, because
-- neither takes an already-encoded JSON value from a client: JSON text, whose
-- key order is the author's own choice (tnt_json_parse), and a CAST of a SQL
-- MAP or ARRAY, built from a Lua table whose key order is arbitrary. Anything
-- handed a finished JSON value has to have spelled it right already.
-- Everything else rests on this list being complete, so a way in with no test
-- here is a hole.

--- Every shape the normal form rejects, and the value each is a spelling of.
local NON_NORMALIZED = {
    -- {"b": 1, "a": 2}: unsorted keys.
    {raw = '\x82\xa1b\x01\xa1a\x02', norm = '\x82\xa1a\x02\xa1b\x01',
     text = '{"a": 2, "b": 1}', what = 'unsorted keys'},
    -- {"a": 1, "a": 2}: duplicate key, last wins.
    {raw = '\x82\xa1a\x01\xa1a\x02', norm = '\x81\xa1a\x02',
     text = '{"a": 2}', what = 'duplicate key'},
    -- {"a": <uint8-encoded 1>}: non-minimal integer.
    {raw = '\x81\xa1a\xcc\x01', norm = '\x81\xa1a\x01',
     text = '{"a": 1}', what = 'non-minimal integer'},
    -- [<array16 header>, 1]: non-minimal container header.
    {raw = '\xdc\x00\x01\x01', norm = '\x91\x01',
     text = '[1]', what = 'non-minimal array header'},
    -- {<str8 key>: 1}: non-minimal string header on a key.
    {raw = '\x81\xd9\x01a\x01', norm = '\x81\xa1a\x01',
     text = '{"a": 1}', what = 'non-minimal key header'},
    -- [<str8 value>]: non-minimal string header on a value.
    {raw = '\x91\xd9\x01a', norm = '\x91\xa1a',
     text = '["a"]', what = 'non-minimal value header'},
}

--- Values that are not JSON because a string or key is not UTF-8. Nothing can
--- rewrite them, so every checked way in refuses them as invalid.
local BAD_UTF8 = {
    {raw = '\xa1\xff', what = '0xff in a string'},
    {raw = '\x81\xa1\xff\x01', what = '0xff in a key'},
    {raw = '\x92\xa1a\xa3\xed\xa0\x80', what = 'surrogate in a nested string'},
    {raw = '\xa1\xc3', what = 'cut short'},
    {raw = '\xa2\xc0\x80', what = 'overlong'},
}

--- A valid multibyte string, "é", which every one of those ways lets in.
local GOOD_UTF8 = {raw = '\xa2\xc3\xa9', text = '"\xc3\xa9"'}

--- Wrap an inner value in an MP_EXT/MP_JSON envelope, ext8 form.
local function envelope(inner)
    return '\xc7' .. string.char(#inner) .. '\x14' .. inner
end

--- An MP_ERROR whose one payload field, foo, holds the JSON value.
local function error_with_json(inner)
    local fields = '\x81\xa3foo' .. envelope(inner)
    -- type, file and message are the mandatory keys; 6 is the fields.
    local err = '\x84\x00\xabClientError\x01\xa1f\x03\xa1m\x06' .. fields
    local stack = '\x81\x00\x91' .. err
    return '\xc7' .. string.char(#stack) .. '\x03' .. stack
end

--- Lua source that decodes a JSON value through the checked entry point.
local function decoded(inner)
    return ("(require('msgpack').decode(%q))"):format(envelope(inner))
end

-- Lua source that forges a JSON cdata holding arbitrary bytes.
-- ffi.new('struct mp_json', n) is the only producer of a JSON value left in
-- Lua that nothing has looked at: msgpack.decode() and object_from_raw() both
-- reject a non-normalized payload, so neither can smuggle one in. Every test
-- below that needs a bad value builds it this way, which makes each of them a
-- test of the entry point it names rather than of the decoder.
local function forged(inner)
    return ([[(function()
        local ffi = require('ffi')
        local raw = %q
        local j = ffi.new('struct mp_json', #raw)
        ffi.copy(j, raw, #raw)
        return j
    end)()]]):format(inner)
end

-- A minimal IPROTO client. The network boundary can only be tested by a client
-- that does not validate, and no encoder in this process is one any more:
-- net.box, msgpack.encode and msgpackffi.encode all refuse to put a
-- non-normalized JSON value on the wire, so these rows hand-build the packet.
local IPROTO_REQUEST_TYPE = '\x00'
local IPROTO_SYNC = '\x01'
local IPROTO_SPACE_ID = '\x10'
local IPROTO_TUPLE = '\x21'
local IPROTO_ERROR_24 = '\x31'
local IPROTO_SQL_TEXT = '\x40'
local IPROTO_SQL_BIND = '\x41'
local IPROTO_INSERT = '\x02'
local IPROTO_EXECUTE = '\x0b'

--- Send a hand-built request body and return the response error, or nil.
--- extra_header, if given, is one more key and value for the header map.
local function raw_request(rtype, body, extra_header)
    local uri = g.server.net_box_uri
    local host, port = uri:match('^(.*):(%d+)$')
    local s
    if port ~= nil then
        s = assert(socket.tcp_connect(host, tonumber(port)), 'connect')
    else
        s = assert(socket.tcp_connect('unix/', uri), 'connect')
    end
    assert(s:read(128, 5) ~= nil, 'greeting')
    local header = (extra_header == nil and '\x82' or '\x83') ..
                   IPROTO_REQUEST_TYPE .. rtype .. IPROTO_SYNC .. '\x01' ..
                   (extra_header or '')
    local packet = header .. body
    s:write(msgpack.encode(#packet) .. packet)
    -- The response fixheader is a msgpack uint of unknown width, so decode it
    -- out of a prefix and read exactly the remainder it names.
    local head = assert(s:read(5, 5), 'response fixheader')
    local len, nxt = msgpack.decode(head)
    local rest = head:sub(nxt)
    while #rest < len do
        local chunk = assert(s:read(len - #rest, 5), 'response body')
        rest = rest .. chunk
    end
    s:close()
    local resp_header, after = msgpack.decode(rest)
    if bit.band(resp_header[0], 0x8000) == 0 then
        return nil
    end
    local resp_body = msgpack.decode(rest:sub(after))
    return resp_body[tonumber(IPROTO_ERROR_24:byte())]
end

--- An INSERT packet body carrying a hand-built tuple.
local function insert_body(space_id, tuple)
    return '\x82' .. IPROTO_SPACE_ID .. msgpack.encode(space_id) ..
           IPROTO_TUPLE .. tuple
end

-- Row: an iproto request body. The client sends raw bytes, so nothing on its
-- side normalizes them; the network is a validate boundary, so a
-- non-normalized value is rejected there and only the normal spelling is
-- stored.
g.test_perimeter_iproto_request = function()
    local space_id = g.server:exec(function()
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        return s.id
    end)
    for i, case in ipairs(NON_NORMALIZED) do
        -- The non-normalized spelling is rejected at the network boundary.
        local bad = '\x92' .. msgpack.encode(i) .. envelope(case.raw)
        t.assert_str_contains(raw_request(IPROTO_INSERT,
                                          insert_body(space_id, bad)) or '',
                              'not in normal form',
                              'iproto rejects: ' .. case.what)
        -- The normal spelling is accepted and stored verbatim.
        local good = '\x92' .. msgpack.encode(i) .. envelope(case.norm)
        t.assert_equals(raw_request(IPROTO_INSERT,
                                    insert_body(space_id, good)), nil,
                        'iproto accepts: ' .. case.what)
    end
    g.server:exec(function(cases)
        local mp = require('msgpack')
        for i, case in ipairs(cases) do
            t.assert_str_contains(mp.encode(box.space.T:get(i)),
                                  case.norm, false,
                                  'iproto: ' .. case.what)
        end
    end, {NON_NORMALIZED})
end

-- Row: an error in a request. An error's payload fields hold any MessagePack,
-- and error:unpack() hands them out with decode_unchecked(), so the check
-- has to reach into them where the error comes in.
g.test_perimeter_iproto_error_field = function()
    local space_id = g.server:exec(function()
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'e', type = 'any'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        return s.id
    end)
    for i, case in ipairs(NON_NORMALIZED) do
        local bad = '\x92' .. msgpack.encode(i) .. error_with_json(case.raw)
        t.assert_str_contains(raw_request(IPROTO_INSERT,
                                          insert_body(space_id, bad)) or '',
                              'not in normal form',
                              'iproto rejects in an error: ' .. case.what)
        local good = '\x92' .. msgpack.encode(i) .. error_with_json(case.norm)
        t.assert_equals(raw_request(IPROTO_INSERT,
                                    insert_body(space_id, good)), nil,
                        'iproto accepts in an error: ' .. case.what)
    end
    g.server:exec(function(cases)
        for i, case in ipairs(cases) do
            t.assert_equals(tostring(box.space.T:get(i)[2]:unpack().foo),
                            case.text, case.what)
        end
    end, {NON_NORMALIZED})
end

-- Row: the iproto header. Unknown keys are skipped by the server, but a
-- box.iproto.override() handler gets the whole header as a msgpack object,
-- which is taken as checked, so the header is checked like the body.
g.test_perimeter_iproto_header = function()
    local IPROTO_PING = '\x40'
    -- A key no request type knows about.
    local UNKNOWN_KEY = '\xcc\xc8'
    for _, case in ipairs(NON_NORMALIZED) do
        t.assert_str_contains(raw_request(IPROTO_PING, '',
                                          UNKNOWN_KEY .. envelope(case.raw))
                              or '', 'not in normal form',
                              'header rejects: ' .. case.what)
        t.assert_equals(raw_request(IPROTO_PING, '',
                                    UNKNOWN_KEY .. envelope(case.norm)), nil,
                        'header accepts: ' .. case.what)
    end
end

-- Row: SQL text. tnt_json_parse() emits normal form directly, so the two
-- spellings of one document give one stored value. This is one of the two
-- producers that legitimately normalizes: the order of keys in the text is the
-- author's, and no client could have been asked to sort it first.
g.test_perimeter_sql_text = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, j JSON)]])
        box.execute([[INSERT INTO t VALUES
                      (1, CAST('{"b": 1, "a": 2}' AS JSON)),
                      (2, CAST('{"a": 2, "b": 1}' AS JSON))]])
        local mp = require('msgpack')
        local a = mp.encode(box.space.T:get(1)[2])
        local b = mp.encode(box.space.T:get(2)[2])
        t.assert_equals(a, b, 'two spellings of one document store alike')
        t.assert_equals(tostring(box.space.T:get(1)[2]), '{"a": 2, "b": 1}')
        box.execute([[DROP TABLE t]])
    end)
end

-- Row: the Lua cdata boundary. A forged cdata holds bytes no parser has seen,
-- and every way from Lua into box refuses it: the two encoders and the write.
-- They all give the same answer about the same bytes, which is the property a
-- repairing encoder would have broken. The renderers do not judge a cdata, so
-- they print one in the spelling it holds.
g.test_perimeter_lua_cdata = function()
    g.server:exec(function(cases)
        local ffi = require('ffi')
        local mp = require('msgpack')
        local mpffi = require('msgpackffi')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        for i, case in ipairs(cases) do
            local j = ffi.new('struct mp_json', #case.raw)
            ffi.copy(j, case.raw, #case.raw)
            local why = ': ' .. case.what
            -- Every way into box, each behind its own closure so the
            -- assertion passes nothing extra to the callee.
            for what, f in pairs({
                msgpack = function() return mp.encode(j) end,
                msgpackffi = function() return mpffi.encode(j) end,
                insert = function() return s:insert({i, j}) end,
            }) do
                t.assert_error_msg_contains('not in normal form', f,
                                            what .. why)
            end
            for what, f in pairs({
                tostring = function() return tostring(j) end,
                yaml = function() return require('yaml').encode(j) end,
                json = function() return require('json').encode(j) end,
            }) do
                t.assert_type(f(), 'string', what .. why)
            end
            -- The normal spelling of the same value goes through all five.
            local n = ffi.new('struct mp_json', #case.norm)
            ffi.copy(n, case.norm, #case.norm)
            t.assert_equals(tostring(n), case.text, 'tostring norm' .. why)
            t.assert_equals(tostring(mp.decode(mp.encode(n))), case.text,
                            'msgpack norm' .. why)
            t.assert_equals(tostring(mpffi.decode(mpffi.encode(n))),
                            case.text, 'msgpackffi norm' .. why)
            s:insert({i, n})
            t.assert_str_contains(mp.encode(s:get(i)), case.norm, false,
                                  'stored' .. why)
        end
        t.assert_equals(s:count(), #cases)
        s:drop()
    end, {NON_NORMALIZED})
end

-- The Lua decode entry point. Raw bytes handed to msgpack.decode() or
-- msgpack.object_from_raw() came from outside, so they are checked right
-- there and not later: luamp_get() copies a decoded value straight into a
-- tuple without looking at it again.
g.test_perimeter_lua_decode = function()
    g.server:exec(function(cases, env)
        local mp = require('msgpack')
        for _, case in ipairs(cases) do
            local raw = loadstring('return ' .. env)()(case.raw)
            t.assert_error_msg_contains('not in normal form', function()
                return mp.decode(raw)
            end, 'decode: ' .. case.what)
            t.assert_error_msg_contains('not in normal form', function()
                return mp.object_from_raw(raw)
            end, 'object_from_raw: ' .. case.what)
            -- The normal spelling of the same value passes both.
            local ok = loadstring('return ' .. env)()(case.norm)
            t.assert_equals(tostring(mp.decode(ok)), case.text)
            -- A msgpack object renders as itself, so compare the bytes it
            -- holds: the point is that they went through untouched.
            t.assert_equals(mp.encode(mp.object_from_raw(ok)), ok)
        end
        -- Malformed bytes are refused too, under the other message: an ext8
        -- envelope promising three bytes that hold a two-key map header and
        -- one key.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return mp.decode('\xc7\x03\x14\x82\xa1a')
        end)
        t.assert_error_msg_contains('Invalid JSON value', function()
            return mp.object_from_raw('\xc7\x03\x14\x82\xa1a')
        end)
    end, {NON_NORMALIZED,
          [[function(inner)
                return '\xc7' .. string.char(#inner) .. '\x14' .. inner
            end]]})
end

-- The Lua decode entry points reach into an error's payload fields too, for
-- the same reason the iproto check does.
g.test_perimeter_lua_decode_error_field = function()
    local bad = {}
    local good = {}
    for i, case in ipairs(NON_NORMALIZED) do
        bad[i] = error_with_json(case.raw)
        good[i] = error_with_json(case.norm)
    end
    g.server:exec(function(cases, bad, good)
        local mp = require('msgpack')
        for i, case in ipairs(cases) do
            t.assert_error_msg_contains('not in normal form', function()
                return mp.decode(bad[i])
            end, 'decode: ' .. case.what)
            t.assert_error_msg_contains('not in normal form', function()
                return mp.object_from_raw(bad[i])
            end, 'object_from_raw: ' .. case.what)
            t.assert_equals(tostring(mp.decode(good[i]):unpack().foo),
                            case.text)
        end
    end, {NON_NORMALIZED, bad, good})
end

-- merger and the xlog reader make tuples out of bytes nothing has checked
-- yet. A JSON value in an error's field gets the same check there as
-- anywhere else.
g.test_perimeter_merger_error_field = function()
    local bad = {}
    local good = {}
    for i, case in ipairs(NON_NORMALIZED) do
        bad[i] = error_with_json(case.raw)
        good[i] = error_with_json(case.norm)
    end
    -- A lone 0xc1, the never-used byte, as the JSON value's payload.
    local malformed = error_with_json('\xc1')
    g.server:exec(function(cases, bad, good, malformed)
        local buffer = require('buffer')
        local ffi = require('ffi')
        local merger = require('merger')
        -- One tuple holding the one field, read back through merger.
        local function fetch(field)
            local raw = '\x91\x91' .. field
            local buf = buffer.ibuf()
            ffi.copy(buf:alloc(#raw), raw, #raw)
            return merger.new_source_frombuffer(buf):select()
        end
        t.assert_error_msg_contains('invalid JSON value in field [1]',
                                    fetch, malformed)
        for i, case in ipairs(cases) do
            t.assert_error_msg_contains('not in normal form', fetch, bad[i])
            local err = fetch(good[i])[1][1]
            t.assert_equals(tostring(err:unpack().foo), case.text, case.what)
        end
    end, {NON_NORMALIZED, bad, good, malformed})
end

-- A decode that succeeds leaves box.error.last() alone. The check tells a
-- JSON failure from a plain MessagePack one by whether it set a new error,
-- not by clearing the diag first.
g.test_perimeter_lua_decode_keeps_last_error = function()
    g.server:exec(function()
        local mp = require('msgpack')
        box.error.clear()
        pcall(box.error, box.error.ILLEGAL_PARAMS, 'kept')
        mp.decode(mp.encode({1, 2}))
        mp.object_from_raw(mp.encode({1, 2}))
        t.assert_equals(box.error.last().message, 'Illegal parameters, kept')
        -- Both failures still say what they are with an error already set.
        t.assert_error_msg_contains('invalid MsgPack', mp.decode, '\x92\x01')
        t.assert_error_msg_contains('Invalid JSON value', mp.decode,
                                    '\xc7\x03\x14\x82\xa1a')
        box.error.clear()
    end)
end

-- Row: UPDATE and UPSERT operands, on both engines, covering all three
-- application sites (space.c's upsert-as-insert, and each engine's update and
-- upsert). A non-normalized operand is rejected at each; the normal spelling
-- goes through and is stored verbatim.
g.test_perimeter_update_operands = function()
    for _, engine_name in ipairs({'memtx', 'vinyl'}) do
        g.server:exec(function(engine, mk_bad, mk_good, norm)
            local mp = require('msgpack')
            local s = box.schema.space.create('T', {engine = engine,
                format = {{name = 'id', type = 'unsigned'},
                          {name = 'j', type = 'json'}}})
            s:create_index('pk', {parts = {1, 'unsigned'}})
            local bad = loadstring('return ' .. mk_bad)()
            local good = loadstring('return ' .. mk_good)()
            -- INSERT operand.
            t.assert_error_msg_contains('not in normal form', function()
                s:insert({1, bad})
            end)
            -- UPDATE operand, against a row seeded with the normal spelling.
            s:insert({1, good})
            t.assert_error_msg_contains('not in normal form', function()
                s:update({1}, {{'=', 2, bad}})
            end)
            s:update({1}, {{'=', 2, good}})
            t.assert_str_contains(mp.encode(s:get(1)), norm, false,
                                  engine .. ': UPDATE operand')
            -- UPSERT-as-INSERT operand, then UPSERT operand on an existing row.
            t.assert_error_msg_contains('not in normal form', function()
                s:upsert({2, bad}, {{'=', 2, bad}})
            end)
            s:upsert({2, good}, {{'=', 2, good}})
            t.assert_str_contains(mp.encode(s:get(2)), norm, false,
                                  engine .. ': UPSERT as INSERT')
            t.assert_error_msg_contains('not in normal form', function()
                s:upsert({2, good}, {{'=', 2, bad}})
            end)
            s:drop()
        end, {engine_name, forged(NON_NORMALIZED[1].raw),
              forged(NON_NORMALIZED[1].norm), NON_NORMALIZED[1].norm})
    end
end

-- A stored function's return value. The return path reads the cdata's bytes
-- without encoding them, so it trusts them rather than checking the value all
-- over again. What keeps badly spelled JSON out is wherever the function got
-- its value from, here msgpack.decode(), which refuses the wrong spelling
-- inside the function body; the right spelling decodes and comes back out
-- through SQL.
g.test_perimeter_stored_function_return = function()
    g.server:exec(function(mk_bad, mk_good, text)
        local function define(mk)
            pcall(box.schema.func.drop, 'JSON_ID')
            box.schema.func.create('JSON_ID', {
                language = 'LUA',
                param_list = {},
                returns = 'json',
                body = 'function() return ' .. mk .. ' end',
                exports = {'SQL'},
                is_deterministic = true})
        end
        define(mk_bad)
        local r, e = box.execute([[SELECT JSON_ID()]])
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), 'not in normal form')
        define(mk_good)
        r, e = box.execute([[SELECT JSON_ID()]])
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1]), text)
    end, {decoded(NON_NORMALIZED[1].raw), decoded(NON_NORMALIZED[1].norm),
          NON_NORMALIZED[1].text})
end

-- Row: a field default, which arrives from a DDL statement. A default is
-- carried in the _space tuple, whose write is itself a validate boundary, so
-- tuple_format_create() only asserts on it as it copies the default into the
-- format. A non-normalized default is therefore rejected at CREATE by the
-- encoder; a normal one is stored and applied verbatim.
g.test_perimeter_field_default = function()
    g.server:exec(function(mk_bad, mk_good, norm)
        local mp = require('msgpack')
        t.assert_error_msg_contains('not in normal form', function()
            box.schema.space.create('T', {format = {
                {name = 'id', type = 'unsigned'},
                {name = 'j', type = 'json',
                 default = loadstring('return ' .. mk_bad)()}}})
        end)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json',
             default = loadstring('return ' .. mk_good)()}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:insert({1})
        t.assert_str_contains(mp.encode(s:get(1)), norm, false,
                              'field default')
        s:drop()
    end, {forged(NON_NORMALIZED[1].raw), forged(NON_NORMALIZED[1].norm),
          NON_NORMALIZED[1].norm})
end

-- Row: a value nested inside a container column, which no format describes.
-- Depth does not hide it: the encoder walks the whole Lua value, so a forged
-- cdata buried in a MAP is refused exactly as a top-level one is.
g.test_perimeter_container_subscript = function()
    g.server:exec(function(mk_bad, mk_good, norm)
        local mp = require('msgpack')
        -- Through SQL, so the column name resolves in the SELECT below.
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP)]])
        t.assert_error_msg_contains('not in normal form', function()
            box.space.T:insert({1, {k = loadstring('return ' .. mk_bad)()}})
        end)
        box.space.T:insert({1, {k = loadstring('return ' .. mk_good)()}})
        t.assert_str_contains(mp.encode(box.space.T:get(1)), norm, false,
                              'nested in a MAP column')
        local r, e = box.execute([[SELECT m['k'] FROM t]])
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1]), '{"a": 2, "b": 1}')
        box.execute([[DROP TABLE t]])
    end, {forged(NON_NORMALIZED[1].raw), forged(NON_NORMALIZED[1].norm),
          NON_NORMALIZED[1].norm})
end

-- A container bound to an SQL statement over iproto. The bind is part of the
-- request body, so the check at the network walks the whole thing and refuses
-- badly spelled JSON inside it, even though the bind's own type is MAP or
-- ARRAY. That one walk is why the bind decoder does not check again.
g.test_perimeter_sql_bind_container = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP)]])
    end)
    local function execute_body(sql, bind)
        return '\x82' .. IPROTO_SQL_TEXT .. msgpack.encode(sql) ..
               IPROTO_SQL_BIND .. bind
    end
    for _, case in ipairs(NON_NORMALIZED) do
        -- [ {":m": {"k": <json>} } ]
        local bad_map = '\x91\x81' .. msgpack.encode(':m') ..
                        '\x81\xa1k' .. envelope(case.raw)
        -- [ {":a": [ <json> ] } ]
        local bad_arr = '\x91\x81' .. msgpack.encode(':a') ..
                        '\x91' .. envelope(case.raw)
        t.assert_str_contains(
            raw_request(IPROTO_EXECUTE,
                        execute_body('SELECT :m', bad_map)) or '',
            'not in normal form', 'bound MAP: ' .. case.what)
        t.assert_str_contains(
            raw_request(IPROTO_EXECUTE,
                        execute_body('SELECT :a', bad_arr)) or '',
            'not in normal form', 'bound ARRAY: ' .. case.what)
        -- The normal spelling binds and selects.
        local good_map = '\x91\x81' .. msgpack.encode(':m') ..
                         '\x81\xa1k' .. envelope(case.norm)
        t.assert_equals(raw_request(IPROTO_EXECUTE,
                                    execute_body('SELECT :m', good_map)), nil,
                        'bound MAP accepted: ' .. case.what)
    end
    g.server:exec(function()
        box.execute([[DROP TABLE t]])
    end)
end

-- The same container bound from Lua, which is a different decoder: it copies
-- an msgpack object in as it is rather than encoding a Lua value. Both routes
-- are covered here: a hand-built cdata inside the bound table, which the
-- encoder catches, and an msgpack object copied past the encoder, which the
-- bind decoder catches.
g.test_perimeter_sql_bind_container_lua = function()
    g.server:exec(function(bads, mk_good, norm)
        local mp = require('msgpack')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP)]])
        --- box.execute() reports rather than raises, unlike conn:execute().
        local function exec_err(sql, params)
            local r, e = box.execute(sql, params)
            t.assert_equals(r, nil)
            return tostring(e)
        end
        -- Every non-normalized shape is refused, in a MAP and in an ARRAY,
        -- and is named as non-normalized rather than as malformed.
        for i, mk in ipairs(bads) do
            local raw = loadstring('return ' .. mk)()
            t.assert_str_contains(exec_err([[SELECT :m]],
                                           {{[':m'] = {k = raw}}}),
                                  'not in normal form',
                                  'bound MAP: ' .. i)
            t.assert_str_contains(exec_err([[SELECT :a]], {{[':a'] = {raw}}}),
                                  'not in normal form',
                                  'bound ARRAY: ' .. i)
        end
        -- Malformed bytes are refused too, under the other message. They can
        -- only be forged now: decode would have caught them.
        local ffi = require('ffi')
        local bad = ffi.new('struct mp_json', 4)
        ffi.copy(bad, '\x82\xa1a', 4)
        t.assert_str_contains(exec_err([[SELECT :m]], {{[':m'] = {k = bad}}}),
                              'Invalid JSON value')
        -- The normal spelling binds, selects and stores.
        local good = loadstring('return ' .. mk_good)()
        local r, e = box.execute([[SELECT :m]], {{[':m'] = {k = good}}})
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1].k), '{"a": 2, "b": 1}')
        box.execute([[INSERT INTO t VALUES (1, :m)]], {{[':m'] = {k = good}}})
        t.assert_str_contains(mp.encode(box.space.T:get(1)), norm, false,
                              'stored from a MAP bound in Lua')
        -- The subject is the MP_JSON payloads, not the container holding
        -- them: a plain map that is merely unsorted, with no JSON in it, is
        -- stored exactly as it was spelled.
        local plain = mp.object_from_raw('\x82\xa1b\x01\xa1a\x02')
        box.execute([[INSERT INTO t VALUES (2, :m)]], {{[':m'] = {k = plain}}})
        t.assert_str_contains(mp.encode(box.space.T:get(2)),
                              '\x82\xa1b\x01\xa1a\x02', false,
                              'a container of its own is never normalized')
        box.execute([[DROP TABLE t]])
    end, {(function()
        local mks = {}
        for _, case in ipairs(NON_NORMALIZED) do
            table.insert(mks, forged(case.raw))
        end
        return mks
    end)(), forged(NON_NORMALIZED[1].norm), NON_NORMALIZED[1].norm})
end

-- Row: a stored function returning a container, which the SQL type system
-- names MAP and never looks inside.
g.test_perimeter_stored_function_container = function()
    g.server:exec(function(mk_bad, mk_good, text)
        local function define(mk)
            pcall(box.schema.func.drop, 'JSON_MAP')
            box.schema.func.create('JSON_MAP', {
                language = 'LUA',
                param_list = {},
                returns = 'map',
                body = 'function() return {k = ' .. mk .. '} end',
                exports = {'SQL'},
                is_deterministic = true})
        end
        define(mk_bad)
        local r, e = box.execute([[SELECT JSON_MAP()]])
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), 'not in normal form')
        define(mk_good)
        r, e = box.execute([[SELECT JSON_MAP()]])
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1].k), text)
    end, {forged(NON_NORMALIZED[1].raw), forged(NON_NORMALIZED[1].norm),
          NON_NORMALIZED[1].text})
end

-- A container carries no promise about what it holds, so an invalid JSON
-- inside one is rejected wherever it enters.
g.test_perimeter_container_rejects_invalid_json = function()
    -- MP_FLOAT is not a JSON number kind, so this envelope is not JSON.
    local inner = '\xca\x3f\x80\x00\x00'
    -- Over iproto the network boundary catches it as invalid MessagePack.
    local body = '\x82' .. IPROTO_SQL_TEXT .. msgpack.encode('SELECT :a') ..
                 IPROTO_SQL_BIND ..
                 '\x91\x81' .. msgpack.encode(':a') ..
                 '\x91' .. envelope(inner)
    t.assert_str_contains(raw_request(IPROTO_EXECUTE, body) or '',
                          'Invalid MsgPack')
    g.server:exec(function()
        -- And in process, where it can only be forged.
        local ffi = require('ffi')
        local j = ffi.new('struct mp_json', 5)
        ffi.copy(j, '\xca\x3f\x80\x00\x00', 5)
        local r, e = box.execute([[SELECT :a]], {{[':a'] = {k = j}}})
        t.assert_equals(r, nil)
        t.assert_str_contains(tostring(e), 'Invalid JSON value')
    end)
end

-- The shape of a Raft DML apply. Picodata's apply comes down to space:insert
-- and space:replace, so it meets the same check a client does and gets no
-- shortcut of its own.
g.test_perimeter_raft_dml_apply_shape = function()
    g.server:exec(function(mk_bad, mk_good, norm)
        local mp = require('msgpack')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        local bad = loadstring('return ' .. mk_bad)()
        local good = loadstring('return ' .. mk_good)()
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, bad})
        end)
        t.assert_error_msg_contains('not in normal form', function()
            s:replace({2, bad})
        end)
        s:insert({1, good})
        s:replace({2, good})
        t.assert_str_contains(mp.encode(s:get(1)), norm, false, 'insert')
        t.assert_str_contains(mp.encode(s:get(2)), norm, false, 'replace')
        s:drop()
    end, {forged(NON_NORMALIZED[1].raw), forged(NON_NORMALIZED[1].norm),
          NON_NORMALIZED[1].norm})
end

-- Row: the C DML entry points. There is exactly one set of them, and every one
-- requires normal form of its caller. The bypassing variants
-- box_insert_as_is() and its three siblings used to exist next to them; they
-- were an unguarded way in, reachable from plain Lua through ffi.C, so they
-- are gone. Their absence is what makes "there is one way in" true of them.
g.test_perimeter_no_as_is_dml_entry_points = function()
    g.server:exec(function()
        local ffi = require('ffi')
        for _, name in ipairs({'box_insert_as_is', 'box_replace_as_is',
                               'box_update_as_is', 'box_upsert_as_is'}) do
            local ok, err = pcall(function() return ffi.C[name] end)
            t.assert_equals(ok, false, name .. ' must not resolve')
            t.assert_str_contains(tostring(err), name, false,
                                  'the error names the missing symbol')
        end
    end)
end

-- A key handed to the comparator through the key_def API, the one way a JSON
-- value reaches a comparison without having been a tuple field first. Nothing
-- checks it here, because the key goes through luaT_tuple_encode() and there
-- are only three places it can have come from, each checked somewhere else.
-- The failing case below shows the first of them being refused by the Lua
-- encoder, and the three passing cases are those three sources. The error
-- class is asserted as well as the message, because the message alone would
-- not say which of the two refused: they word it identically.
g.test_perimeter_key_def_compare_key = function()
    g.server:exec(function(mk_bad, mk_good, envelope_good)
        local key_def = require('key_def')
        local msgpack = require('msgpack')
        local kd = key_def.new({{fieldno = 1, type = 'json'}})
        local good = loadstring('return ' .. mk_good)()
        local tuple = box.tuple.new({good})

        -- A forged cdata in the key table never reaches the comparator: the
        -- Lua encoder refuses it while encoding the key, and says so as a
        -- LuajitError rather than as ER_JSON_NOT_NORMALIZED.
        local ok, err = pcall(kd.compare_with_key, kd, tuple,
                              {loadstring('return ' .. mk_bad)()})
        t.assert_equals(ok, false)
        t.assert_str_contains(tostring(err), 'not in normal form')
        t.assert_equals(err.type, 'LuajitError',
                        'the Lua encoder is what refuses a forged key')

        -- The three provenances a key can actually have, all comparing.
        t.assert_equals(kd:compare_with_key(tuple, {good}), 0,
                        'a cdata key the encoder emitted')
        t.assert_equals(kd:compare_with_key(
            tuple, {msgpack.object_from_raw(envelope_good)}), 0,
            'an msgpack.object key, spliced verbatim')
        t.assert_equals(kd:compare_with_key(tuple, tuple), 0,
                        'a tuple key, spliced verbatim')
    end, {forged(NON_NORMALIZED[1].raw), forged(NON_NORMALIZED[1].norm),
          envelope(NON_NORMALIZED[1].norm)})
end

-- A response off the wire. The operator picks the peer, not a client, so
-- net.box takes the JSON in a response as it is, the way the applier takes a
-- row from a cluster member: a peer running this same code checked it when it
-- first came in there. A value spelled right arrives intact and is usable
-- here, and every other spelling arrives too, byte for byte, and is not fixed
-- on the way.
g.test_perimeter_net_box_response = function()
    local netbox = require('net.box')
    --- A peer that answers every call with one fixed JSON value.
    local function serve(inner)
        return socket.tcp_server('127.0.0.1', 0, function(sock)
            local salt = require('digest').base64_encode(string.rep('\0', 32))
            sock:write(('%-63s\n%-63s\n'):format(
                'Tarantool 2.11.8 (Binary) ' ..
                '00000000-0000-0000-0000-000000000000', salt))
            while true do
                local head = sock:read(5)
                if head == nil or head == '' then return end
                local len, nxt = msgpack.decode(head)
                local rest = head:sub(nxt)
                while #rest < len do
                    local chunk = sock:read(len - #rest)
                    if chunk == nil or chunk == '' then return end
                    rest = rest .. chunk
                end
                local hdr = msgpack.decode(rest)
                local body = ''
                if hdr[0] == 0x49 then          -- IPROTO_ID
                    body = '\x82\x54\x04\x55\x90'
                elseif hdr[0] == 0x0a then      -- IPROTO_CALL
                    body = '\x81\x30\x91' .. envelope(inner)
                end
                local packet = '\x82\x00\x00\x01' ..
                               msgpack.encode(hdr[1] or 0) .. body
                sock:write(msgpack.encode(#packet) .. packet)
            end
        end)
    end

    --- Dial a peer serving @a inner and make one call against it.
    local function call(inner)
        local srv = serve(inner)
        local conn = netbox.connect('127.0.0.1:' .. srv:name().port,
                                    {fetch_schema = false,
                                     reconnect_after = 0})
        conn:wait_connected(5)
        t.assert_equals(conn.error, nil, tostring(conn.error))
        local ok, res = pcall(conn.call, conn, 'get_profile')
        conn:close()
        srv:close()
        return ok, res
    end

    local ok, got = call(NON_NORMALIZED[1].norm)
    t.assert(ok, tostring(got))
    -- The value survived the crossing, bytes for bytes, and is a JSON value
    -- on this side rather than a map or a string.
    t.assert_equals(msgpack.encode(got), envelope(NON_NORMALIZED[1].norm))
    t.assert_equals(tostring(got), NON_NORMALIZED[1].text)

    -- A value out of normal form cannot go back through msgpack.encode(),
    -- which refuses it, so read the bytes straight out of the cdata.
    local ffi = require('ffi')
    local function bytes(j)
        return ffi.string(j.data, ffi.sizeof(j))
    end
    for _, case in ipairs(NON_NORMALIZED) do
        local passed, res = call(case.raw)
        t.assert(passed, case.what .. ': ' .. tostring(res))
        t.assert_equals(bytes(res), case.raw, case.what)
    end
    for _, case in ipairs(BAD_UTF8) do
        local passed, res = call(case.raw)
        t.assert(passed, case.what .. ': ' .. tostring(res))
        t.assert_equals(bytes(res), case.raw, case.what)
    end
    ok, got = call(GOOD_UTF8.raw)
    t.assert(ok, tostring(got))
    t.assert_equals(tostring(got), GOOD_UTF8.text)
end

-- A string or key that is not UTF-8 is not JSON, because RFC 8259 requires
-- JSON text to be UTF-8. The network refuses it wherever it appears in a
-- request: a tuple, a bind, an error's field and the header.
g.test_perimeter_utf8_iproto = function()
    local space_id = g.server:exec(function()
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'j', type = 'any'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        return s.id
    end)
    local function execute_body(sql, bind)
        return '\x82' .. IPROTO_SQL_TEXT .. msgpack.encode(sql) ..
               IPROTO_SQL_BIND .. bind
    end
    local IPROTO_PING = '\x40'
    local UNKNOWN_KEY = '\xcc\xc8'
    for i, case in ipairs(BAD_UTF8) do
        local why = ': ' .. case.what
        local tuple = '\x92' .. msgpack.encode(i) .. envelope(case.raw)
        t.assert_str_contains(raw_request(IPROTO_INSERT,
                                          insert_body(space_id, tuple)) or '',
                              'invalid JSON value', false, 'tuple' .. why)
        local bind = '\x91' .. envelope(case.raw)
        t.assert_str_contains(raw_request(IPROTO_EXECUTE,
                                          execute_body('SELECT ?', bind))
                              or '', 'invalid JSON value', false,
                              'bind' .. why)
        local err = '\x92' .. msgpack.encode(i) .. error_with_json(case.raw)
        t.assert_str_contains(raw_request(IPROTO_INSERT,
                                          insert_body(space_id, err)) or '',
                              'invalid JSON value', false, 'error' .. why)
        t.assert_str_contains(raw_request(IPROTO_PING, '',
                                          UNKNOWN_KEY .. envelope(case.raw))
                              or '', 'invalid JSON value', false,
                              'header' .. why)
    end
    local tuple = '\x92\x01' .. envelope(GOOD_UTF8.raw)
    t.assert_equals(raw_request(IPROTO_INSERT, insert_body(space_id, tuple)),
                    nil)
    g.server:exec(function(text)
        t.assert_equals(tostring(box.space.T:get(1)[2]), text)
    end, {GOOD_UTF8.text})
end

-- The same from Lua: both decode entry points refuse the bytes, and a cdata
-- forged around them gets no further than either encoder or a write.
g.test_perimeter_utf8_lua = function()
    local cases = {}
    for i, case in ipairs(BAD_UTF8) do
        cases[i] = {raw = case.raw, env = envelope(case.raw), what = case.what}
    end
    g.server:exec(function(cases, good, good_env)
        local ffi = require('ffi')
        local mp = require('msgpack')
        local mpffi = require('msgpackffi')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'}, {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        for i, case in ipairs(cases) do
            local j = ffi.new('struct mp_json', #case.raw)
            ffi.copy(j, case.raw, #case.raw)
            for what, f in pairs({
                decode = function() return mp.decode(case.env) end,
                object_from_raw = function()
                    return mp.object_from_raw(case.env)
                end,
                msgpack = function() return mp.encode(j) end,
                msgpackffi = function() return mpffi.encode(j) end,
                insert = function() return s:insert({i, j}) end,
            }) do
                local ok, err = pcall(f)
                t.assert_not(ok, what .. ': ' .. case.what)
                t.assert_str_contains(tostring(err):lower(),
                                      'invalid json value', false,
                                      what .. ': ' .. case.what)
            end
        end
        t.assert_equals(s:count(), 0)
        local j = mp.decode(good_env)
        t.assert_equals(tostring(j), good.text)
        s:insert({1, j})
        t.assert_equals(tostring(s:get(1)[2]), good.text)
        s:drop()
    end, {cases, GOOD_UTF8, envelope(GOOD_UTF8.raw)})
end

-- SQL builds JSON two ways, from text and from a MAP or ARRAY, and both
-- refuse a string that is not UTF-8.
g.test_perimeter_utf8_sql = function()
    g.server:exec(function(good)
        for _, text in ipairs({'"\xff"', '{"\xff": 1}', '["a", "\xc3"]',
                               '"\xed\xa0\x80"'}) do
            for _, sql in ipairs({[[SELECT CAST(? AS JSON)]],
                                  [[SELECT JSON_PARSE(?)]]}) do
                local r, err = box.execute(sql, {text})
                t.assert_equals(r, nil, sql)
                t.assert_str_contains(tostring(err),
                                      'invalid UTF-8 in string', false, sql)
            end
        end
        local cast = [[SELECT CAST(:m AS JSON)]]
        for _, v in ipairs({{k = '\xff'}, {['\xff'] = 1}, {'a', '\xc3'}}) do
            local r, err = box.execute(cast, {{[':m'] = v}})
            t.assert_equals(r, nil)
            t.assert_str_contains(tostring(err), 'is not a valid json')
        end
        local r = box.execute([[SELECT CAST(? AS JSON)]], {good.text})
        t.assert_equals(tostring(r.rows[1][1]), good.text)
        r = box.execute(cast, {{[':m'] = {k = '\xc3\xa9'}}})
        t.assert_equals(tostring(r.rows[1][1]), '{"k": "\xc3\xa9"}')
    end, {GOOD_UTF8})
end

-- Tuples made from bytes nothing has checked yet, as merger and the xlog
-- reader make them, refuse it too.
g.test_perimeter_utf8_merger = function()
    local bad = {}
    for i, case in ipairs(BAD_UTF8) do
        bad[i] = envelope(case.raw)
    end
    g.server:exec(function(bad, good, text)
        local buffer = require('buffer')
        local ffi = require('ffi')
        local merger = require('merger')
        local function fetch(field)
            local raw = '\x91\x91' .. field
            local buf = buffer.ibuf()
            ffi.copy(buf:alloc(#raw), raw, #raw)
            return merger.new_source_frombuffer(buf):select()
        end
        for _, field in ipairs(bad) do
            t.assert_error_msg_contains('invalid JSON value in field [1]',
                                        fetch, field)
        end
        t.assert_equals(tostring(fetch(good)[1][1]), text)
    end, {bad, envelope(GOOD_UTF8.raw), GOOD_UTF8.text})
end

--------------------------------------------------------------------------------
-- json_properties
--------------------------------------------------------------------------------

local g = t.group('json_properties')

g.before_all(function(cg)
    cg.server = json_server
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.T ~= nil then
            box.space.T:drop()
        end
    end)
end)

-- A malformed JSON value nested inside an array field is rejected at the box C
-- API boundary, which walks the whole tuple, so depth does not hide it. The
-- boundary validates without a format, so it names the failure as invalid
-- MessagePack rather than naming the field it sits in.
g.test_malformed_nested_value_is_rejected = function(cg)
    cg.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        -- ext8 len 1 subtype 20, inner = a lone str32 marker: malformed.
        -- The decode check refuses to build anything out of it at all.
        t.assert_error_msg_contains('Invalid JSON value', function()
            return msgpack.object_from_raw('\xc7\x01\x14\xdb')
        end)
        -- Forged past that check and buried in a container, which no format
        -- describes, it is still refused on the way to storage.
        local bad = ffi.new('struct mp_json', 1)
        ffi.copy(bad, '\xdb', 1)
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'a', type = 'array'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        local ok, err = pcall(s.insert, s, {1, {'ok', bad}})
        t.assert_not(ok)
        t.assert_str_contains(tostring(err), 'Invalid JSON value')
        t.assert_equals(s:count(), 0)
    end)
end

-- A malformed payload survives being logged.
-- A malformed subtype-20 payload is no longer refused at row decode, so it gets
-- as far as the check, is refused there, and is then printed by the error
-- handler: request_str() calls mp_snprint() on request->tuple. A replication
-- peer or a corrupt xlog can put us on that path, which is why the renderer is
-- bounded by both depth and input length. This test actually drives it rather
-- than just asserting the insert failed.
--
g.test_malformed_json_is_logged_without_a_crash = function(cg)
    cg.server:exec(function()
        local msgpack = require('msgpack')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        local ffi = require('ffi')
        for _, inner in ipairs({
            -- A truncated string header: the overread case.
            '\xdb',
            -- A fixstr claiming 31 bytes with one present.
            '\xbfa',
            -- 200 nested arrays: past any depth the print hook passes down.
            string.rep('\x91', 200) .. '\xc0',
        }) do
            -- The decode check refuses to wrap them at all.
            local envelope = '\xc7' .. string.char(#inner) .. '\x14' .. inner
            t.assert_error(function()
                return msgpack.object_from_raw(envelope)
            end)
            -- Forged past it, the write refuses them, and the rejection
            -- handler renders them on the way to the log.
            local j = ffi.new('struct mp_json', #inner)
            ffi.copy(j, inner, #inner)
            t.assert_error(function() s:insert({1, j}) end)
            -- And through the renderer directly, which is what that handler
            -- reaches: a JSON cdata's __tostring is mp_snprint_json().
            t.assert_error(function() return tostring(j) end)
        end
        t.assert_equals(s:count(), 0)
    end)
    -- The server is still up and serving after all of that.
    t.assert_equals(cg.server:exec(function() return box.info.status end),
                    'running')
end

--------------------------------------------------------------------------------
-- json_replication
--------------------------------------------------------------------------------

local g = t.group('json_replication')

g.before_all(function(cg)
    cg.replica_set = replica_set:new({})
    cg.master = cg.replica_set:build_and_add_server({alias = 'master'})
    cg.replica = cg.replica_set:build_and_add_server({
        alias = 'replica',
        box_cfg = {
            replication = server.build_listen_uri('master',
                                                  cg.replica_set.id),
            read_only = true,
        },
    })
    cg.replica_set:start()
end)

g.after_all(function(cg)
    cg.replica_set:drop()
end)

g.after_each(function(cg)
    cg.master:exec(function()
        if box.space.T ~= nil then
            box.space.T:drop()
        end
    end)
    cg.replica:wait_for_vclock_of(cg.master)
end)

-- A JSON value replicates byte for byte. Relay just copies bytes, so the
-- replica does no JSON check of its own, and what arrives is exactly what the
-- master stored, which the master checked when it came in.
g.test_json_replicates_byte_for_byte = function(cg)
    cg.master:exec(function()
        local msgpack = require('msgpack')
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        -- The master lets in only the right spelling, and relays it
        -- unchanged.
        s:insert({1, msgpack.object_from_raw(
            '\xc7\x07\x14\x82\xa1a\x02\xa1b\x01')})
        rawset(_G, 'stored', msgpack.encode(s:get(1)))
    end)
    local master_bytes = cg.master:exec(function()
        return rawget(_G, 'stored')
    end)
    cg.replica:wait_for_vclock_of(cg.master)
    local replica_bytes = cg.replica:exec(function()
        local msgpack = require('msgpack')
        return msgpack.encode(box.space.T:get(1))
    end)
    t.assert_equals(replica_bytes, master_bytes,
                    'the replica holds the master bytes verbatim')
    cg.replica:exec(function()
        t.assert_equals(tostring(box.space.T:get(1)[2]), '{"a": 2, "b": 1}')
    end)
end

-- The logging case of json_properties, driven through the applier, which is
-- the remote half of how it is reached: a peer relays a row whose value this
-- node refuses, and the error handler prints it into the log.
g.test_replica_survives_a_malformed_relayed_value = function(cg)
    cg.master:exec(function()
        local s = box.schema.space.create('T', {format = {
            {name = 'id', type = 'unsigned'},
            {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        -- The master lets in only values already in normal form, so what it
        -- relays is fine and applies cleanly on the replica.
        -- This is the positive half of section 7.1.
        local msgpack = require('msgpack')
        s:insert({1, msgpack.object_from_raw(
            '\xc7\x07\x14\x82\xa1a\x02\xa1b\x01')})
    end)
    cg.replica:wait_for_vclock_of(cg.master)
    cg.replica:exec(function()
        t.assert_equals(tostring(box.space.T:get(1)[2]), '{"a": 2, "b": 1}')
        t.assert_equals(box.info.status, 'running')
    end)
    -- The replica logged nothing about a refused value, because there was
    -- none to refuse: the check that ran was the master's.
    t.assert_equals(cg.replica:grep_log('invalid JSON value'), nil)
end

--------------------------------------------------------------------------------
-- json_update_ops
--------------------------------------------------------------------------------

local g = t.group('json_update_ops', {{engine = 'memtx'}, {engine = 'vinyl'}})

g.before_all(function(cg)
    cg.server = json_server
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.T ~= nil then
            box.space.T:drop()
        end
    end)
end)

-- An operand must arrive in normal form, so an UPDATE that writes a
-- non-normalized JSON value is refused rather than repaired, and one that
-- writes the normal spelling stores those bytes verbatim.
-- One test per application site: space.c (upsert-as-insert), memtx_space.c
-- (update) and vinyl.c (both).
g.test_update_operand_must_be_normal = function(cg)
    cg.server:exec(function(engine)
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local unsorted = '\x82\xa1b\x01\xa1a\x02'
        local sorted = '\x82\xa1a\x02\xa1b\x01'
        --- Forged: no decoder hands out a non-normalized JSON cdata.
        local function mk(raw)
            local j = ffi.new('struct mp_json', #raw)
            ffi.copy(j, raw, #raw)
            return j
        end
        local bad, good = mk(unsorted), mk(sorted)
        local s = box.schema.space.create('T', {engine = engine,
            format = {{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, bad})
        end)
        s:insert({1, good})
        t.assert_error_msg_contains('not in normal form', function()
            s:update({1}, {{'=', 2, bad}})
        end)
        s:update({1}, {{'=', 2, good}})
        t.assert_str_contains(msgpack.encode(s:get(1)[2]), sorted, false,
                              'UPDATE operand stored verbatim')
        -- upsert-as-insert, then upsert on an existing row.
        t.assert_error_msg_contains('not in normal form', function()
            s:upsert({2, bad}, {{'=', 2, bad}})
        end)
        s:upsert({2, good}, {{'=', 2, good}})
        t.assert_str_contains(msgpack.encode(s:get(2)[2]), sorted, false,
                              'UPSERT-as-INSERT tuple stored verbatim')
        t.assert_error_msg_contains('not in normal form', function()
            s:upsert({2, good}, {{'=', 2, bad}})
        end)
        s:upsert({2, good}, {{'=', 2, good}})
        t.assert_str_contains(msgpack.encode(s:get(2)[2]), sorted, false,
                              'UPSERT operand stored verbatim')
    end, {cg.params.engine})
end

-- A malformed JSON operand is rejected at the request, not at apply time,
-- and the diag names where.
g.test_malformed_operand_is_rejected = function(cg)
    cg.server:exec(function(engine)
        local ffi = require('ffi')
        -- MP_BIN inside a JSON payload: a disallowed kind.
        local bad = '\x81\xa1a\xc4\x01\x00'
        local j = ffi.new('struct mp_json', #bad)
        ffi.copy(j, bad, #bad)
        local s = box.schema.space.create('T', {engine = engine,
            format = {{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        local good = ffi.new('struct mp_json', 4) -- {"a":1}
        ffi.copy(good, '\x81\xa1\x61\x01', 4)
        s:insert({1, good})
        t.assert_error_msg_contains('JSON',
            function() s:update({1}, {{'=', 2, j}}) end)
    end, {cg.params.engine})
end

-- No update operation transforms the bytes of an MP_JSON value. Arithmetic
-- requires a number and splice requires a string, and both reject an MP_EXT
-- operand. If a future operation gains the ability to edit a JSON value in
-- place, this test is what fails, and the UPDATE result is what stops being
-- trusted.
g.test_no_operation_rewrites_a_json_payload = function(cg)
    cg.server:exec(function(engine)
        local ffi = require('ffi')
        local raw = '\x81\xa1a\x01' -- {"a":1}
        local j = ffi.new('struct mp_json', #raw)
        ffi.copy(j, raw, #raw)
        local s = box.schema.space.create('T', {engine = engine,
            format = {{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:insert({1, j})
        t.assert_error(function() s:update({1}, {{'+', 2, 1}}) end)
        t.assert_error(function() s:update({1}, {{':', 2, 1, 1, 'x'}}) end)
    end, {cg.params.engine})
end

-- The vinyl squash runs in a dump or compaction task, on a worker thread
-- where tuple_new_checked's fiber and diag are unavailable. The operands were
-- checked at the request instead, so the squash needs none of its own and must
-- carry their bytes through untouched. Two
-- upserts with no intervening read stay unapplied, so a dump and a compaction
-- squash them there rather than on the tx thread.
g.test_upsert_squash_in_a_worker_thread = function(cg)
    t.skip_if(cg.params.engine ~= 'vinyl', 'vinyl only')
    cg.server:exec(function()
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        local sorted = '\x82\xa1a\x02\xa1b\x01'
        local j = ffi.new('struct mp_json', #sorted)
        ffi.copy(j, sorted, #sorted)
        local s = box.schema.space.create('T', {engine = 'vinyl',
            format = {{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        s:insert({1, j})
        box.snapshot()
        -- No read between them, so both stay unapplied in the memory level.
        s:upsert({1, j}, {{'=', 2, j}})
        s:upsert({1, j}, {{'=', 2, j}})
        box.snapshot()
        s.index.pk:compact()
        t.helpers.retrying({timeout = 10}, function()
            t.assert_equals(s.index.pk:stat().run_count, 1)
        end)
        t.assert_str_contains(msgpack.encode(s:get(1)[2]), sorted, false,
                              'squashed upsert kept its bytes')
    end)
end

-- The check does not depend on the engine: a badly spelled value is refused on
-- insert into a vinyl space just as into a memtx one, and only the right
-- spelling gets stored.
g.test_json_insert_is_normalized_per_engine = function(cg)
    cg.server:exec(function(engine)
        local ffi = require('ffi')
        local msgpack = require('msgpack')
        -- {"a":1} with a str8 header on a one-byte key, and the same document
        -- already in normal form. The wide one has to be forged: the decode
        -- decoder would not hand out a non-normalized value.
        local wide = ffi.new('struct mp_json', 5)
        ffi.copy(wide, '\x81\xd9\x01a\x01', 5)
        local narrow = msgpack.object_from_raw('\xd6\x14\x81\xa1a\x01')
        local s = box.schema.space.create('T', {engine = engine,
            format = {{name = 'id', type = 'unsigned'},
                      {name = 'j', type = 'json'}}})
        s:create_index('pk', {parts = {1, 'unsigned'}})
        t.assert_error_msg_contains('not in normal form', function()
            s:insert({1, wide})
        end)
        s:insert({2, narrow})
        t.assert_equals(tostring(s:get(2)[2]), '{"a": 1}',
                        'INSERT of the normal spelling on ' .. engine)
    end, {cg.params.engine})
end

--------------------------------------------------------------------------------
-- json_c_function
--------------------------------------------------------------------------------

local g = t.group('json_c_function')

local FUNCS = {'ret_json_sorted', 'ret_map_json_sorted'}

g.before_all(function()
    g.server = json_server
    g.server:exec(function(funcs)
        local build_path = os.getenv("BUILDDIR")
        package.cpath = build_path..'/test/sql-luatest/?.so;'..
                        build_path..'/test/sql-luatest/?.dylib;'..
                        package.cpath
        local opts = {language = 'C', returns = 'any', exports = {'SQL'}}
        for _, name in ipairs(funcs) do
            box.schema.func.create('sql_json.' .. name, opts)
        end
    end, {FUNCS})
end)

g.after_all(function()
    g.server:exec(function(funcs)
        for _, name in ipairs(funcs) do
            box.schema.func.drop('sql_json.' .. name, {if_exists = true})
        end
    end, {FUNCS})
end)

-- A C stored function vouches for any JSON it returns, as for box_insert():
-- port_c_get_vdbemem() takes it as it is and only a debug build asserts. So
-- all this can check is that a normal value comes through both of its JSON
-- branches: the MP_EXT branch for a value returned as JSON, and the MAP/ARRAY
-- branch for one inside a container.
g.test_json_c_function_return_takes_json_as_is = function()
    g.server:exec(function()
        local r, e = box.execute([[SELECT "sql_json.ret_json_sorted"()]])
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1]), '{"a": 2, "b": 1}')
    end)
end

g.test_json_c_function_container_takes_json_as_is = function()
    g.server:exec(function()
        local r, e = box.execute([[SELECT "sql_json.ret_map_json_sorted"()]])
        t.assert_equals(e, nil)
        t.assert_equals(tostring(r.rows[1][1].k), '{"a": 2, "b": 1}')
    end)
end
