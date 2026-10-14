local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'datetime-map-format'})
    g.server:start()
    g.server:exec(function()
        rawset(_G, 'mismatch', function(map_text)
            return ('Type mismatch: can not convert map(%s) to datetime')
                   :format(map_text)
        end)
        -- Checks that the cast of each map to DATETIME is a type mismatch
        -- error. A case is the map in SQL and the map in the error message.
        rawset(_G, 'check_mismatch', function(cases)
            for _, case in ipairs(cases) do
                local _, err = box.execute(
                    ('SELECT CAST(%s AS DATETIME);'):format(case[1]))
                t.assert_equals(err ~= nil and err.message or nil,
                                _G.mismatch(case[2]), case[1])
            end
        end)
        -- Returns the cases of the maps with each key and the value 1.
        rawset(_G, 'key_cases', function(keys)
            local cases = {}
            for _, key in ipairs(keys) do
                table.insert(cases, {("{'%s': 1}"):format(key),
                                     ('{"%s": 1}'):format(key)})
            end
            return cases
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- A key that is not the name of a field of DATETIME is an error.
g.test_unknown_key = function()
    g.server:exec(function()
        _G.check_mismatch({
            {"{'days': 1}", '{"days": 1}'},
            {"{'second': 1}", '{"second": 1}'},
            {"{'x': 1}", '{"x": 1}'},
            {"{'day': 1, 'x': 2}", '{"day": 1, "x": 2}'},
            {"{'x': 2, 'day': 1}", '{"x": 2, "day": 1}'},
            -- The names are case-sensitive.
            {"{'DAY': 1}", '{"DAY": 1}'},
            {"{'Year': 1}", '{"Year": 1}'},
        })
        -- The names of the fields of INTERVAL that DATETIME has not.
        _G.check_mismatch(_G.key_cases({'week', 'adjust'}))
    end)
end

-- The start of the name of a field is not the name of the field.
g.test_start_of_name_as_key = function()
    g.server:exec(function()
        _G.check_mismatch(_G.key_cases({'', 'y', 'm', 'mo', 'd', 'da', 'h',
                                        's', 'ms', 'u', 'n', 't', 'time',
                                        'tz'}))
    end)
end

-- A key that is not a string is an error.
g.test_key_is_not_string = function()
    g.server:exec(function()
        _G.check_mismatch({
            {'{1: 1}', '{1: 1}'},
            {'{-5: 1}', '{-5: 1}'},
            {"{'day': 1, 2: 3}", '{"day": 1, 2: 3}'},
        })
    end)
end

-- A key that is the same as a key before it is an error. A map literal
-- keeps only the last of such keys, so the maps come from a column.
g.test_repeated_key = function()
    g.server:exec(function()
        local raw = require('msgpack').object_from_raw
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP);]])
        box.space.T:insert({1, raw('\x82\xa3day\x01\xa3day\x02')})
        box.space.T:insert({2, raw('\x82\xa3day\x01\xa3day\x01')})
        box.space.T:insert({3, raw('\x83\xa3day\x01\xa4hour\x02' ..
                                   '\xa3day\x03')})
        for id, map_text in ipairs({'{"day": 1, "day": 2}',
                                    '{"day": 1, "day": 1}',
                                    '{"day": 1, "hour": 2, "day": 3}'}) do
            local _, err = box.execute(
                [[SELECT CAST(m AS DATETIME) FROM t WHERE id = ?;]], {id})
            t.assert_equals(err.message, _G.mismatch(map_text), map_text)
        end
        box.execute([[DROP TABLE t;]])
    end)
end

-- The check applies to a map from a bound parameter and from a column.
g.test_map_from_parameter_and_column = function()
    g.server:exec(function()
        local dt = require('datetime')
        local sql = [[SELECT CAST(#v AS DATETIME);]]
        local res = box.execute(sql, {{['#v'] = {day = 2}}})
        t.assert_equals(res.rows, {{dt.new({day = 2})}})
        local _, err = box.execute(sql, {{['#v'] = {days = 2}}})
        t.assert_equals(err.message, _G.mismatch('{"days": 2}'))
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP);]])
        box.execute([[INSERT INTO t VALUES (1, {'day': 2}), (2, {'d': 2});]])
        res = box.execute([[SELECT CAST(m AS DATETIME) FROM t
                            WHERE id = 1;]])
        t.assert_equals(res.rows, {{dt.new({day = 2})}})
        _, err = box.execute([[SELECT CAST(m AS DATETIME) FROM t;]])
        t.assert_equals(err.message, _G.mismatch('{"d": 2}'))
        box.execute([[DROP TABLE t;]])
    end)
end
