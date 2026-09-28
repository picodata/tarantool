## bugfix/sql

* A correlated subquery with a window function, such as
  `(SELECT ALL sum(b) OVER () FROM t2 WHERE t2.a = t1.a LIMIT 1)`, is now
  computed for each row of the outer query rather than only once.
