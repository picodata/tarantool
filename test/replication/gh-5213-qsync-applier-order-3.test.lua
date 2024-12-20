--
-- gh-5213: applier used to process CONFIRM/ROLLBACK before writing them to WAL.
-- As a result it could happen that the transactions became visible on CONFIRM,
-- then somehow weren't written to WAL, and on restart the data might not be
-- visible again. Which means rollback of confirmed data and is not acceptable
-- (on the contrary with commit after rollback).
--
-- To fix that there was a patch making synchro rows processing after WAL write.
-- As a result, the following situation could happen. Instance 1 owns the limbo,
-- instances 2 and 3 know about that. The limbo is not empty. Now instance 1
-- writes CONFIRM and sends it to the instances 2 and 3. Both start a WAL write
-- for the CONFIRM. Now instance 3 finishes it, creates a new synchro
-- transaction, owns the local limbo, and sends the transaction to the instance
-- 2. Here the CONFIRM WAL write is not done yet. It should not happen, that
-- the instance 3's new transaction is rejected. Because firstly instance 3 will
-- send the same instance 1's CONFIRM to the instance 2 due to it being earlier
-- in WAL of instance 3. Then on instance 2 it will block on a latch with
-- replica_id 1 until the original CONFIRM received from the instance 1 is
-- finished. Afterwards the instance 3's transaction is applied just fine - the
-- limbo on instance 2 is empty now.
--
-- It is not related to read-views, but could break the replication.
--
test_run = require('test_run').new()
fiber = require('fiber')
old_synchro_quorum = box.cfg.replication_synchro_quorum
old_synchro_timeout = box.cfg.replication_synchro_timeout

box.schema.user.grant('guest', 'super')

s = box.schema.space.create('test', {is_sync = true})
_ = s:create_index('pk')
box.ctl.promote(); box.ctl.wait_rw()

test_run:cmd('create server replica1 with rpl_master=default,\
              script="replication/replica1.lua"')
test_run:cmd('start server replica1')

test_run:cmd('create server replica2 with rpl_master=default,\
              script="replication/replica2.lua"')
test_run:cmd('start server replica2')

-- Build mutual replication between replica1 and replica2.
test_run:switch('replica1')
replication = box.cfg.replication
table.insert(replication, test_run:eval('replica2', 'return box.cfg.listen')[1])
box.cfg{replication = {}}
box.cfg{replication = replication}

test_run:switch('replica2')
replication = box.cfg.replication
table.insert(replication, test_run:eval('replica1', 'return box.cfg.listen')[1])
box.cfg{replication = {}}
box.cfg{replication = replication}

test_run:switch('default')
fiber = require('fiber')
box.cfg{                                                                        \
    replication_synchro_quorum = 4,                                             \
    replication_synchro_timeout = 1000,                                         \
}
-- Send a transaction to all 3 nodes. The limbo is owned by the default node
-- everywhere.
f = fiber.new(function() s:replace{1} end)
test_run:wait_lsn('replica1', 'default')
test_run:wait_lsn('replica2', 'default')

-- Make so the replica1 will apply CONFIRM from the default instance for a long
-- time.
test_run:switch('replica1')
box.error.injection.set('ERRINJ_WAL_DELAY_COUNTDOWN', 0)

-- Emit the CONFIRM.
test_run:switch('default')
box.cfg{replication_synchro_quorum = 3}
test_run:wait_cond(function() return f:status() == 'dead' end)

-- It hangs on the replica1.
test_run:switch('replica1')
test_run:wait_cond(function()                                                   \
    return box.error.injection.get('ERRINJ_WAL_DELAY')                          \
end)

-- But is applied on the replica2. The limbo is empty here now.
test_run:switch('replica2')
test_run:wait_lsn('replica2', 'default')
box.cfg{                                                                        \
    replication_synchro_quorum = 1,                                             \
    replication_synchro_timeout = 1000,                                         \
}
-- Replica2 takes the limbo ownership and sends the transaction to the replica1.
-- Along with the CONFIRM from the default node, which is still not applied
-- on the replica1.
box.ctl.promote(); box.ctl.wait_rw()
box.info.id == box.info.synchro.queue.owner -- promote should've been applied
box.cfg{replication_synchro_quorum = 2}
fiber = require('fiber')
f = fiber.new(function() box.space.test:replace{2} end)

test_run:switch('replica1')
fiber = require('fiber')
-- WAL write of the CONFIRM from the default node still is not done. Give it
-- some time to get the new rows from the replica2 and block on the latch.
-- Can't catch it anyhow via conds, so the only way is to sleep a bit.
fiber.sleep(0.1)
-- Let the WAL writes finish. Firstly CONFIRM is finished, the limbo is emptied
-- and the replica_id 1 latch is unlocked. Now the replica2 transaction is
-- applied and persisted.
box.error.injection.set('ERRINJ_WAL_DELAY', false)
test_run:wait_lsn('replica1', 'replica2')
box.space.test:get({2})

-- Ensure the replication works fine, nothing is broken.
test_run:wait_upstream(test_run:get_server_id('replica2'), {status = 'follow'})

test_run:switch('replica2')
test_run:wait_upstream(test_run:get_server_id('replica1'), {status = 'follow'})

test_run:switch('default')
test_run:cmd('stop server replica1')
test_run:cmd('delete server replica1')
test_run:cmd('stop server replica2')
test_run:cmd('delete server replica2')
-- Restore leadership to make the default instance writable.
box.cfg{replication_synchro_quorum = 1}
box.ctl.promote(); box.ctl.wait_rw()
s:drop()
box.schema.user.revoke('guest', 'super')
box.cfg{                                                                        \
    replication_synchro_quorum = old_synchro_quorum,                            \
    replication_synchro_timeout = old_synchro_timeout,                          \
}
box.ctl.demote()
