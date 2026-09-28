## bugfix/sql

* An aggregate function now belongs to the query of the columns its argument
  refers to also when they are referred to from a subquery in the argument, as
  in PostgreSQL. So in `SELECT (SELECT sum((SELECT x FROM t2 WHERE x = a)))
  FROM t1`, where `a` is a column of `t1`, `sum()` adds up over the rows of
  `t1`; and `SELECT (SELECT sum(x + (SELECT y)) FROM bb) FROM aa` no longer
  fails an assertion in debug builds.
