## feature/sql

* Added the `TO_DATE(string, format)` SQL function. It parses the string as
  `datetime.parse()` does and gives the start of its day in the parsed time
  zone. An empty format, `'iso8601'` and `'rfc3339'` parse an ISO 8601 or
  RFC 3339 string, other formats use the directives of `strptime()`.
  An error message shows at most 32 bytes of each argument, cut at a UTF-8
  character boundary, and escapes control characters, `"` and `\` as
  `mp_snprint()` does.
