-- PostgreSQL-incompatible datetime tests.

local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'datetime'})
    g.server:start()
    g.server:exec(function()
        -- Returns the error message of the expression, or nil if there
        -- is no error.
        rawset(_G, 'expr_error', function(expr)
            local _, err = box.execute('SELECT ' .. expr .. ';')
            return err ~= nil and err.message or nil
        end)
        rawset(_G, 'dt', function(text)
            return ("CAST('%s' AS DATETIME)"):format(text)
        end)
        rawset(_G, 'itv', function(map)
            return ('CAST(%s AS INTERVAL)'):format(map)
        end)
    end)
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

-- The sum or the difference of a DATETIME and an INTERVAL that is out of
-- the range of DATETIME is an error.
g.test_datetime_overflow_error = function()
    g.server:exec(function()
        local max = _G.dt('5879611-07-10T00:00:00Z')
        local min = _G.dt('-5879610-06-23T00:00:00Z')
        local message = 'Failed to execute SQL statement: datetime is ' ..
                        'overflowed'
        for _, expr in ipairs({
            max .. ' + ' .. _G.itv("{'day': 7}"),
            _G.itv("{'day': 7}") .. ' + ' .. max,
            max .. ' - ' .. _G.itv("{'day': -7}"),
            min .. ' - ' .. _G.itv("{'day': 7}"),
            min .. ' + ' .. _G.itv("{'day': -7}"),
            _G.dt('-5879610-06-22T00:00:00Z') .. ' - ' ..
            _G.itv("{'nsec': 1}"),
            _G.dt('-5879610-06-22T00:00:00Z') .. ' + ' ..
            _G.itv("{'nsec': -1}"),
            _G.dt('-5879610-06-22T01:00:00+01:00') .. ' - ' ..
            _G.itv("{'nsec': 1}"),
            _G.dt('5879611-07-11T00:00:00.999999999Z') .. ' + ' ..
            _G.itv("{'nsec': 1}"),
            _G.dt('5879611-07-10T23:00:00.999999999-01:00') .. ' + ' ..
            _G.itv("{'nsec': 1}"),
            _G.dt('2026-01-01T00:00:00Z') .. ' + ' ..
            _G.itv("{'year': 9999999}"),
            _G.dt('2026-01-01T00:00:00Z') .. ' - ' ..
            _G.itv("{'month': 99999999}"),
        }) do
            t.assert_equals(_G.expr_error(expr), message, expr)
        end
    end)
end

-- A datetime result at the limit of the type is correct.
g.test_datetime_result_at_limit = function()
    g.server:exec(function()
        local res = box.execute('SELECT CAST(' ..
            _G.dt('5879611-07-10T00:00:00Z') .. ' + ' ..
            _G.itv("{'day': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'5879611-07-11T00:00:00Z'}})
        res = box.execute('SELECT CAST(' ..
            _G.dt('-5879610-06-22T00:00:00.000000001Z') .. ' - ' ..
            _G.itv("{'nsec': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'-5879610-06-22T00:00:00Z'}})
        t.assert_equals(_G.expr_error(_G.dt('5879611-07-10T00:00:00Z') ..
            ' - ' .. _G.dt('-5879610-06-23T00:00:00Z')), nil)
    end)
end

-- Intermediate nanoseconds may exceed int32_t before normalization.
g.test_datetime_nanosecond_carry = function()
    g.server:exec(function()
        local dt = _G.dt('2026-01-01T00:00:00.999999999Z')
        for _, expr in ipairs({
            dt .. ' + ' .. _G.itv("{'nsec': 2147483647}"),
            dt .. ' - ' .. _G.itv("{'nsec': -2147483647}"),
        }) do
            local res = box.execute('SELECT CAST(' .. expr .. ' AS STRING);')
            t.assert_equals(res.rows, {{'2026-01-01T00:00:03.147483646Z'}})
        end
        local res = box.execute('SELECT CAST(' .. dt .. ' - ' ..
            _G.itv("{'nsec': 2147483647}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'2025-12-31T23:59:58.852516352Z'}})
    end)
end

-- The sum of a value of a DATETIME series and the step out of the range
-- of DATETIME is an error. Unlike the cases of the test with the same
-- name in table_func_test.lua, the datetimes here are near the limit of
-- the tarantool range, so they are parsed by tarantool only.
g.test_generate_series_datetime_limits = function()
    g.server:exec(function()
        local sql = [[SELECT CAST(VALUE AS STRING) FROM generate_series(
                          %s, CAST('%s' AS DATETIME),
                          CAST(%s AS INTERVAL))%s;]]
        local function dt(s)
            return ("CAST('%s' AS DATETIME)"):format(s)
        end
        for _, case in ipairs({
            {dt('5879611-07-01T00:00:00Z'), '5879611-07-11T00:00:00Z',
             "{'day': 7}",
             {'5879611-07-01T00:00:00Z', '5879611-07-08T00:00:00Z'}},
            {dt('-5879610-06-25T00:00:00Z'), '-5879610-06-22T00:00:00Z',
             "{'day': -2}",
             {'-5879610-06-25T00:00:00Z', '-5879610-06-23T00:00:00Z'}},
        }) do
            local rows = {}
            for i, value in ipairs(case[4]) do
                rows[i] = {value}
            end
            local res = box.execute(sql:format(case[1], case[2], case[3],
                                               ' LIMIT ' .. #rows))
            t.assert_equals(res.rows, rows, case[3])
            local _, err = box.execute(sql:format(case[1], case[2], case[3],
                                                  ''))
            t.assert_equals(err.message, 'Failed to execute SQL ' ..
                            'statement: datetime is overflowed', case[3])
        end
    end)
end
