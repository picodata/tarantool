## bugfix/sql

* `SUM` on an integer column now returns a decimal, as PostgreSQL does. It
  returned an integer. Thus a sum that was more than the signed 64-bit range
  came to the client as a negative number.
