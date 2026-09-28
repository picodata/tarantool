## bugfix/sql

* A window function whose argument is an aggregate in a query without
  `GROUP BY`, as in `SELECT sum(sum(a)) OVER () FROM t`, no longer fails with
  `misuse of aggregate`.
