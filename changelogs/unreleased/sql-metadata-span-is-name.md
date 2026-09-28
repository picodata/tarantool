## feature/sql

* The `span` field of the full SQL metadata (`sql_full_metadata`) is now always
  the same as the column name: it is encoded as `nil` over IPROTO, which means
  the name, and shown as the name by `box.execute()` and `net.box`. It used to
  be the text of the expression of the column, which is not kept any more, as
  PostgreSQL does not report it either.
