-- PostgreSQL-incompatible datetime tests.

local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'datetime'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

-- Make sure that explicit cast to DATETIME works as intended.
g.test_datetime_18_3 = function()
    g.server:exec(function()
        local dt = require('datetime')
        local dt1 = dt.new(
            {year = 2001, month = 1, day = 1, hour = 1, tz = 'Z'})
        local sql = [[SELECT CAST('2001-01-01T01:00:00Z' AS DATETIME);]]
        local res = {{dt1}}
        local rows = box.execute(sql).rows
        t.assert_equals(rows, res)
    end)
end

-- Make sure cast from STRING to DATETIME works as intended.
g.test_datetime_32_1 = function()
    g.server:exec(function()
        local dt = require('datetime')
        local dt1 = dt.new(
            {year = 2000, month = 2, day = 29, hour = 1, tz = 'Z'})
        local sql = [[SELECT CAST('2000-02-29T01:00:00Z' AS DATETIME);]]
        local res = {{dt1}}
        local rows = box.execute(sql).rows
        t.assert_equals(rows, res)
    end)
end
