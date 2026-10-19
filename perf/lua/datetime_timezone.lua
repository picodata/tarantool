--
-- The test measures datetime operations that depend on time zones.
--
-- Output format:
-- <test-case> <run-time-nanoseconds>
--
-- The format test depends on TZ of the process: when TZ is not set, glibc
-- may check /etc/localtime on every call. Run the test without TZ and with
-- TZ=UTC, and compare the results of two builds with compare.lua.
--

local clock = require('clock')
local datetime = require('datetime')
local t = require('tarantool')

local _, _, build_type = string.match(t.build.target, "^(.+)-(.+)-(.+)$")
if build_type == "Debug" then
    print("WARNING: tarantool has built with enabled debug mode")
end

local function new_in(tz)
    return datetime.new{year = 2026, month = 9, day = 24, hour = 10, min = 5,
                        tz = tz}
end

local date = new_in()
-- tzdata has no file for this abbreviation.
local date_msk = new_in('MSK')

local TESTS = {
    {
        name = 'format',
        run = function(n)
            for _ = 1, n do
                date:format('%Y-%m-%d %H:%M')
            end
        end,
    },
    {
        name = 'new_in_one_zone',
        run = function(n)
            for _ = 1, n do
                new_in('Europe/Moscow')
            end
        end,
    },
    {
        name = 'new_in_two_alternating_zones',
        run = function(n)
            for i = 1, n do
                new_in(i % 2 == 0 and 'Europe/Moscow' or 'America/New_York')
            end
        end,
    },
    {
        name = 'isdst_in_zone_without_file',
        run = function(n)
            for _ = 1, n do
                local _ = date_msk.isdst
            end
        end,
    },
}

local ITERATIONS = 2e5
local RUNS = 3

for _, test in ipairs(TESTS) do
    -- Warm up the JIT, then take the best run.
    test.run(ITERATIONS)
    local best = math.huge
    for _ = 1, RUNS do
        local start = clock.monotonic()
        test.run(ITERATIONS)
        best = math.min(best, clock.monotonic() - start)
    end
    print(string.format('%s %d', test.name, best / ITERATIONS * 1e9))
end

os.exit(0)
