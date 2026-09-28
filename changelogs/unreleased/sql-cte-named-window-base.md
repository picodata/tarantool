## bugfix/sql

* A window based on a named window, as in `OVER (w)`, no longer loses the
  clauses of the named window when it is used in a CTE.
