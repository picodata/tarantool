## bugfix/sql

* A `DELETE` that finds its rows by the primary key no longer skips them when
  a subquery of its `WHERE` clause reads a materialized `FROM` subquery, as in
  `DELETE FROM t WHERE a IN (SELECT q.x FROM (SELECT b AS x FROM s LIMIT 5) AS
  q, s)`. An `UPDATE` that finds a row by a unique secondary index no longer
  skips it when its `WHERE` clause reads such a subquery either.
