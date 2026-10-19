local datetime = require('datetime')
local ffi = require('ffi')
local msgpack = require('msgpack')
local t = require('luatest')

ffi.cdef[[
    int setenv(const char *name, const char *value, int overwrite);
]]

local g = t.group()

local tz_at_start

g.before_all(function()
    tz_at_start = os.getenv('TZ')
end)

g.after_each(function()
    os.setenv('TZ', tz_at_start)
end)

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

local function offsets_of_zones()
    local function offset(tz)
        return datetime.new{year = 2026, month = 9, day = 24, tz = tz}.tzoffset
    end
    return {offset('Europe/Moscow'), offset('America/New_York')}
end

g.test_alternating_zones = function()
    for _ = 1, 1000 do
        t.assert_equals(offsets_of_zones(), {180, -240})
    end
end

-- tzdata has no file for MSK, and the failed lookup is remembered.
g.test_zone_without_tzdata_file = function()
    local d = datetime.new{year = 2026, month = 9, day = 24, tz = 'MSK'}
    for _ = 1, 1000 do
        t.assert_equals(d.isdst, false)
    end
    t.assert_equals(d.tzoffset, 180)
end

g.test_zones_after_reload = function()
    t.assert_equals(offsets_of_zones(), {180, -240})
    datetime.tz_reload()
    t.assert_equals(offsets_of_zones(), {180, -240})
end

g.test_tz_reload = function()
    ffi.C.setenv('TZ', 'XXX-3', 1)
    datetime.tz_reload()
    t.assert_equals(datetime.now().tzoffset, 180)
    ffi.C.setenv('TZ', 'XXX+5', 1)
    datetime.tz_reload()
    t.assert_equals(datetime.now().tzoffset, -300)
end

g.test_setenv_tz = function()
    os.setenv('TZ', 'XXX-3')
    t.assert_equals(datetime.now().tzoffset, 180)
    t.assert_equals(os.date('%z'), '+0300')
    os.setenv('TZ', 'XXX+5')
    t.assert_equals(datetime.now().tzoffset, -300)
    t.assert_equals(os.date('%z'), '-0500')
end

-- The name is compared as C sees it: 'TZ\0suffix' sets TZ.
g.test_setenv_tz_c_name = function()
    os.setenv('TZ\0suffix', 'XXX-3')
    t.assert_equals(os.getenv('TZ'), 'XXX-3')
    t.assert_equals(datetime.now().tzoffset, 180)
end

g.test_unsetenv_tz = function()
    os.setenv('TZ', nil)
    local offset = datetime.now().tzoffset
    -- Any zone other than the local one.
    local other = offset == 180 and 'XXX-4' or 'XXX-3'
    os.setenv('TZ', other)
    t.assert_not_equals(datetime.now().tzoffset, offset)
    os.setenv('TZ', nil)
    t.assert_equals(datetime.now().tzoffset, offset)
end

g.test_setenv_error = function()
    t.assert_error(os.setenv, 'A=B', '1')
end

-- datetime:format() takes the zone from the datetime, not from the process.
g.test_format_ignores_process_tz = function()
    local named = datetime.new{year = 2026, month = 9, day = 24, hour = 10,
                               min = 5, tz = 'Europe/Moscow'}
    local fixed = datetime.new{year = 2026, month = 9, day = 24, hour = 10,
                               min = 5, tzoffset = '+0530'}
    for _, tz in ipairs({'UTC', 'XXX+5'}) do
        os.setenv('TZ', tz)
        t.assert_equals(named:format('%Y-%m-%d %H:%M %z %Z'),
                        '2026-09-24 10:05 +0300 Europe/Moscow', tz)
        t.assert_equals(fixed:format('%H:%M %z'), '10:05 +0530', tz)
    end
end
