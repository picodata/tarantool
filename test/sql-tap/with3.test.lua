#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(2)

-- At one point this would incorrectly report "circular reference: cte1".
test:do_catchsql_test(
    "with3-6.0",
    [[
        with
          cte1(x, y) AS ( select 1, 2, 3 ),
          cte2(z) as ( select 1 from cte1 )
        select * from cte2, cte1;
    ]], {
        1, "table CTE1 has 3 values for 2 columns"
    })

test:do_catchsql_test(
    "with3-6.1",
    [[
        with
          cte1(x, y) AS ( select 1, 2, 3 ),
          cte2(z) as ( select 1 from cte1 UNION ALL
                       SELECT z+1 FROM cte2 WHERE z<5)
        select * from cte2, cte1;
    ]], {
        1, "table CTE1 has 3 values for 2 columns"
    })

test:finish_test()
