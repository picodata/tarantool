local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'to_date'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

-- TO_DATE() must give the same result as datetime.parse() followed by
-- datetime:set({hour = 0, min = 0, sec = 0, nsec = 0}).
g.test_to_date_matches_parse = function()
    g.server:exec(function()
        local dt = require('datetime')
        local cases = {
            {'2026-01-13', ''},
            {'2026-01-13T15:04:05Z', ''},
            {'2026-01-13T23:30:00+05:45', ''},
            {'2026-01-13T00:30:00-03:30', ''},
            {'2026-01-13T23:59:59.999999999+14:00', ''},
            {'2026-07-01T23:30:00 Europe/Moscow', ''},
            {'1969-12-31T23:59:59-01:00', ''},
            {'4714-11-24 00:00:00+00 BC', ''},
            {'9999-12-31T23:59:59Z', ''},
            {'Oct 18, 2025 2:59 PM', ''},
            {'2026-01-13T15:04:05+03:00', 'iso8601'},
            {'2026-01-13T15:04:05+03:00', 'rfc3339'},
            {'18.10.2025', '%d.%m.%Y'},
            {'2026-01-13 23:30:00 +0530', '%Y-%m-%d %H:%M:%S %z'},
            {'2026-01-13xyz', '%Y-%m-%d'},
            {'2026 045', '%Y %j'},
            {'1969-12-31 23:00 -0100', '%Y-%m-%d %H:%M %z'},
            {'garbage', ''},
            {'2020-01-01T10:00 Foo/Bar', ''},
            {'2020-01-01T10:00 AT', ''},
            {'4714-11-23 23:59:59+00 BC', ''},
            {'10000-01-01T00:00:00Z', ''},
            {'2020/20/20', '%Y/%d/%m'},
            {'', '%Y'},
            {'', ''},
        }
        for _, c in ipairs(cases) do
            local str, fmt = c[1], c[2]
            local opts = fmt ~= '' and {format = fmt} or {}
            local ok, exp = pcall(dt.parse, str, opts)
            local res, err = box.execute([[SELECT TO_DATE(?, ?);]],
                                         {str, fmt})
            if ok then
                exp:set({hour = 0, min = 0, sec = 0, nsec = 0})
                t.assert_equals(err, nil, str)
                local got = res.rows[1][1]
                t.assert_equals({got.epoch, got.nsec, got.tzoffset, got.tz},
                                {exp.epoch, exp.nsec, exp.tzoffset, exp.tz},
                                str)
            else
                t.assert_equals(err.message,
                                "Failed to execute SQL statement: " ..
                                exp:gsub('^.-:%d+: ', ''), str)
            end
        end
    end)
end

g.test_to_date_null = function()
    g.server:exec(function()
        local sql = [[SELECT TO_DATE(?, ?);]]
        t.assert_equals(box.execute(sql, {'2026', box.NULL}).rows,
                        {{box.NULL}})
        t.assert_equals(box.execute(sql, {box.NULL, '%Y'}).rows,
                        {{box.NULL}})
    end)
end

-- The error message escapes the arguments as mp_snprint() does and prints
-- at most 32 bytes of each.
g.test_to_date_error_escape = function()
    g.server:exec(function()
        local long = string.rep('a', 32)
        local cases = {
            {'2026\0-01-13', '', [['2026\u0000-01-13']]},
            {'x\n\t\27\\"\'/\x7fд', '%Y',
             [['x\n\t\u001b\\\"'/\u007fд' using '%Y' format]]},
            {'x', '%Y\0%m', [['x' using '%Y\u0000%m' format]]},
            {long, '', "'" .. long .. "'"},
            {long .. 'b', '', "'" .. long .. "...'"},
            -- The cut does not split a character.
            {long:sub(2) .. 'дx', '', "'" .. long:sub(2) .. "...'"},
            {long:sub(3) .. 'дx', '', "'" .. long:sub(3) .. "д...'"},
            {long:sub(2) .. '\x80\x80', '',
             "'" .. long:sub(2) .. "\x80...'"},
            {long .. '\0', string.rep('%Y', 17),
             "'" .. long .. "...' using '" .. string.rep('%Y', 16) ..
             "...' format"},
        }
        for _, c in ipairs(cases) do
            local _, err = box.execute([[SELECT TO_DATE(?, ?);]],
                                       {c[1], c[2]})
            t.assert_equals(err.message, "Failed to execute SQL statement: " ..
                            "could not parse " .. c[3], c[3])
        end
    end)
end

g.test_to_date_wrong_type = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT TO_DATE(1, '%Y');]])
        t.assert_equals(err.message, "Failed to execute SQL statement: " ..
                        "wrong arguments for function TO_DATE()")
    end)
end
