#!/usr/bin/env tarantool

local test = require("sqltester")
local dec = require('decimal')
local dt = require('datetime')

-- Немного параноидальных тестов.
test:plan(81)
test.silent = true

test:do_execsql_test(
    "picodata-index-usage-1.0",
    [[
        drop table if exists t;
        create table t(id int primary key, dt datetime, dm decimal, db double);

        create index t_dt on t(dt);
        create index t_dm on t(dm);
        create index t_db on t(db);

        START TRANSACTION;
            insert into t values (1, cast ('2025-11-25T18:48:17+0300' as datetime), 1.0, 1.1);
            insert into t values (2, cast ('2025-11-25T18:49:17+0300' as datetime), 2.0, 2.0);
            insert into t values (3, cast ('2025-11-25T18:50:17+0300' as datetime), 3, 3.3);
        COMMIT;

        drop table if exists t_empty;
        create table t_empty(id int primary key, dt datetime, dm decimal);
        create index t_empty_dt on t_empty(dt);
        create index t_empty_dm on t_empty(dm);
    ]], {
    })

--- INT

test:do_execsql_test(
    "picodata-index-usage-1.1",
    [[
        select * from t;
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-1.2.1",
    [[
        select * from t where id = 1;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID=?) (~1 row)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.2.2",
    [[
        select * from t where id = 1;
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
    })

test:do_eqp_test(
    "picodata-index-usage-1.3.1",
    [[
        select * from t where id > 2 and id < 10;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID>? AND ID<?) (~16384 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.3.2",
    [[
        select * from t where id > 2 and id < 10;
    ]], {
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-1.4.1",
    [[
        select * from t where id = 1.1;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID=?) (~1 row)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.4.2",
    [[
        select * from t where id = 1.1;
    ]], {
    })

test:do_execsql_test(
    "picodata-index-usage-1.4.3",
    [[
        select * from t where id = 1.0;
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
    })

test:do_eqp_test(
    "picodata-index-usage-1.5.1",
    [[
        select * from t where id < 5.2;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.5.2",
    [[
        select * from t where id < 5.2;
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-1.6.1",
    [[
        select * from t where id > 2.5 and id < 12.3;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID>? AND ID<?) (~16384 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.6.2",
    [[
        select * from t where id > 2.5 and id < 12.3;
    ]], {
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-1.7.1",
    [[
        select * from t where id > cast (1 as int) and id < cast (2.3 as decimal);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID>? AND ID<?) (~16384 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.7.2",
    [[
        select * from t where id > cast (1 as int) and id < cast (2.3 as decimal);
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
    })

test:do_eqp_test(
    "picodata-index-usage-1.8.1",
    [[
        select * from t where id < cast (2.2 as double);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.8.2",
    [[
        select * from t where id < cast (2.2 as double);
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
    })

test:do_eqp_test(
    "picodata-index-usage-1.9.1",
    [[
        select * from t where id > cast (1.5 as decimal);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-1.9.2",
    [[
        select * from t where id > cast (1.5 as decimal);
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-1.10",
    [[
        select * from t where id < ?;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-1.11",
    [[
        select * from t where id < cast (? as int);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-1.12",
    [[
        select * from t where id < cast (? as double);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-1.13",
    [[
        select * from t where id < cast (? as decimal);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-1.14",
    [[
        select * from t where id < cast (? as unsigned);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING PRIMARY KEY (ID<?) (~262144 rows)" }
    })

-- pk index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-1.15.1",
    [[
        select * from t where id = '';
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

-- pk index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-1.15.2",
    [[
        select * from t where id < '';
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~983040 rows)" }
    })

-- XXX: this is the reason why we disabled indices for `id = ''` and such
test:do_catchsql_test(
    "picodata-index-usage-1.15.3",
    [[
        select * from t where id < '';
    ]], {
        1, "Type mismatch: can not convert string('') to number",
    })

--- DATETIME

test:do_eqp_test(
    "picodata-index-usage-2.1.0",
    [[
        select * from t where dt = now();
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT=?) (~10 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.1.2",
    [[
        select * from t where dt = cast ('2025-11-25T18:48:17+0300' as datetime);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT=?) (~10 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-2.1.3",
    [[
        select * from t where dt = cast ('2025-11-25T18:48:17+0300' as datetime);
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
    })

test:do_eqp_test(
    "picodata-index-usage-2.1.3",
    [[
        select * from t where dt < cast ('2025-11-25T18:48:17+0300' as datetime) + cast ({'min':2} as interval);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT<?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-2.1.4",
    [[
        select * from t where dt < cast ('2025-11-25T18:48:17+0300' as datetime) + cast ({'min':2} as interval);
    ]], {
        1, dt.parse("2025-11-25T18:48:17+0300"), dec.new("1.0"), 1.1,
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.2.1",
    [[
        select * from t where dt = '';
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

test:do_catchsql_test(
    "picodata-index-usage-2.2.2",
    [[
        select * from t where dt = '';
    ]], {
        1, "Type mismatch: can not convert string('') to datetime",
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.3",
    [[
        select * from t where dt = 22;
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.4",
    [[
        select * from t where dt < 25.2 or dt > 100;
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~983040 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.5",
    [[
        select * from t where dt = ?;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT=?) (~10 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.6",
    [[
        select * from t where dt > ? and dt < ?;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT>? AND DT<?) (~16384 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.7",
    [[
        select * from t where dt between cast (? as datetime) and cast (? as datetime);
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT>? AND DT<?) (~16384 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.8",
    [[
        select * from t where dt = cast (? as string);
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.9",
    [[
        select * from t where dt = cast (? as int);
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.10",
    [[
        select * from t where dt < cast (? as datetime) + ?;
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT<?) (~262144 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-2.11",
    [[
        select * from t where dt < cast (? as datetime) + cast (? as int);
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~983040 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.12",
    [[
        select * from t where dt = (select ?)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT=?) (~10 rows)" },
        { 0, 0, 0, "EXECUTE SCALAR SUBQUERY 1" }
    })

test:do_eqp_test(
    "picodata-index-usage-2.13",
    [[
        select * from t where dt < (select now() + ?)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DT (DT<?) (~262144 rows)" },
        { 0, 0, 0, "EXECUTE SCALAR SUBQUERY 1" }
    })

--- DECIMAL

test:do_execsql_test(
    "picodata-index-usage-3.1",
    [[
        select * from t where dm > 1
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-3.2",
    [[
        select * from t where dm > 1
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.3",
    [[
        select * from t where dm > ?
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.4",
    [[
        select * from t where dm > cast (? as int)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.5",
    [[
        select * from t where dm > cast (? as double)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.6",
    [[
        select * from t where dm > cast (? as decimal)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.7",
    [[
        select * from t where dm > cast (? as unsigned)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-3.8",
    [[
        select * from t where dm = ''
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-3.9.1",
    [[
        select * from t where dm > cast (1 as unsigned)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-3.9.2",
    [[
        select * from t where dm > cast (1 as unsigned)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-3.10.1",
    [[
        select * from t where dm > cast (1 as int)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-3.10.2",
    [[
        select * from t where dm > cast (1 as int)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-3.11.1",
    [[
        select * from t where dm > cast (1 as double)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-3.11.2",
    [[
        select * from t where dm > cast (1 as double)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_execsql_test(
    "picodata-index-usage-3.11.3",
    [[
        select * from t where dm >= cast (2 as double)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-3.12.1",
    [[
        select * from t where dm > cast (1 as decimal)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DM (DM>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-3.12.2",
    [[
        select * from t where dm > cast (1 as decimal)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_execsql_test(
    "picodata-index-usage-3.12.3",
    [[
        select * from t where dm >= cast (2 as decimal)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

--- DOUBLE

test:do_execsql_test(
    "picodata-index-usage-4.1",
    [[
        select * from t where db > 1.1
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-4.2",
    [[
        select * from t where db > 1.1
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.3",
    [[
        select * from t where db > ?
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.4",
    [[
        select * from t where db > cast (? as int)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.5",
    [[
        select * from t where db > cast (? as double)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.6",
    [[
        select * from t where db > cast (? as decimal)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.7",
    [[
        select * from t where db > cast (? as unsigned)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

-- index doesn't apply here
test:do_eqp_test(
    "picodata-index-usage-4.8",
    [[
        select * from t where db = ''
    ]], {
        { 0, 0, 0, "SCAN TABLE T (~262144 rows)" }
    })

test:do_eqp_test(
    "picodata-index-usage-4.9.1",
    [[
        select * from t where db >= cast (2 as unsigned)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-4.9.2",
    [[
        select * from t where db >= cast (2 as unsigned)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-4.10.1",
    [[
        select * from t where db >= cast (2 as int)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-4.10.2",
    [[
        select * from t where db >= cast (2 as int)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-4.11.1",
    [[
        select * from t where db > cast (1.1 as double)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-4.11.2",
    [[
        select * from t where db > cast (1.1 as double)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_execsql_test(
    "picodata-index-usage-4.11.3",
    [[
        select * from t where db >= cast (2 as double)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_eqp_test(
    "picodata-index-usage-4.12.1",
    [[
        select * from t where db > cast (1.1 as decimal)
    ]], {
        { 0, 0, 0, "SEARCH TABLE T USING COVERING INDEX T_DB (DB>?) (~262144 rows)" }
    })

test:do_execsql_test(
    "picodata-index-usage-4.12.2",
    [[
        select * from t where db > cast (1.1 as decimal)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:do_execsql_test(
    "picodata-index-usage-4.12.3",
    [[
        select * from t where db >= cast (2 as decimal)
    ]], {
        2, dt.parse("2025-11-25T18:49:17+0300"), dec.new("2.0"), 2.0,
        3, dt.parse("2025-11-25T18:50:17+0300"), dec.new("3"), 3.3,
    })

test:finish_test()
