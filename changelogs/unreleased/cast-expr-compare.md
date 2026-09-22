## bugfix/sql

* Fixed aggregates whose arguments differ only in the type they cast to, such
  as `SUM(CAST(c AS INTEGER))` and `SUM(CAST(c AS DOUBLE))` in one query,
  sharing one result instead of being computed separately.
