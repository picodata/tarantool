## feature/sql

* The last column of `EXPLAIN`, `comment`, is now `pseudocode`, and all builds
  fill it: before, it was `NULL` in a build that is not a debug build. It shows
  what each VDBE instruction does with the values of its operands, for example
  `r[2] = c[1].row().column('T.A')` or `IF r[2] <= r[3] THEN GOTO 9 END`, and
  after `#` the comment of the code generator. The column `p4` shows binary
  data as a hex literal, for example `x'FF00'`: before, it had the bytes of the
  data. A long text of MsgPack in `p4` is now cut on a character boundary.
