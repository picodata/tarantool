## bugfix/sql

* An alias of a window function used as an argument of an aggregate or window
  function, as in `SELECT sum(a) OVER () AS s FROM t ORDER BY sum(s)`, is now
  reported as `misuse of aliased window function S`, instead of failing later
  with a misleading `misuse of aggregate: SUM()`.
