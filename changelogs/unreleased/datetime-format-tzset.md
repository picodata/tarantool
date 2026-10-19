## bugfix/datetime

* `datetime:format()` no longer re-reads the local time zone of the process
  on every call. When `TZ` is not set, glibc checked `/etc/localtime` with a
  system call each time, and formatting was several times slower. The result
  of `format()` does not change: it takes the time zone from the datetime.
  Because of this, a new `TZ` set bypassing `os.setenv()` or a replaced
  `/etc/localtime` no longer reaches `datetime.now()`, `os.date()` and the
  log by chance after the next `format()`. Call `datetime.tz_reload()` or
  restart the process to apply it (glibc sees a replaced `/etc/localtime`
  only when `TZ` is not set).
