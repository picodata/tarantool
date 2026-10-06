## feature/sql

* Added `EXPLAIN ANALYZE`. It runs the statement, drops its rows, and then
  shows the VDBE program as `EXPLAIN` does, with a first column that tells
  where the time went. By default the column is `samples`: the number of
  samples that found each instruction running, at 99 samples in a second of CPU
  time. The facet form takes options: `EXPLAIN (analyze {'mode': ['hits',
  'samples'], 'freq': 500}) ...`. The mode `hits` shows the column `hits`, the
  number of times each instruction ran, and `samples` shows the samples. The
  mode is one value or a list of values, `all` is all the modes, and `EXPLAIN
  (analyze ['hits', 'samples']) ...` is the short form of the list. The option
  `freq` is the number of samples in a second, from 1 to 1000. If the samples
  cannot start, for example in a build that cannot sample or when the process
  is at its limit of timers, the statement fails and does not run: use the mode
  `hits` then. The statement keeps its changes. `EXPLAIN ANALYZE` does not take
  the statements that control the transaction or the session (`START
  TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, `ROLLBACK TO`,
  `SET SESSION`) and the statements that change the schema (`CREATE`, `DROP`,
  `ALTER`). It takes `TRUNCATE`.
