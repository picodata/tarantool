local server = require('luatest.server')
local t = require('luatest')

local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'like'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_computed_escape = function()
    g.server:exec(function()
        local sql = [[SELECT '' LIKE '' ESCAPE '' || '';]]
        local result, err = box.execute(sql)
        t.assert(result == nil)
        local message = [[Failed to execute SQL statement: ]]..
                        [[ESCAPE expression must be a single character]]
        t.assert_equals(err.message, message)

        result = box.execute([[SELECT '' LIKE '' ESCAPE '#' || '';]])
        t.assert_equals(result.rows, {{true}})
    end)
end
