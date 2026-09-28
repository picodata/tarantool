## bugfix/sql

* Two items of a `FROM` clause visible under the same table name, as in
  `SELECT * FROM t, (SELECT 1) AS t` or `WITH q AS (...) SELECT * FROM q, q`,
  are now rejected. Just like in PostgreSQL, this is reported as a table name
  specified more than once, whether or not a column is referenced by it.
