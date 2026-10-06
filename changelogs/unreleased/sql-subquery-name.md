## bugfix/sql

* **[Breaking change]** A subquery in `FROM` without an alias had a memory
  address in its name, for example `subquery_7F3D9603A038`, and the full name
  of its result columns showed it. Now the name is the number of the subquery
  in the statement: `(subquery:1).COLUMN_1`.
