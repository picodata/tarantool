## feature/sql

- A term `ORDINALITY = expr` of a table function called `WITH ORDINALITY`
  finds its row without a full scan, so a join of two `UNNEST` calls on the
  ordinality reads each row once instead of rescanning the inner call.
