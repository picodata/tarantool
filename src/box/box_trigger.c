/*
 * Copyright 2010-2026, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "box_trigger.h"

#include "trigger.h"
#include "space.h"
#include "txn.h"

/* {{{ Generic trigger primitives */

void
box_trigger_create(struct trigger *trigger, trigger_f run,
		   void *data, trigger_f0 destroy)
{
	trigger_create(trigger, run, data, destroy);
}

void
box_trigger_add(struct rlist *list, struct trigger *trigger)
{
	trigger_add(list, trigger);
}

void
box_trigger_clear(struct trigger *trigger)
{
	trigger_clear(trigger);
}

/* }}} Generic trigger primitives */

/* {{{ Space trigger lists */

struct rlist *
box_space_on_replace(struct space *space)
{
	return &space->on_replace;
}

struct rlist *
box_space_before_replace(struct space *space)
{
	return &space->before_replace;
}

/* }}} Space trigger lists */

/* {{{ Transaction trigger lists */

struct rlist *
box_txn_on_commit(struct txn *txn)
{
	txn_init_triggers(txn);
	return &txn->on_commit;
}

struct rlist *
box_txn_on_rollback(struct txn *txn)
{
	txn_init_triggers(txn);
	return &txn->on_rollback;
}

struct rlist *
box_txn_on_wal_write(struct txn *txn)
{
	txn_init_triggers(txn);
	return &txn->on_wal_write;
}

/* }}} Transaction trigger lists */

/* {{{ Replace event accessors */

struct txn_stmt *
box_txn_current_stmt(struct txn *txn)
{
	return txn_current_stmt(txn);
}

struct tuple *
box_txn_stmt_old_tuple(struct txn_stmt *stmt)
{
	return stmt->old_tuple;
}

struct tuple *
box_txn_stmt_new_tuple(struct txn_stmt *stmt)
{
	return stmt->new_tuple;
}

/* }}} Replace event accessors */
