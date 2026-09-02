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
        -- {"b":1,"a":2} unsorted, and {"a":2,"b":1} already sorted: one
        -- document, two spellings.
        s:insert({1, msgpack.object_from_raw(
            '\xc7\x07\x14\x82\xa1b\x01\xa1a\x02')})
        s:insert({2, msgpack.object_from_raw(
            '\xc7\x07\x14\x82\xa1a\x02\xa1b\x01')})
        -- Equal after normalization, so equality holds in SQL too.
        local res = box.execute(
            [[SELECT count(*) FROM t t1, t t2
              WHERE t1.id < t2.id AND t1.data = t2.data]])
        t.assert_equals(res.rows[1][1], 1, 'two spellings compare equal')
        -- And the stored bytes are the same, which is what makes that true.
        t.assert_equals(msgpack.encode(s:get(1)[2]),
                        msgpack.encode(s:get(2)[2]))
        -- A non-minimal integer encoding sorts by its value, not its width.
        s:insert({3, msgpack.object_from_raw('\xd5\x14\xcc\x05')}) -- uint8 5
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
