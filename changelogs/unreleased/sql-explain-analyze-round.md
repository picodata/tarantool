## feature/sql

* `EXPLAIN ANALYZE` has a new option, `round`: `EXPLAIN (analyze {'round':
  false}) ...`. By default it is `true`, and the measurements are short texts
  that are rounded down, for example `12.3k`. With `false`, the measurements
  are exact integers, and their columns have the type `integer`.
