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
        box.execute([[INSERT INTO t VALUES (1, {'b': 2, 'a': 1})]])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(res.metadata[1].type, 'json')
        -- Keys are normalized (sorted); tostring gives canonical JSON text.
        t.assert_equals(tostring(res.rows[1][1]), '{"a": 1, "b": 2}')
    end)
end

g.test_json_store_array_literal = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, [3, 1, 2])]])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(res.rows[1][1]), '[3, 1, 2]')
    end)
end

g.test_json_store_nested = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, {'users': [{'name': 'Bob'}]})]])
        local res = box.execute([[SELECT data FROM t WHERE id = 1]])
        t.assert_equals(tostring(res.rows[1][1]),
                        '{"users": [{"name": "Bob"}]}')
    end)
end

g.test_json_typeof = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, {'a': 1})]])
        local res = box.execute([[SELECT TYPEOF(data) FROM t WHERE id = 1]])
        t.assert_equals(res.rows[1][1], 'json')
    end)
end

--
-- Reject non-JSON ext types and non-string keys on insert.
--
g.test_json_reject_non_json_types = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])

        local uuid = '11111111-1111-1111-1111-111111111111'
        local res, err = box.execute(
            "INSERT INTO t VALUES (1, CAST('" .. uuid .. "' AS UUID))")
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'Type mismatch')

        res, err = box.execute(
            [[INSERT INTO t VALUES (2, CAST('2026-01-01' AS DATETIME))]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'Type mismatch')

        res, err = box.execute([[INSERT INTO t VALUES (3, x'DEADBEEF')]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'Type mismatch')
    end)
end

g.test_json_reject_integer_key = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        local res, err = box.execute([[INSERT INTO t VALUES (1, {1: 'x'})]])
        t.assert_equals(res, nil)
        t.assert_str_contains(err.message, 'json')
    end)
end

--
-- QUOTE renders a JSON value as canonical JSON text (the same way it renders
-- MAP/ARRAY) instead of asserting on a non-null JSON value (debug) or returning
-- the literal string 'NULL' (release).
--

--
-- A bind is outside the cluster's parse boundary either way, so
-- sql_bind_decode() normalizes it rather than leaning on the request-level
-- mp_check(), which no longer looks inside an MP_JSON.
--
-- The value goes over iproto as a msgpack object, so no client-side
-- serializer normalizes it on the way out: the local Lua bind path refuses a
-- msgpack object as USERDATA and never reaches sql_bind_decode().
--

--
-- A JSON field default arrives from DDL, which is outside the cluster, so it
-- is normalized before it is stored. Two spellings of one document must give
-- one stored default.
--

--
-- A nested MP_JSON inside a plain MAP column is normalized on the way in, so
-- ORDER BY over a subscript returns JSONB order and the read path does no
-- work. The assertion is about the STORED bytes: a read-side repair
-- would also produce sorted output here, and would be wrong.
--

--
-- Normalization shrinks the value, so the field map must be built from the
-- normalized bytes. Building it first leaves every later offset stale, which
-- shows up as a wrong secondary lookup rather than as a wrong JSON value.
--

--
-- Position independence: the walk reads nothing from the format, so a value
-- is normalized wherever it sits, described or not, at any depth.
--
-- Each case asserts the STORED bytes. Encoding a whole tuple copies its data
-- verbatim, so msgpack.encode(tuple) is what storage holds; encoding an
-- extracted field would re-normalize on the way out and pass either way. The
-- value goes in through msgpack.object_from_raw, so no Lua serializer touches
-- it on the way in either. The spelling {"b":1,"a":2} normalizes by
-- reordering.
--

--- Raw MP_EXT/MP_JSON for {"b":1,"a":2}, keys unsorted.
local RAW_UNSORTED = [[require('msgpack').object_from_raw(
    '\xc7\x07\x14\x82\xa1b\x01\xa1a\x02')]]
--- The inner bytes the same document must be stored as.
local SORTED_INNER = '\x82\xa1a\x02\xa1b\x01'

--
-- A malformed subtype-20 payload is now rejected by the perimeter rather than
-- by row decode. The check hook no longer looks inside an MP_JSON, so
-- msgpack.object_from_raw() accepts these bytes and the tuple constructor is
-- what refuses them, naming the field they sit in.
--

--
-- A JSON index part is rejected on both engines, by the same check that
-- rejects ANY, ARRAY and MAP.
--
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

