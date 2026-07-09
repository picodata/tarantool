## feature/sql

* Subscripting a NULL array or map with the `[]` operator now yields NULL instead of raising
  `Selecting is not possible from NULL`. A bare untyped `NULL[1]` is still rejected.
