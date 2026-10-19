## bugfix/datetime

* Fixed a crash on a datetime value with a time zone index that this version
  does not know, for example a value decoded from MsgPack. Such a value now
  works as a value with a fixed offset: it is printed with its offset, `%Z`
  and `tz` are empty, and `isdst` is false.
