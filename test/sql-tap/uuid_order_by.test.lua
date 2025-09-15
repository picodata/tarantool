#!/usr/bin/env tarantool
local build_path = os.getenv("BUILDDIR")
package.cpath = build_path..'/test/sql-tap/?.so;'..build_path..'/test/sql-tap/?.dylib;'..package.cpath

local uuid = require("uuid")
local test = require("sqltester")
test:plan(2)

test:do_execsql_test(
    "uuid-order-by-asc",
    [[
with q(x) as (
    values
        (cast ('44cbbc8e-9f7f-45b5-b075-111c04091840' as uuid)),
        (cast ('70d20d76-75ef-496b-a4a4-ac9fa9b74eb1' as uuid)),
        (cast ('424e1a4f-cd67-427c-91d9-275db9043963' as uuid)),
        (cast ('70d20d76-75ef-496b-a4a4-ac9fa9b74eb1' as uuid)),
        (cast ('414e1a4f-cd67-427c-91d9-275db9043963' as uuid)),
        (cast ('70d20d76-75ef-496b-a4a4-ac9fa9b74eb1' as uuid)),
        (cast ('70d20d76-75ef-496b-a4a4-ac9fa9b74eb1' as uuid))
)
select * from q order by x asc;
    ]], {
        uuid.fromstr("414e1a4f-cd67-427c-91d9-275db9043963"),
        uuid.fromstr("424e1a4f-cd67-427c-91d9-275db9043963"),
        uuid.fromstr("44cbbc8e-9f7f-45b5-b075-111c04091840"),
        uuid.fromstr("70d20d76-75ef-496b-a4a4-ac9fa9b74eb1"),
        uuid.fromstr("70d20d76-75ef-496b-a4a4-ac9fa9b74eb1"),
        uuid.fromstr("70d20d76-75ef-496b-a4a4-ac9fa9b74eb1"),
        uuid.fromstr("70d20d76-75ef-496b-a4a4-ac9fa9b74eb1"),
    })

test:do_execsql_test(
    "uuid-order-by-desc",
    [[
with q(x) as (
    values
        (cast ('44cbbc8e-9f7f-45b5-b075-111c04091840' as uuid)),
        (cast ('70d20d76-75ef-496b-a4a4-ac9fa9b74eb1' as uuid)),
        (cast ('414e1a4f-cd67-427c-91d9-275db9043963' as uuid)),
        (cast ('424e1a4f-cd67-427c-91d9-275db9043963' as uuid))
)
select * from q order by x desc;
    ]], {
        uuid.fromstr("70d20d76-75ef-496b-a4a4-ac9fa9b74eb1"),
        uuid.fromstr("44cbbc8e-9f7f-45b5-b075-111c04091840"),
        uuid.fromstr("424e1a4f-cd67-427c-91d9-275db9043963"),
        uuid.fromstr("414e1a4f-cd67-427c-91d9-275db9043963"),
    })

test:finish_test()
