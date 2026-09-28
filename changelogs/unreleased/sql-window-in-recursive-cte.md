## bugfix/sql

* A window function in the recursive part of a recursive CTE is now rejected
  with `cannot use window functions in recursive queries` instead of being
  computed over a single row of the queue.
