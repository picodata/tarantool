## bugfix/sql

* A materialized subquery now keeps its rows in the order of its query. They
  used to be sorted by their values, so a window function computed under
  `SELECT ALL`, as in `SELECT ALL sum(b) OVER (ORDER BY b, a) FROM t`, could
  see them in the wrong order.
