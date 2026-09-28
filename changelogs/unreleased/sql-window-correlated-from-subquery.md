## bugfix/sql

* A subquery in the `FROM` clause of a correlated subquery that uses a window
  function is no longer resolved twice. This failed an assertion in debug
  builds when the subquery referred to the outer query, as in
  `SELECT (SELECT row_number() OVER () FROM (SELECT c FROM t1)) FROM t2`.
