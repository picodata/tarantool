## bugfix/datetime

* `datetime:format()` no longer reads past the end of a format that ends
  with `%` or with `%` and digits, for example `'%'` or `'%3'`. Such a format
  could add bytes from memory to the result.
