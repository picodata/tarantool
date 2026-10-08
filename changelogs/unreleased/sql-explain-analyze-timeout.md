## feature/sql

* `EXPLAIN ANALYZE` has a new option, `timeout`: `EXPLAIN (analyze {'timeout':
  1.5}) ...`. It is the maximum time of the run in seconds, an integer or a
  number with a fraction. When the time is over, the run stops and `EXPLAIN
  ANALYZE` shows the hits and the samples of the part that ran. The statement
  keeps the changes that it made before the stop. A statement such as `INSERT
  ... SELECT` first collects all its rows and then writes them, thus a stop in
  the first part keeps nothing. The default, 0, is no limit.
