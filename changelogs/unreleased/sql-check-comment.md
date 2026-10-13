## bugfix/sql

* Fixed a `CHECK` constraint that lost a part of its expression. If the
  expression had a line comment in the middle, the part after the comment was
  ignored, and the constraint accepted rows that it must reject. A comment is
  now not kept in the stored text of a `CHECK` expression.
