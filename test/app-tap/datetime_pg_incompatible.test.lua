#!/usr/bin/env tarantool

-- PostgreSQL-incompatible datetime tests.

local tap = require('tap')
local test = tap.test('datetime_parse_full')
local date = require('datetime')
local TZ = date.TZ

test:plan(7)

local function assert_raises(test, error_msg, func, ...)
    local ok, err = pcall(func, ...)
    local err_tail = err and err:gsub("^.+:%d+: ", "") or ''
    return test:is(not ok and err_tail, error_msg,
                   ('"%s" received, "%s" expected'):format(err_tail, error_msg))
end

test:test("Simple tests for parser", function(test)
    test:plan(2)

    -- Testcases with override timezone by setting tzoffset.
    test:ok(date.parse("1970-01-01T01:00:00Z", {tzoffset = '+02:00'}) ==
            date.new{year=1970, mon=1, day=1, hour=1, min=0, sec=0, tzoffset=0})

    -- Testcases with override timezone by setting tz.
    -- Timezone is specified in a parsed string as a military timezone.
    test:ok(date.parse("1970-01-01T01:00:00Z", {tz = "Europe/Moscow"}) ==
            date.new{
                year = 1970, mon = 1, day = 1,
                hour = 1, min = 0, sec = 0, tzoffset = 0
            })
end)

test:test("Multiple tests for parser (with nanoseconds)", function(test)
    test:plan(49)
    -- borrowed from
    -- github.com/chansen/p5-time-moment/blob/master/t/180_from_string.t
    local tests =
    {
        --{ iso-8601 string, epoch, nanoseconds, tz-offset, do reverse check?}
        {'0001-W01-1T00:00:00Z',    -62135596800,         0,    0, 0},
        {'0001W011T000000Z',        -62135596800,         0,    0, 0},
        {'0001001T000000Z',         -62135596800,         0,    0, 0},
        {'1970-01-01T00:00:00.123456789Z',     0, 123456789,    0, 1},
        {'1970-01-01T00:00:00.12345678Z',      0, 123456780,    0, 0},
        {'1970-01-01T00:00:00.1234567Z',       0, 123456700,    0, 0},
        {'1970-01-01T00:00:00.0000001Z',       0,       100,    0, 0},
        {'1970-01-01T00:00:00.00000001Z',      0,        10,    0, 0},
        {'1970-01-01T00:00:00.000000001Z',     0,         1,    0, 1},
        {'1970-01-01T00:00:00.000000009Z',     0,         9,    0, 1},
        {'1970-01-01T00:00:00.00000009Z',      0,        90,    0, 0},
        {'1970-01-01T00:00:00.0000009Z',       0,       900,    0, 0},
        {'1970-01-01T00:00:00.9999999Z',       0, 999999900,    0, 0},
        {'1970-01-01T00:00:00.99999999Z',      0, 999999990,    0, 0},
        {'1970-01-01T00:00:00.999999999Z',     0, 999999999,    0, 1},
    }
    for _, value in ipairs(tests) do
        local str, epoch, nsec, tzoffset, check
        str, epoch, nsec, tzoffset, check = unpack(value)
        local dt = date.parse(str)
        test:is(dt.epoch, epoch, ('%s: dt.epoch == %d'):format(str, epoch))
        test:is(dt.nsec, nsec, ('%s: dt.nsec == %d'):format(str, nsec))
        test:is(dt.tzoffset, tzoffset, ('%s: dt.tzoffset == %d'):format(str, tzoffset))
        if check > 0 then
            test:is(str, tostring(dt), ('%s == tostring(%s)'):
                    format(str, tostring(dt)))
        end
    end
end)

