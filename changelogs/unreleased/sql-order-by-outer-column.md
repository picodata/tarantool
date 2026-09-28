## feature/sql

* The `ORDER BY` and `GROUP BY` clauses of a subquery can now refer to columns
  of an outer query, as in `SELECT (SELECT c FROM t2 ORDER BY abs(c - a)
  LIMIT 1) FROM t1`.
