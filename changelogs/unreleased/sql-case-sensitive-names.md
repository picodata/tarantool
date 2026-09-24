## bugfix/sql

* A few names in SQL were still compared case-insensitively, so names
  differing only in case were mixed up. They are now compared exactly, like
  all the other names:
  - the table name qualifying a column of a parenthesized join, so `"t".*`
    in `SELECT "t".* FROM (("t" CROSS JOIN "T") AS s CROSS JOIN t2)` no
    longer takes in the columns of `"T"`;
  - the name of a recursive CTE, so a table `"C"` used in the CTE `"c"` is
    no longer taken for a reference to the CTE;
  - the `NEW` and `OLD` rows in a trigger body, so `"new".a` and `"Old".a`
    no longer refer to them. Unquoted `new` and `old` are still fine;
  - window names, which are now also normalized like other names, so
    `OVER "W"` refers to `WINDOW w` and `OVER "w"` no longer refers to
    `WINDOW "W"`. Error messages show the normalized name;
  - function names, so a call to a user function `"abs"` is no longer
    matched with a call to `ABS` in `GROUP BY`, and a user aggregate `"max"`
    is no longer computed as the built-in `MAX`.
