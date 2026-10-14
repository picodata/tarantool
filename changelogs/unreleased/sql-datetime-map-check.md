## bugfix/sql

* A cast of a map to `DATETIME` now gives an error if the map has a key that
  is not the name of a field of `DATETIME` or a key repeated in the map.
  Before, such a key was ignored, and the start of a name was accepted as the
  name: `CAST({'d': 15} AS DATETIME)` gave the 15th day of the month, and
  `CAST({'': 2000} AS DATETIME)` gave the year 2000.
