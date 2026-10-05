## bugfix/sql

* `AVG` on an integer column now returns a decimal, as PostgreSQL does. It
  returned an integer and truncated the result: the average of 1 and 2 was 1.
