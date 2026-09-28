## bugfix/sql

* An alias of a window function referenced from a subquery, as in
  `SELECT sum(b) OVER () AS s FROM t ORDER BY (SELECT s)`, is now reported as
  `misuse of aliased window function S`. The subquery used to read a value that
  was never computed, which failed an assertion in debug builds.
