## bugfix/sql

* Fixed a crash on an expression with a very long chain of `COLLATE` clauses.
  Such an expression now gives the error about the depth of the expression
  tree, as other deep expressions do.
