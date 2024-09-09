## feature/replication

* A new compat option `compat.replication_synchro_timeout` has been added.
  This option determines whether the `replication.synchro_timeout` option rolls
  back transactions. When set to 'new', transactions are not rolled back due to
  a timeout. In this mode `replication.synchro_timeout` is used to wait
  confirmation in promote/demote and gc-checkpointing. If 'old' is set, the
  behavior is no different from what it was before this patch appeared.
