## feature/sql

* `EXPLAIN ANALYZE` has a new mode, `wait_samples`: `EXPLAIN (analyze {'mode':
  ['samples', 'wait_samples']}) ...`. Its column, `wait_samples`, is the number
  of samples that found the statement in an instruction while the statement
  did not use the CPU, for example in a disk read of vinyl or in the commit.
  The samples are taken 99 times in a second of real time, or as the option
  `freq` says, thus `wait_samples` and `samples` compare directly. The mode
  `all` includes it.
