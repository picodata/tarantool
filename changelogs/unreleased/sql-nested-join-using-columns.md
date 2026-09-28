## bugfix/sql

* The columns of a `USING` or `NATURAL` join in parentheses are now resolved
  as in PostgreSQL. The right-hand table's own copy of a join column can be
  referred to by its table's name, as `t2.x`, and `t2.*` returns all of the
  columns of `t2`, while `*` and `x` still take the join column once. Before,
  the right-hand copy was dropped, and the join column of several nested
  `USING` joins was reported as an ambiguous column. A column of a join in
  parentheses can now also be referred to by its table's name with
  `sql_full_column_names` enabled.
