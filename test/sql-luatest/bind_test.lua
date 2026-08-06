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
