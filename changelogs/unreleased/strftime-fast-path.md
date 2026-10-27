## feature/datetime

* `datetime:format()` and SQL `TO_CHAR()` are several times faster for the
  common formats. The 2-digit fields such as `%Y`, `%m`, `%d`, `%H`, `%M`,
  `%S` and the literal characters of the format no longer go through
  `snprintf()`. The result does not change.