--
-- JSON survives a restart byte for byte, on both engines.
-- Recovery performs no JSON walk of its own, so what comes back is what was
-- written; the vinyl half is what would catch a diag or region touch on the
-- reader-thread path.
--

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
            [[INSERT INTO t VALUES (1, %s)]], value_sql))
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
        box.execute([[INSERT INTO t VALUES (3, {'a': 1})]])

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
        box.execute([[INSERT INTO t VALUES (1, {'b': 2, 'a': 1})]])
        local tuple = box.space.T:get(1)
        t.assert_equals(tostring(tuple[2]), '{"a": 1, "b": 2}')
        box.execute([[DROP TABLE t]])
    end)
end

-- Read a JSON value as a cdata and write it back: round-trips intact.
g.test_json_roundtrip = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, {'b': 2, 'a': 1})]])
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
        box.execute([[INSERT INTO t2 VALUES (1, {'x': 5})]])
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
        box.execute([[INSERT INTO t3 VALUES (1, {'b': 2, 'a': 1})]])
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

--
-- Box-boundary validation: a hand-built, un-normalized MP_EXT/MP_JSON value is
-- rejected on write (subtype-triggered, so it also covers ANY columns).
--

--
-- A bad JSON value nested inside an array/map field is rejected too: box
-- validation descends containers rather than only checking the field's top
-- type, or a later read/compare walks the value out of bounds.
--

--
-- A JSON value passed to a Lua function called from SQL keeps its tag: it
-- arrives as the cdata rather than a plain table, and a JSON null stays a
-- present cdata rather than collapsing to SQL NULL.
--
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
        box.execute([[INSERT INTO tf VALUES (1, {'a': 1})]])
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

--
-- The inner value of an MP_EXT/MP_JSON is validated, or a crafted subtype-20
-- value reaches a cdata that a later tostring()/compare walks out of bounds.
-- These bytes are crafted directly because no SQL path produces them.
--

--
-- The msgpackffi decoder is pure Lua and never runs mp_check, so the
-- MP_EXT/MP_JSON branch must validate the inner value itself. Without that an
-- attacker-supplied subtype-20 value decodes into a JSON cdata over malformed
-- or un-normalized bytes that a later tostring()/compare walks out of bounds.
--

--
-- A JSON value may not contain a nested JSON value: subtype-20 inside
-- subtype-20 would recurse until the fiber stack is exhausted, so it is
-- rejected at the first nested level. No SQL path produces such bytes.
--

--
-- A JSON cdata forged via FFI holds arbitrary bytes, so tostring() must
-- validate before walking them or a malformed payload reads past the cdata
-- instead of raising a Lua error. No SQL path produces one, so forge it.
--

--
-- A JSON value renders through every Lua serializer instead of aborting
-- (yaml/lua) or producing malformed output (json). The yaml encoder is the
-- console's default, so this is the very first thing a user hits.
--
g.test_json_lua_serializers = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, data JSON)]])
        box.execute([[INSERT INTO t VALUES (1, {'b': 2, 'a': 1})]])
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

--
-- The same forged cdata reaching a serializer rather than tostring(). Every
-- Lua serializer funnels through luaL_tofield(), so validation lives there;
-- this covers each of them so a new one cannot quietly reopen the hole.
--

--
-- A JSON cdata bound through the Lua path is validated: a malformed inner
-- value is rejected instead of entering the statement. luaL_tofield() is what
-- reports here; execute.c's own check guards the fields that do not come
-- through the Lua serializer.
--

--
-- A bad JSON value in a tuple field beyond the space format is rejected too:
-- box validation now checks trailing fields, not only those the format
-- describes (field 2 here is not in the format).
--

--
-- A Lua function called from SQL can return a JSON value: the return path
-- (port_lua_get_vdbemem) wraps and validates it instead of raising
-- "Unsupported type passed from Lua".
--

--
-- A bad JSON value at an undescribed position nested inside a described
-- container is rejected. A JSON-path index (data.a) makes the format deep, so
-- box validation walks the tuple with the format iterator, where a sibling key
-- not in the format was previously skipped without validation.
--

--
-- The same validation covers a map with a non-string key nested in a described
-- container: that key/value pair takes a separate skip branch in the iterator
-- (entry->field = NULL for a non-string key) and was likewise stored without
-- JSON validation.
--

--
-- A forged cdata cannot produce a bad stored value. The worst it achieves is
-- holding bytes that are normalized on the way out of Lua, so encode, decode
-- and tostring all agree on the normalized value.
--
