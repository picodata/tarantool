## bugfix/sql

* Fixed a crash on `EXPLAIN`, `EXPLAIN QUERY PLAN` and `EXPLAIN ANALYZE` with
  the `sql_full_metadata` session setting on, for a query with a result column
  that is a column of a table or has a collation.
