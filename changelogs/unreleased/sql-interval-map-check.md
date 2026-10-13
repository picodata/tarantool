## bugfix/sql

* A cast of a map to `INTERVAL` now gives an error if the map has a key that
  is not the name of a field of `INTERVAL`. Before, such a key was ignored, and
  the start of a name was accepted as the name: `CAST({'d': 1} AS INTERVAL)`
  gave one day. The same applies to the value of `adjust`, which is now
  case-sensitive too. A key repeated in the map is an error now as well.
