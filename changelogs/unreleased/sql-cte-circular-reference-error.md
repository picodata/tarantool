## bugfix/sql

* An error in the definition of a common table expression referenced from
  another one is now reported as it is, rather than as a `circular reference`
  of the former.
