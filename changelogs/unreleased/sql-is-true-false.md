## feature/sql

* Added the `IS [NOT] TRUE` and `IS [NOT] FALSE` predicates. Unlike
  comparison with `=`, they never return NULL: `NULL IS TRUE` is FALSE.
