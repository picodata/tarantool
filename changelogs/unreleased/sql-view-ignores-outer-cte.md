## bugfix/sql

* The names in a view no longer refer to the common table expressions of the
  statement that uses the view. So `WITH t(a) AS (...) SELECT * FROM v` now
  reads the space `t` where the view `v` does, not the CTE. It used to return
  the rows of the CTE, or fail to resolve a column.
