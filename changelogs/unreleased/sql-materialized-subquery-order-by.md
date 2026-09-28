## bugfix/sql

* A subquery with `ORDER BY` that is materialized rather than flattened, such
  as a CTE used twice or a query with a window function under `SELECT ALL`,
  now stores its rows correctly. It used to store them malformed, which failed
  an assertion in debug builds.
