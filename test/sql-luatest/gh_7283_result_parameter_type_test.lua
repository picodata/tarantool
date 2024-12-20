local server = require('luatest.server')
local t = require('luatest')
local g = t.group()

g.before_all(function()
    g.server = server:new({alias = 'result_parameter_type'})
    g.server:start()
end)

g.after_all(function()
    g.server:stop()
end)

g.test_result_parameter_type_1 = function()
    g.server:exec(function()
        local t = require('luatest')
        box.execute([[CREATE TABLE t1(a INT PRIMARY KEY);]])
        local q = box.prepare([[SELECT COLUMN_1 FROM t1 JOIN (VALUES (?)) AS t2 ON true]])
        local res, _ = q:execute()
        t.assert_equals(res.metadata[1].type, 'any')
        box.execute([[DROP TABLE t1;]])
    end)
end
