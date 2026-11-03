## bugfix/replication

* Fixed an assertion failure when the initial `box.cfg` replication
  connection failed the quorum: the instance crashed with
  `applier_pause(): Assertion 'fiber() == applier->fiber' failed` instead
  of exiting with a configuration error (gh-8675).
