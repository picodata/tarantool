## bugfix/sql

* A FROM clause item in parentheses, as in `SELECT * FROM (t) AS w`, no longer
  loses what was given to the item inside. Its alias is kept when the
  parentheses have none of their own, so `FROM t2 JOIN (t1 AS u) ON u.x = p`
  resolves `u` now. Its `INDEXED BY` hint is followed rather than ignored, a
  hint naming a non-existent index is reported, a table function call is no
  longer taken for a table of the same name, and the item may not be scanned
  without `SEQSCAN` when `sql_seq_scan` is false.
