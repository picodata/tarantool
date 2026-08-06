local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'bind'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_bind_1 = function()
    g.server:exec(function()
        local sql = [[SELECT @1asd;]]
        local res = "At line 1 at or near position 9: unrecognized token '1asd'"
        local _, err = box.execute(sql, {{['@1asd'] = 123}})
        t.assert_equals(err.message, res)
    end)
end

g.test_bind_2 = function()
    local conn = g.server.net_box
    local sql = [[SELECT @1asd;]]
    local res = [[At line 1 at or near position 9: unrecognized token '1asd']]
    local _, err = pcall(conn.execute, conn, sql, {{['@1asd'] = 123}})
    t.assert_equals(err.message, res)
end

-- An empty string has no bytes to copy onto the region, and a zero-size
-- region_alloc() asserts in a debug build.
g.test_bind_empty_string = function()
    g.server:exec(function()
        local res = box.execute([[SELECT ?]], {''})
        t.assert_equals(res.rows, {{''}})
    end)
end

-- The same value over iproto, which decodes binds from MessagePack instead
-- and has always accepted it.
g.test_bind_empty_string_iproto = function()
    local conn = g.server.net_box
    t.assert_equals(conn:execute([[SELECT ?]], {''}).rows, {{''}})
end

-- An empty string still round-trips through a TEXT column.
g.test_bind_empty_string_insert = function()
    g.server:exec(function()
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, s TEXT)]])
        box.execute([[INSERT INTO t VALUES (1, ?)]], {''})
        t.assert_equals(box.execute([[SELECT s FROM t]]).rows, {{''}})
        box.execute([[DROP TABLE t]])
    end)
end

-- A varbinary bind arrives as the payload itself, with no MessagePack header
-- to decode. Decoding one anyway reads a length out of the payload bytes, so
-- the bind ends up describing memory past the value.
g.test_bind_varbinary = function()
    g.server:exec(function()
        local varbinary = require('varbinary')
        local val = varbinary.new('\xde\xad\xbe\xef')
        local res = box.execute([[SELECT ?]], {val})
        t.assert_equals(#res.rows[1][1], 4)
        t.assert_equals(tostring(res.rows[1][1]), tostring(val))
    end)
end

-- The same value over iproto, which really does decode from MessagePack.
g.test_bind_varbinary_iproto = function()
    local varbinary = require('varbinary')
    local conn = g.server.net_box
    local val = varbinary.new('\xde\xad\xbe\xef')
    local res = conn:execute([[SELECT ?]], {val})
    t.assert_equals(#res.rows[1][1], 4)
    t.assert_equals(tostring(res.rows[1][1]), tostring(val))
end

-- An empty varbinary takes the zero-length path as well.
g.test_bind_empty_varbinary = function()
    g.server:exec(function()
        local varbinary = require('varbinary')
        local res = box.execute([[SELECT ?]], {varbinary.new('')})
        t.assert_equals(#res.rows[1][1], 0)
    end)
end

-- A varbinary bind round-trips through a VARBINARY column, embedded NUL and
-- high bytes included. SQL hands the value back to Lua as a plain string.
g.test_bind_varbinary_insert = function()
    g.server:exec(function()
        local varbinary = require('varbinary')
        local val = varbinary.new('\x00\xff\x10binary')
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, b VARBINARY)]])
        box.execute([[INSERT INTO t VALUES (1, ?)]], {val})
        local got = box.execute([[SELECT b FROM t]]).rows[1][1]
        t.assert_equals(#got, 9)
        t.assert_equals(got, tostring(val))
        box.execute([[DROP TABLE t]])
    end)
end
