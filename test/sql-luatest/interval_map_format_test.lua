local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'interval-map-format'})
    g.server:start()
    g.server:exec(function()
        -- Returns the error message of the cast of the map to INTERVAL,
        -- or nil if there is no error.
        rawset(_G, 'cast_error', function(map)
            local _, err = box.execute(('SELECT CAST(%s AS INTERVAL);')
                                       :format(map))
            return err ~= nil and err.message or nil
        end)
        rawset(_G, 'mismatch', function(map_text)
            return ('Type mismatch: can not convert map(%s) to interval')
                   :format(map_text)
        end)
    end)
end)

g.after_all(function()
    g.server:stop()
end)

-- A map with the names of the fields of INTERVAL as keys is correct.
g.test_correct_map = function()
    g.server:exec(function()
        local itv = require('datetime').interval
        local res = box.execute([[
            SELECT CAST({'year': 1, 'month': 2, 'week': 3, 'day': 4,
                         'hour': 5, 'min': 6, 'sec': 7, 'nsec': 8,
                         'adjust': 'last'} AS INTERVAL);]])
        t.assert_equals(res.rows, {{itv.new({
            year = 1, month = 2, week = 3, day = 4, hour = 5, min = 6,
            sec = 7, nsec = 8, adjust = 'last'})}})
        res = box.execute([[SELECT CAST({} AS INTERVAL);]])
        t.assert_equals(res.rows, {{itv.new()}})
        -- A number with an exact integer value is a correct value.
        res = box.execute([[SELECT CAST({'year': 1.0, 'day': 2e0}
                                        AS INTERVAL);]])
        t.assert_equals(res.rows, {{itv.new({year = 1, day = 2})}})
        -- Each adjust value gives its adjust mode.
        for _, adjust in ipairs({'none', 'last', 'excess'}) do
            res = box.execute(("SELECT CAST({'day': 1, 'adjust': '%s'} " ..
                               "AS INTERVAL);"):format(adjust))
            t.assert_equals(res.rows[1][1]:totable().adjust, adjust)
        end
    end)
end

-- A key that is not the name of a field of INTERVAL is an error.
g.test_unknown_key = function()
    g.server:exec(function()
        for _, case in ipairs({
            {"{'days': 1}", '{"days": 1}'},
            {"{'second': 1}", '{"second": 1}'},
            {"{'x': 1}", '{"x": 1}'},
            {"{'day': 1, 'x': 2}", '{"day": 1, "x": 2}'},
            {"{'x': 2, 'day': 1}", '{"x": 2, "day": 1}'},
            -- The names are case-sensitive.
            {"{'DAY': 1}", '{"DAY": 1}'},
            {"{'Year': 1}", '{"Year": 1}'},
            -- The names of the fields of DATETIME that INTERVAL has not.
            {"{'msec': 1}", '{"msec": 1}'},
            {"{'usec': 1}", '{"usec": 1}'},
            {"{'timestamp': 1}", '{"timestamp": 1}'},
        }) do
            t.assert_equals(_G.cast_error(case[1]), _G.mismatch(case[2]),
                            case[1])
        end
    end)
end

-- The start of the name of a field is not the name of the field.
g.test_start_of_name_as_key = function()
    g.server:exec(function()
        for _, key in ipairs({'', 'y', 'ye', 'yea', 'm', 'mo', 'w', 'd',
                              'da', 'h', 's', 'n', 'ns', 'a', 'adj'}) do
            local map = ("{'%s': 1}"):format(key)
            t.assert_equals(_G.cast_error(map),
                            _G.mismatch(('{"%s": 1}'):format(key)), map)
        end
    end)
end

-- A key that is not a string is an error.
g.test_key_is_not_string = function()
    g.server:exec(function()
        for _, case in ipairs({
            {'{1: 1}', '{1: 1}'},
            {'{-5: 1}', '{-5: 1}'},
            {"{'day': 1, 2: 3}", '{"day": 1, 2: 3}'},
        }) do
            t.assert_equals(_G.cast_error(case[1]), _G.mismatch(case[2]),
                            case[1])
        end
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
                [[SELECT CAST(m AS INTERVAL) FROM t WHERE id = ?;]], {id})
            t.assert_equals(err.message, _G.mismatch(map_text), map_text)
        end
        box.execute([[DROP TABLE t;]])
    end)
end

-- A value that is not an integer number in the range of the field is an
-- error.
g.test_malformed_value = function()
    g.server:exec(function()
        for _, case in ipairs({
            {"{'day': '1'}", '{"day": "1"}'},
            {"{'day': true}", '{"day": true}'},
            {"{'day': NULL}", '{"day": null}'},
            {"{'day': [1]}", '{"day": [1]}'},
            {"{'day': {'a': 1}}", '{"day": {"a": 1}}'},
            {"{'day': 1.5}", '{"day": 1.5}'},
            {"{'day': 15e-1}", '{"day": 1.5}'},
            {"{'year': 1.5}", '{"year": 1.5}'},
            {"{'year': '1'}", '{"year": "1"}'},
            {"{'nsec': NULL}", '{"nsec": null}'},
            {"{'year': 3000000000}", '{"year": 3000000000}'},
            {"{'year': 11759222}", '{"year": 11759222}'},
            {"{'day': 1, 'hour': 'a'}", '{"day": 1, "hour": "a"}'},
        }) do
            t.assert_equals(_G.cast_error(case[1]), _G.mismatch(case[2]),
                            case[1])
        end
    end)
end

-- An adjust value that is not 'none', 'last' or 'excess' is an error. The
-- start of one of these words is an error too. The words are
-- case-sensitive.
g.test_malformed_adjust = function()
    g.server:exec(function()
        for _, case in ipairs({
            {"{'adjust': 'x'}", '{"adjust": "x"}'},
            {"{'adjust': ''}", '{"adjust": ""}'},
            {"{'adjust': 'la'}", '{"adjust": "la"}'},
            {"{'adjust': 'n'}", '{"adjust": "n"}'},
            {"{'adjust': 'lasts'}", '{"adjust": "lasts"}'},
            {"{'adjust': 'LAST'}", '{"adjust": "LAST"}'},
            {"{'adjust': 'Excess'}", '{"adjust": "Excess"}'},
            {"{'adjust': 1}", '{"adjust": 1}'},
            {"{'adjust': NULL}", '{"adjust": null}'},
        }) do
            t.assert_equals(_G.cast_error(case[1]), _G.mismatch(case[2]),
                            case[1])
        end
    end)
end

-- The check applies to a map from a bound parameter and from a column.
g.test_map_from_parameter_and_column = function()
    g.server:exec(function()
        local itv = require('datetime').interval
        local sql = [[SELECT CAST(#v AS INTERVAL);]]
        local res = box.execute(sql, {{['#v'] = {day = 1}}})
        t.assert_equals(res.rows, {{itv.new({day = 1})}})
        local _, err = box.execute(sql, {{['#v'] = {days = 1}}})
        t.assert_equals(err.message, _G.mismatch('{"days": 1}'))
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, m MAP);]])
        box.execute([[INSERT INTO t VALUES (1, {'day': 1}), (2, {'d': 1});]])
        res = box.execute([[SELECT CAST(m AS INTERVAL) FROM t
                            WHERE id = 1;]])
        t.assert_equals(res.rows, {{itv.new({day = 1})}})
        _, err = box.execute([[SELECT CAST(m AS INTERVAL) FROM t;]])
        t.assert_equals(err.message, _G.mismatch('{"d": 1}'))
        box.execute([[DROP TABLE t;]])
    end)
end
