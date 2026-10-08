## feature/sql

* `EXPLAIN ANALYZE` has a new option, `rollback_stmt`: `EXPLAIN (analyze
  {'rollback_stmt': true}) ...`. With `true`, the statement never keeps its
  changes: it rolls back its transaction, or its savepoint if it runs in a
  transaction of the user. This is also for a run that stops at its `timeout`
  and for a run that ends with an error. Thus in a transaction of the user
  `INSERT OR ROLLBACK` with this option does not roll back the transaction
  after a conflict, as it does without the option: it rolls back only its own
  changes. The default is `false`.
