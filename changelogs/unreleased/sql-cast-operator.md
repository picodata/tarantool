## feature/sql

* Added the PostgreSQL-style cast operator: `expr::type` is the same as
  `CAST(expr AS type)`. The operator binds tighter than all other operators,
  so `-a::INT` is `-(a::INT)`. A named parameter that follows the colon of a
  map literal now needs a space before it: `{5: :name}`, not `{5::name}`.
