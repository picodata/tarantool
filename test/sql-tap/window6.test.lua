#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(5)

test:execsql([[
    DROP TABLE IF EXISTS over;
    CREATE TABLE over(x INT PRIMARY KEY, over INT);
    DROP TABLE IF EXISTS "window";
    CREATE TABLE window(x INT PRIMARY KEY, window INT);
    INSERT INTO over VALUES(1, 2), (3, 4), (5, 6);
    INSERT INTO window VALUES(1, 2), (3, 4), (5, 6);
]])

test:do_execsql_test(
    "5.0",
    [[ SELECT sum(x) over FROM over ]], { 9 })

test:do_execsql_test(
    "5.1",
    [[ SELECT sum(x) over  over FROM over WINDOW over AS () ]],
    { 9, 9, 9 })

test:do_execsql_test(
    "5.2",
    [[
SELECT sum(over) over  over  over FROM over  over WINDOW over AS (ORDER BY over)
    ]], {
        2, 6, 12
    })

test:do_execsql_test(
    "5.3",
    [[
SELECT sum(over) over  over  over FROM over  over WINDOW over AS (ORDER BY over);
    ]], {
        2, 6, 12
    })

test:do_execsql_test(
    "5.4",
    [[
SELECT sum(window) OVER window  window FROM window  window  window  window AS (ORDER BY window);
    ]], {
        2, 6, 12
    })

test:finish_test()
