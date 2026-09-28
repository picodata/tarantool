## bugfix/sql

* A common table expression can now be referenced from a subquery in a named
  window definition, as in `WITH c AS (...) SELECT sum(a) OVER w FROM t WINDOW
  w AS (PARTITION BY (SELECT x FROM c WHERE ...))`. It used to be reported as
  a missing space.
