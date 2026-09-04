## bugfix/sql

* Fixed type inference for `COALESCE()` and `IFNULL()` expressions. The type
  used for planning and result metadata is derived from the argument types,
  allowing the expressions to be passed to numeric functions such as `ABS()`.
  At runtime, the selected value retains its own type without conversion to
  the inferred common type. In particular, bound values are not marked as
  `ANY` merely because their types were unknown during planning (work item #41).
