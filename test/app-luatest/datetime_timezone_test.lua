local datetime = require('datetime')
local msgpack = require('msgpack')
local t = require('luatest')

local g = t.group()

-- Decode 1970-01-01T03:00:00+0300 with the given zone index from MsgPack,
-- as another Tarantool version could have written it.
local function decode_with_tzindex(tzindex)
    return msgpack.decode('\xc7\x10\x04' .. string.rep('\0', 12) ..
                          string.char(180, 0, tzindex % 256,
                                      math.floor(tzindex / 256)))
end

-- A zone index unknown to this version works as a fixed offset.
g.test_unknown_tzindex = function()
    local hole = 1
    while datetime.TZ[hole] ~= nil do
        hole = hole + 1
    end
    -- 1024 is the largest index MsgPack accepts, past the end of the table.
    for _, tzindex in ipairs({hole, 1024}) do
        local d = decode_with_tzindex(tzindex)
        local msg = 'tzindex ' .. tzindex
        t.assert_equals(tostring(d), '1970-01-01T03:00:00+0300', msg)
        t.assert_equals(d:format('%z'), '+0300', msg)
        t.assert_equals(d:format('%Z'), '', msg)
        t.assert_equals(d.tz, '', msg)
        t.assert_equals(d.isdst, false, msg)
        t.assert_equals(d:totable().tz, '', msg)
        local later = d + datetime.interval.new{hour = 1}
        t.assert_equals(later.epoch, 3600, msg)
        t.assert_equals(later.tzoffset, 180, msg)
    end
end
