## feature/sql

- `UNNEST` takes several arrays: `UNNEST([1, 2], ['a'])` gives the columns
  `VALUE_1` and `VALUE_2` with the elements at the same position, and SQL
  `NULL` for an array that has no element there, as in PostgreSQL.
