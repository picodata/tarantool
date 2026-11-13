## bugfix/box

* A yield inside a `before_replace` or `on_replace` trigger of a memtx
  transaction without MVCC now stops the instance with a panic. This
  includes a start of a new fiber, for example with `fiber.create()`.
  Before, the yield aborted the transaction, and the trigger and the
  statement could then use freed memory. A yield outside of these
  triggers aborts the transaction as before.
* DDL from a `before_replace` trigger now fails with the error "Space
  trigger does not support DDL operations", as DDL from an `on_replace`
  trigger already did. Before, DDL on the space of the trigger could lose
  the row of the statement without an error. The error for an
  `on_replace` trigger now has the same text.
