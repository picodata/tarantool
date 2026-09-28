## bugfix/sql

* Fixed a crash on a window function in the `ORDER BY` clause of a subquery
  whose ordering does not matter, as in
  `SELECT EXISTS (SELECT a FROM t ORDER BY sum(a) OVER ())`.
