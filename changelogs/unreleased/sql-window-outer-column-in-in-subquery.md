## bugfix/sql

* A query with an `IN` subquery that refers to the outer query only from the
  `PARTITION BY` or `ORDER BY` of a window, as in
  `t1_id IN (SELECT row_number() OVER (ORDER BY t1_id) FROM t3)`, no longer
  reads a table of the outer query before it is opened.
