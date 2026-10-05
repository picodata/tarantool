## bugfix/sql

* `SUM` and `AVG` on integers cannot overflow now. The addition continues in
  decimal when the sum does not fit in an integer. These functions raised the
  error "integer is overflowed" before.
