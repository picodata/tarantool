## feature/sql

* `INDEXED BY` can now use skip-scan to search later parts of a composite TREE
  index when leading parts, or a contiguous block after a fixed prefix, have
  no equality bounds. `EXPLAIN QUERY PLAN` marks those parts with `ANY(...)`.
  A ready index search takes precedence over a full scan of the named index;
  ordinary searches and skip-scan are compared by cost.
