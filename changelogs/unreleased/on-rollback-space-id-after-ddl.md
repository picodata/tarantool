## bugfix/box

* Fixed a use after free in the iterator of an `on_rollback` trigger. It
  occurred when the transaction renamed or created a space and changed it
  after that.
