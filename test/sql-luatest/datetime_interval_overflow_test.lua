local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'datetime-interval-overflow'})
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

-- The sum or the difference of a DATETIME and an INTERVAL that is out of
-- the range of DATETIME is an error.
g.test_datetime_is_out_of_range = function()
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

-- The sum or the difference of two INTERVAL values that is out of the
-- range of INTERVAL is an error.
g.test_interval_is_out_of_range = function()
    g.server:exec(function()
        local message = 'Failed to execute SQL statement: interval is ' ..
                        'overflowed'
        for _, expr in ipairs({
            _G.itv("{'year': 11759221}") .. ' + ' .. _G.itv("{'year': 1}"),
            _G.itv("{'year': -11759221}") .. ' - ' .. _G.itv("{'year': 1}"),
            _G.itv("{'nsec': 2147483647}") .. ' + ' .. _G.itv("{'nsec': 1}"),
            _G.itv("{'nsec': -2147483647}") .. ' - ' .. _G.itv("{'nsec': 1}"),
            _G.itv("{'nsec': 2147483647}") .. ' + ' .. _G.itv("{'nsec': 2}"),
            _G.itv("{'nsec': -2147483647}") .. ' - ' .. _G.itv("{'nsec': 2}"),
            _G.itv("{'nsec': -2147483647}") .. ' + ' .. _G.itv("{'nsec': -2}"),
            _G.itv("{'nsec': 2147483647}") .. ' - ' .. _G.itv("{'nsec': -2}"),
        }) do
            t.assert_equals(_G.expr_error(expr), message, expr)
        end
    end)
end

-- A result at the limit of the type is correct.
g.test_result_at_limit = function()
    g.server:exec(function()
        local res = box.execute('SELECT CAST(' ..
            _G.dt('5879611-07-10T00:00:00Z') .. ' + ' ..
            _G.itv("{'day': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'5879611-07-11T00:00:00Z'}})
        res = box.execute('SELECT CAST(' ..
            _G.itv("{'year': 11759220}") .. ' + ' ..
            _G.itv("{'year': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'+11759221 years'}})
        res = box.execute('SELECT CAST(' ..
            _G.dt('-5879610-06-22T00:00:00.000000001Z') .. ' - ' ..
            _G.itv("{'nsec': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'-5879610-06-22T00:00:00Z'}})
        res = box.execute('SELECT CAST(' ..
            _G.itv("{'nsec': 2147483646}") .. ' + ' ..
            _G.itv("{'nsec': 1}") .. ' AS STRING);')
        t.assert_equals(res.rows, {{'+0 seconds, 2147483647 nanoseconds'}})
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

-- The error does not stop the instance: the next statement works.
g.test_instance_works_after_error = function()
    g.server:exec(function()
        t.assert_not_equals(_G.expr_error(_G.dt('5879611-07-10T00:00:00Z') ..
            ' + ' .. _G.itv("{'day': 7}")), nil)
        t.assert_equals(box.execute('SELECT 1;').rows, {{1}})
    end)
end
