## bugfix/sql

* A query with an `IN` subquery that refers to the outer query only from the
  `FILTER` of a window function, as in `t1_id IN (SELECT count(*) FILTER
  (WHERE t1_id = 3) OVER () FROM t3)`, no longer reads a table of the outer
  query before it is opened.
