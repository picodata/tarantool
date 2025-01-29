#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(1)

test:do_test(
    "select-param-having-1.1",
    function()
        local res = box.execute([[
            WITH q(a) AS (VALUES (1))
            SELECT AVG(a), ? AS c1
            FROM q
            HAVING 1 = AVG(a)
        ]], {100})
        local row = res.rows[1]
        return {row[1], row[2]}
    end, {
        1, 100
    })

test:finish_test()
