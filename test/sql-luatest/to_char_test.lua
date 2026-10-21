local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'to_char'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

-- TO_CHAR() must return the same string as datetime:format().
g.test_to_char_matches_format = function()
    g.server:exec(function()
        local dt = require('datetime')
        local dates = {
            '2026-01-13T15:04:05Z',
            '2026-01-13T15:04:05.123456789+05:45',
            '2026-01-13T15:04:05.123456-03:30',
            '2026-07-01T23:30:00 Europe/Moscow',
            '2020-12-31T08:00:00Z',
            '2021-01-03T08:00:00Z',
            '0001-01-01T00:00:00Z',
            '1969-12-31T23:59:59-01:00',
        }
        local formats = {
            '%A %a %B %b %h %p',
            '%C|%y|%Y|%G|%g|%D|%F|%v|%x|%c|%+',
            '%d|%e|%H|%I|%k|%l|%M|%m|%S|%j|%u|%w|%U|%W|%V',
            '%R|%r|%T|%X|%s|%z|%Z',
            '%f|%0f|%1f|%3f|%6f|%9f|%12f',
            '%%|%Ey|%OH|%q|%3d|plain text|%',
            'plain text|%3',
            'plain text|%12',
            '',
        }
        for _, str in ipairs(dates) do
            local d = dt.parse(str)
            for _, f in ipairs(formats) do
                local res, err = box.execute([[SELECT TO_CHAR(?, ?);]],
                                             {d, f})
                t.assert_equals(err, nil, f)
                t.assert_equals(res.rows, {{d:format(f)}}, f)
            end
        end
    end)
end

-- The output and the format can be longer than the internal buffers.
g.test_to_char_long = function()
    g.server:exec(function()
        local dt = require('datetime')
        local d = dt.parse('2026-01-13T15:04:05Z')
        local f = string.rep('%c ', 1000)
        local rows = box.execute([[SELECT TO_CHAR(?, ?);]], {d, f}).rows
        t.assert_equals(rows, {{d:format(f)}})
        t.assert_equals(#rows[1][1], 25000)
    end)
end

g.test_to_char_null = function()
    g.server:exec(function()
        local dt = require('datetime')
        local d = dt.parse('2026-01-13T15:04:05Z')
        local sql = [[SELECT TO_CHAR(?, ?);]]
        t.assert_equals(box.execute(sql, {d, box.NULL}).rows, {{box.NULL}})
        t.assert_equals(box.execute(sql, {box.NULL, '%Y'}).rows,
                        {{box.NULL}})
    end)
end

g.test_to_char_wrong_type = function()
    g.server:exec(function()
        local _, err = box.execute([[SELECT TO_CHAR(1, '%Y');]])
        t.assert_equals(err.message, "Failed to execute SQL statement: " ..
                        "wrong arguments for function TO_CHAR()")
    end)
end
