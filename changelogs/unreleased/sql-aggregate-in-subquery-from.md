## bugfix/sql

* An aggregate function in the `FROM` clause of a subquery of the query that
  it belongs to, as in `SELECT (SELECT y FROM (SELECT sum(x) AS y)) FROM t`,
  no longer fails with `misuse of aggregate`.
