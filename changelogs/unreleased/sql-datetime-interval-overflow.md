## bugfix/sql

* Fixed a crash on the sum or the difference of `DATETIME` and `INTERVAL`
  values with a result that is out of the range of its type, such as
  `CAST('5879611-07-10T00:00:00Z' AS DATETIME) + CAST({'day': 7} AS INTERVAL)`.
  Such an operation now gives the error `datetime is overflowed` or
  `interval is overflowed`.