test:test("Check parsing of full supported years range", function(test)
    test:plan(45)
    local valid_years = {
        -5879610, -5879000, -5800000, -2e6, -1e5, -1e4, -9999, -2000, -1000,
        0, 1e4, 1e6, 2e6, 5e6, 5879611
    }
    local fmt = '%FT%T%z'
    for _, y in ipairs(valid_years) do
        local txt = ('%04d-06-22'):format(y)
        local dt = date.parse(txt)
        test:isnt(dt, nil, dt)
        local out_txt = tostring(dt)
        local out_dt = date.parse(out_txt)
        test:is(dt, out_dt, ('default parse of %s (%s == %s)'):
                            format(out_txt, dt, out_dt))
        local fmt_dt = date.parse(out_txt, {format = fmt})
        test:is(dt, fmt_dt, ('parse via format %s (%s == %s)'):
                            format(fmt, dt, fmt_dt))
    end
end)

test:test("Parsing of timezone abbrevs", function(test)
    test:plan(220)
    local zone_abbrevs = {
        -- military
        A =   1*60, B =   2*60, C =   3*60,
        D =   4*60, E =   5*60, F =   6*60,
        G =   7*60, H =   8*60, I =   9*60,
        K =  10*60, L =  11*60, M =  12*60,

        N =  -1*60, O =  -2*60, P =  -3*60,
        Q =  -4*60, R =  -5*60, S =  -6*60,
        T =  -7*60, U =  -8*60, V =  -9*60,
        W = -10*60, X = -11*60, Y = -12*60,

        Z = 0,

        -- universal
        GMT = 0, UTC = 0, UT = 0,
        -- some non ambiguous
        MSK = 3 * 60,   MCK = 3 * 60,   CET = 1 * 60,
        AMDT = 5 * 60,  BDST = 1 * 60,  IRKT = 8 * 60,
        KST = 9 * 60,   PDT = -7 * 60,  WET = 0 * 60,
        HOVDST = 8 * 60, CHODST = 9 * 60,

        -- Olson
        ['Europe/Moscow'] = 180,
        ['Africa/Abidjan'] = 0,
        ['America/Argentina/Buenos_Aires'] = -180,
        ['Asia/Krasnoyarsk'] = 420,
        ['Pacific/Fiji'] = 720,
    }
    local exp_pattern = '^2020%-02%-10T00:00'
    local base_date = '2020-02-10T0000 '

    for zone, offset in pairs(zone_abbrevs) do
        local date_text = base_date .. zone
        local date, len = date.parse(date_text)
        test:isnt(date, nil, 'parse ' .. zone)
        test:ok(len > #base_date, 'length longer than ' .. #base_date)
        test:is(1, tostring(date):find(exp_pattern), 'expected prefix')
        test:is(date.tzoffset, offset, 'expected offset')
        test:is(date.tz, zone, 'expected timezone name')
    end
end)

test:test("Parsing of timezone names (tzindex)", function(test)
    test:plan(396)
    local zone_abbrevs = {
        -- military
        A =  1, B =  2, C =  3,
        D =  4, E =  5, F =  6,
        G =  7, H =  8, I =  9,
        K = 10, L = 11, M = 12,

        N = 13, O = 14, P = 15,
        Q = 16, R = 17, S = 18,
        T = 19, U = 20, V = 21,
        W = 22, X = 23, Y = 24,

        Z = 25,

        -- universal
        GMT = 186, UTC = 296, UT = 112,

        -- some non ambiguous
        MSK = 238,   MCK = 232,  CET = 155,
        AMDT = 336,  BDST = 344, IRKT = 409,
        KST = 226,   PDT = 264,  WET = 314,
        HOVDST = 664, CHODST = 656,

        -- Olson
        ['Europe/Moscow'] = 947,
        ['Africa/Abidjan'] = 672,
        ['America/Argentina/Buenos_Aires'] = 694,
        ['Asia/Krasnoyarsk'] = 861,
        ['Pacific/Fiji'] = 984,
    }
    local exp_pattern = '^2020%-02%-10T00:00'
    local base_date = '2020-02-10T0000 '

    for zone, index in pairs(zone_abbrevs) do
        local date_text = base_date .. zone
        local date, len = date.parse(date_text)
        print(zone, index)
        test:isnt(date, nil, 'parse ' .. zone)
        local tzname = date.tz
        local tzindex = date.tzindex
        test:is(tzindex, index, 'expected tzindex')
        test:is(tzname, zone, 'expected timezone name')
        test:is(TZ[tzindex], tzname, ('TZ[%d] => %s'):format(tzindex, tzname))
        test:is(TZ[tzname], tzindex, ('TZ[%s] => %d'):format(tzname, tzindex))
        test:ok(len > #base_date, 'length longer than ' .. #base_date)
        local txt = tostring(date)
        test:is(1, txt:find(exp_pattern), 'expected prefix')
        test:is(zone, txt:sub(#txt - #zone + 1, #txt), 'sub of ' .. txt)
        txt = date:format('%FT%T %Z')
        test:is(zone, txt:sub(#txt - #zone + 1, #txt), 'sub of ' .. txt)
    end
end)

local function error_ambiguous(s)
    return ("could not parse '%s' - ambiguous timezone"):format(s)
end

local function error_generic(s)
    return ("could not parse '%s'"):format(s)
end

test:test("Parsing of timezone names (errors)", function(test)
    test:plan(9)
    local zones_arratic = {
        -- ambiguous
        AT = error_ambiguous, BT = error_ambiguous,
        ACT = error_ambiguous, BST = error_ambiguous,
        GST = error_ambiguous, WAT = error_ambiguous,
        AZOST = error_ambiguous,
        -- generic errors
        ['XXX'] = error_generic,
        ['A-_'] = error_generic,
    }
    local base_date = '2020-02-10T0000 '

    for zone, error_function in pairs(zones_arratic) do
        local date_text = base_date .. zone
        assert_raises(test, error_function(date_text),
                      function() return date.parse(date_text) end)
    end
end)

test:test("Daylight saving checks", function (test)
    --[[
        Check various dates in `Europe/Moscow` timezone for their
        proper daylight saving settings.

        Tzdata defines these rules for `Europe/Moscow` time-zone:
```
Zone Europe/Moscow  2:30:17 -       LMT 1880
                    2:30:17 -       MMT 1916 Jul  3 # Moscow Mean Time
                    2:31:19 Russia  %s  1919 Jul  1  0:00u
                    3:00    Russia  %s  1921 10
                    3:00    Russia  Europe/Moscow/Europe/Moscow 1922 10
                    2:00    -       EET 1930 Jun 21
                    3:00    Russia  Europe/Moscow/Europe/Moscow 1991 03 31 2:00s
                    2:00    Russia  EE%sT 1992 Jan 19  2:00s
                    3:00    Russia  Europe/Moscow/Europe/Moscow 2011 03 27 2:00s
                    4:00    -       Europe/Moscow 2014 10 26 2:00s
                    3:00    -       Europe/Moscow
```
        Either you could see the same table dumped in more or less
        human-readable form using `zdump` utility:

        `zdump -c 2004,2022 -v Europe/Moscow`
    ]]
    test:plan(30)
    local moments = {
        -- string, isdst?, tzoffset (mins)
        {'2004-10-31T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2005-03-27T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2005-10-30T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2006-03-26T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2006-10-29T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2007-03-25T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2007-10-28T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2008-03-30T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2008-10-26T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2009-03-29T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2009-10-25T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2010-03-28T03:00:00 Europe/Moscow', true, 4 * 60},
        {'2010-10-31T02:00:00 Europe/Moscow', false, 3 * 60},
        {'2011-03-27T03:00:00 Europe/Moscow', false, 4 * 60},
        {'2014-10-26T01:00:00 Europe/Moscow', false, 3 * 60},
    }
    for _, row in pairs(moments) do
        local str, isdst, tzoffset = unpack(row)
        local dt = date.parse(str)
        test:is(dt.isdst, isdst,
                ('%s: isdst = %s'):format(tostring(dt), dt.isdst))
        test:is(dt.tzoffset, tzoffset,
                ('%s: tzoffset = %s'):format(tostring(dt), dt.tzoffset))
    end
end)

os.exit(test:check() and 0 or 1)
