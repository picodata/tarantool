## bugfix/sql

* The columns of a table whose name contains a dot, such as `"t.1"`, can now be
  referred to through an aliased parenthesized join that contains the table.
