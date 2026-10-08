## feature/sql

* `EXPLAIN ANALYZE` has a new option, `runs`: `EXPLAIN (analyze {'runs': 10})
  ...`. It runs the statement this number of times, and the hits and the
  samples are the sums of all runs. An error in a run ends the runs. A run that
  stops at its `timeout` does not: the timeout is for each run. With
  `rollback_stmt` each run rolls back its changes, thus all runs start from the
  same data. Without it each run keeps its changes, thus after an error in a
  run the changes of the runs before it stay. To prevent this, use
  `rollback_stmt`, or make a savepoint in a transaction before the statement
  and roll back to it. The other fibers run between the runs, unless the
  statement is in a transaction that cannot yield.
