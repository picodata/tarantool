local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'explain-analyze-round'})
    g.server:start()
    g.server:exec(function()
        box.execute([[SET SESSION "sql_vdbe_max_steps" = 0;]])
        box.execute([[CREATE TABLE t (id INT PRIMARY KEY, a INT);]])
        box.begin()
        for i = 1, 12345 do
            box.space.T:insert({i, i})
        end
        box.commit()
        -- Returns the type of the column "hits" and its value for the
        -- instruction that reads a column of each row of the table.
        rawset(_G, 'hits', function(options)
            local sql = ([[EXPLAIN (ANALYZE {'mode': 'hits'%s}, opcode)
                           SELECT sum(a) FROM t;]]):format(options)
            local res, err = box.execute(sql)
            if res == nil then
                return nil, err.message
            end
            for _, row in ipairs(res.rows) do
                if row[3]:find('Column') ~= nil then
                    return res.metadata[1].type, row[1]
                end
            end
        end)
    end)
    -- A build that cannot sample the instructions gives an error for the
    -- default mode of EXPLAIN ANALYZE, so these tests are not for it.
    local can_sample = g.server:exec(function()
        local _, err = box.execute([[EXPLAIN ANALYZE SELECT 1;]])
        return err == nil or err.message:find('cannot sample', 1, true) == nil
    end)
    t.skip_if(not can_sample, 'the build cannot sample the instructions')
end)

g.after_all(function()
    g.server:stop()
end)

-- The value of the option is TRUE or FALSE.
g.test_round_value = function()
    g.server:exec(function()
        local msg = "EXPLAIN option 'round' must be TRUE or FALSE"
        for _, value in ipairs({'1', '0', "'false'", '0.5'}) do
            local _, err = _G.hits([[, 'round': ]] .. value)
            t.assert_str_contains(err, msg, false, value)
        end
    end)
end

-- By default, and with TRUE, a measurement is a text of at most 5
-- characters, rounded down.
g.test_round = function()
    g.server:exec(function()
        t.assert_equals({_G.hits('')}, {'text', '12.3k'})
        t.assert_equals({_G.hits([[, 'round': true]])}, {'text', '12.3k'})
    end)
end

-- With FALSE, a measurement is an exact integer.
g.test_no_round = function()
    g.server:exec(function()
        t.assert_equals({_G.hits([[, 'round': false]])}, {'integer', 12345})
        local res = box.execute([[EXPLAIN (ANALYZE {'mode': 'all',
                                                    'round': false})
                                  SELECT sum(a) FROM t;]])
        for i = 1, 3 do
            t.assert_equals(res.metadata[i].type, 'integer')
        end
        t.assert_equals(res.metadata[4].name, 'addr')
    end)
end
