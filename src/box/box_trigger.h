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
#pragma once

#include "trivia/util.h"
#include "trigger.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct space;
struct txn;
struct txn_stmt;
struct tuple;

/* {{{ Generic trigger primitives */

/**
 * Generic trigger primitives exported for foreign callers, e.g.
 * the Rust connector. Tarantool's trigger_create() and
 * trigger_add() are static inline and thus not linkable; these
 * thin wrappers expose the same primitives behind the
 * conventional box_ prefix, so that external code can build its
 * own trigger handlers without a bespoke binding layer.
 *
 * The struct trigger is owned by the caller. box_trigger_clear()
 * only unlinks it from its list, it neither frees the trigger nor
 * runs its destroy callback.
 */

/**
 * Initialize a trigger.
 * \sa trigger_create()
 */
API_EXPORT void
box_trigger_create(struct trigger *trigger, trigger_f run,
		   void *data, trigger_f0 destroy);

/**
 * Add a trigger to a trigger list. The most recently added
 * trigger runs first, so the trigger added first runs last.
 * \sa trigger_add()
 */
API_EXPORT void
box_trigger_add(struct rlist *list, struct trigger *trigger);

/**
 * Remove a trigger from whatever list it is on.
 * \sa trigger_clear()
 */
API_EXPORT void
box_trigger_clear(struct trigger *trigger);

/* }}} Generic trigger primitives */

/* {{{ Space trigger lists */

/**
 * Return a space's on_replace trigger list. The list is run with
 * the current transaction as the event; use box_txn_current_stmt()
 * inside the handler to reach the tuple being replaced.
 */
API_EXPORT struct rlist *
box_space_on_replace(struct space *space);

/**
 * Return a space's before_replace trigger list.
 * See box_space_on_replace().
 */
API_EXPORT struct rlist *
box_space_before_replace(struct space *space);

/* }}} Space trigger lists */

/* {{{ Transaction trigger lists */

/*
 * The transaction trigger lists are created lazily, so these
 * accessors initialize them on first use before returning a
 * pointer suitable for box_trigger_add().
 */

/** Return the transaction's on_commit trigger list. */
API_EXPORT struct rlist *
box_txn_on_commit(struct txn *txn);

/** Return the transaction's on_rollback trigger list. */
API_EXPORT struct rlist *
box_txn_on_rollback(struct txn *txn);

/** Return the transaction's on_wal_write trigger list. */
API_EXPORT struct rlist *
box_txn_on_wal_write(struct txn *txn);

/* }}} Transaction trigger lists */

/* {{{ Replace event accessors */

/**
 * The statement a space replace trigger fires for. Returns NULL
 * outside of a sub-statement.
 */
API_EXPORT struct txn_stmt *
box_txn_current_stmt(struct txn *txn);

/** The tuple before the change, or NULL for a pure insert. */
API_EXPORT struct tuple *
box_txn_stmt_old_tuple(struct txn_stmt *stmt);

/** The tuple after the change, or NULL for a delete. */
API_EXPORT struct tuple *
box_txn_stmt_new_tuple(struct txn_stmt *stmt);

/* }}} Replace event accessors */

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
