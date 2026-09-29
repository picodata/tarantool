## bugfix/sql

* Empty table aliases (`SELECT * FROM t AS ""`) and CTE names
  (`WITH "" AS (...)`) are now rejected just like other empty identifiers.
