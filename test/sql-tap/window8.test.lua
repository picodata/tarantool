#!/usr/bin/env tarantool
local test = require("sqltester")
test:plan(5)

-- "map" is a keyword in Tarantool, so the table is called "tmap".
test:do_execsql_test(
    "window8-8.0",
    [[
        DROP TABLE IF EXISTS tx;
        CREATE TABLE tx(a INTEGER PRIMARY KEY);
        INSERT INTO tx VALUES(1), (2), (3), (4), (5), (6);

        DROP TABLE IF EXISTS tmap;
        CREATE TABLE tmap(v INTEGER PRIMARY KEY, t TEXT);
        INSERT INTO tmap VALUES
          (1, 'odd'), (2, 'even'), (3, 'odd'),
          (4, 'even'), (5, 'odd'), (6, 'even');
    ]], {
        -- <window8-8.0>
        -- </window8-8.0>
    })

test:do_execsql_test(
    "window8-8.1",
    [[
        SELECT sum(a) OVER (
          PARTITION BY (
            SELECT t FROM tmap WHERE v=a
          ) ORDER BY a
        ) FROM tx;
    ]], {
        -- <window8-8.1>
        2, 6, 12, 1, 4, 9
        -- </window8-8.1>
    })

test:do_execsql_test(
    "window8-8.2",
    [[
        SELECT sum(a) OVER win FROM tx
        WINDOW win AS (
          PARTITION BY (
            SELECT t FROM tmap WHERE v=a
          ) ORDER BY a
        );
    ]], {
        -- <window8-8.2>
        2, 6, 12, 1, 4, 9
        -- </window8-8.2>
    })

test:do_execsql_test(
    "window8-8.3",
    [[
        WITH tmap2 AS (
          SELECT * FROM tmap
        )
        SELECT sum(a) OVER (
          PARTITION BY (
            SELECT t FROM tmap2 WHERE v=a
          ) ORDER BY a
        ) FROM tx;
    ]], {
        -- <window8-8.3>
        2, 6, 12, 1, 4, 9
        -- </window8-8.3>
    })

-- A CTE referenced from a subquery in a named window definition.
test:do_execsql_test(
    "window8-8.4",
    [[
        WITH tmap2 AS (
          SELECT * FROM tmap
        )
        SELECT sum(a) OVER win FROM tx
        WINDOW win AS (
          PARTITION BY (
            SELECT t FROM tmap2 WHERE v=a
          ) ORDER BY a
        );
    ]], {
        -- <window8-8.4>
        2, 6, 12, 1, 4, 9
        -- </window8-8.4>
    })

test:finish_test()
