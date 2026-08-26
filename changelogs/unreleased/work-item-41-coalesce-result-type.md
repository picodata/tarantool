## bugfix/sql

* Fixed the result type of `COALESCE()` and `IFNULL()` expressions. It is now
  derived from the argument types, allowing the expressions to be passed to
  numeric functions such as `ABS()` (work item #41).
