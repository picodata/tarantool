/*
 * Copyright 2010-2017, Tarantool AUTHORS, please see AUTHORS file.
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
#include "execute.h"

#include "assoc.h"
#include "bind.h"
#include "iproto_constants.h"
#include "sql/sqlInt.h"
#include "sql/sqlLimit.h"
#include "errcode.h"
#include "small/region.h"
#include "diag.h"
#include "sql.h"
#include "xrow.h"
#include "schema.h"
#include "port.h"
#include "tuple.h"
#include "box/lua/execute.h"
#include "box/sql_stmt_cache.h"
#include "session.h"
#include "rmean.h"
#include "box/sql/port.h"

const char *sql_info_key_strs[] = {
	"row_count",
	"autoincrement_ids",
};

/**
 * Convert sql row into a tuple and append to a port.
 * @param stmt Started prepared statement. At least one
 *        sql_step must be done.
 * @param region Runtime allocator for temporary objects.
 * @param port Port to store tuples.
 *
 * @retval  0 Success.
 * @retval -1 Memory error.
 */
static inline int
sql_row_to_port(struct sql_stmt *stmt, struct region *region, struct port *port)
{
	uint32_t size;
	size_t svp = region_used(region);
	char *pos = sql_stmt_result_to_msgpack(stmt, &size, region);
	struct tuple *tuple =
		tuple_new(box_tuple_format_default(), pos, pos + size);
	if (tuple == NULL)
		goto error;
	region_truncate(region, svp);
	return port_c_add_tuple(port, tuple);

error:
	region_truncate(region, svp);
	return -1;
}

static bool
sql_stmt_schema_version_is_valid(struct sql_stmt *stmt)
{
	return sql_stmt_schema_version(stmt) == stmt_cache_schema_version();
}

/**
 * Re-compile statement and refresh global prepared statement
 * cache with the newest value.
 */
static int
sql_reprepare(struct sql_stmt **stmt)
{
	const char *sql_str = sql_stmt_query_str(*stmt);
	struct sql_stmt *new_stmt;
	if (sql_stmt_compile(sql_str, strlen(sql_str), NULL,
			     &new_stmt, NULL) != 0)
		return -1;
	if (sql_stmt_cache_update(*stmt, new_stmt) != 0)
		return -1;
	*stmt = new_stmt;
	return 0;
}

/**
 * Find or create prepared statement by its SQL query.
 * If statement is outdated or not found in the statement
 * cache, it will be compiled and added to the cache. Also,
 * the statement ID will be added to the list of available
 * statements in the current session.
 *
 * @param sql SQL query.
 * @param len Length of the query.
 * @param stmt_id Pointer to store statement ID.
 * @param stmt Pointer to store statement.
 *
 * @retval  0 Success.
 * @retval -1 Error.
 */
static int
sql_stmt_find_or_create(const char *sql, int len,
			uint32_t *stmt_id, struct sql_stmt **stmt)
{
	uint32_t new_id = sql_stmt_calculate_id(sql, len);
	struct sql_stmt *new_stmt = sql_stmt_cache_find(new_id);
	rmean_collect(rmean_box, IPROTO_PREPARE, 1);
	if (new_stmt == NULL) {
		if (sql_stmt_compile(sql, len, NULL, &new_stmt, NULL) != 0)
			return -1;
		if (sql_stmt_cache_insert(new_stmt) != 0) {
			sql_stmt_finalize(new_stmt);
			return -1;
		}
	} else {
		if (!sql_stmt_schema_version_is_valid(new_stmt) &&
		    !sql_stmt_busy(new_stmt)) {
			if (sql_reprepare(&new_stmt) != 0)
				return -1;
		}
	}
	assert(new_stmt != NULL);
	/* Add id to the list of available statements in session. */
	if (!session_check_stmt_id(current_session(), new_id))
		session_add_stmt_id(current_session(), new_id);
	*stmt_id = new_id;
	*stmt = new_stmt;
	return 0;
}

/**
 * Find or create prepared statement by its SQL query.
 * Returns compiled statement into provided port.
 */
int
sql_prepare(const char *sql, int len, struct port *port)
{
	uint32_t stmt_id = 0;
	struct sql_stmt *stmt = NULL;
	if (sql_stmt_find_or_create(sql, len, &stmt_id, &stmt) != 0)
		return -1;
	enum sql_serialization_format format = sql_column_count(stmt) > 0 ?
					   DQL_PREPARE : DML_PREPARE;
	port_sql_create(port, stmt, format, false);

	return 0;
}

/**
 * Find or create prepared statement by its SQL query.
 * Returns compiled statement ID and session ID.
 */
int
sql_prepare_ext(const char *sql, int len, uint32_t *stmt_id, uint64_t *session_id)
{
	struct sql_stmt *stmt = NULL;
	if (sql_stmt_find_or_create(sql, len, stmt_id, &stmt) != 0)
		return -1;
	*session_id = current_session()->id;
	return 0;
}

int
sql_unprepare_ext(uint32_t stmt_id, uint64_t session_id)
{
	struct session *session = session_find(session_id);
	if (session == NULL) {
		diag_set(ClientError, ER_NO_SUCH_SESSION, session_id);
		return -1;
	}
	if (!session_check_stmt_id(session, stmt_id)) {
		diag_set(ClientError, ER_WRONG_QUERY_ID, stmt_id);
		return -1;
	}
	struct sql_stmt *stmt = sql_stmt_cache_find(stmt_id);
	if (stmt == NULL) {
		diag_set(ClientError, ER_WRONG_QUERY_ID, stmt_id);
		return -1;
	}
	if (sql_stmt_busy(stmt)) {
		diag_set(ClientError, ER_SQL_STATEMENT_BUSY, stmt_id);
		return -1;
	}
	session_remove_stmt_id(session, stmt_id);
	sql_stmt_unref(stmt_id);
	return 0;
}

/**
 * Deallocate prepared statement from current session:
 * remove its ID from session-local hash and unref entry
 * in global holder.
 */
int
sql_unprepare(uint32_t stmt_id)
{
	if (!session_check_stmt_id(current_session(), stmt_id)) {
		diag_set(ClientError, ER_WRONG_QUERY_ID, stmt_id);
		return -1;
	}
	session_remove_stmt_id(current_session(), stmt_id);
	sql_stmt_unref(stmt_id);
	return 0;
}

/**
 * Run prepared SQL statement's bytecode.
 *
 * This function uses region to allocate memory for temporary
 * objects. After this function, region will be in the same state
 * in which it was before this function.
 *
 * @param db SQL handle.
 * @param stmt Prepared statement.
 * @param port Port to store SQL response.
 * @param region Region to allocate temporary objects.
 *
 * @retval  0 Success.
 * @retval -1 Error.
 */
static inline int
sql_stmt_run_vdbe(struct sql_stmt *stmt, uint64_t vdbe_max_steps,
		  struct region *region, struct port *port)
{
	int rc, column_count = sql_column_count(stmt);
	rmean_collect(rmean_box, IPROTO_EXECUTE, 1);
	sql_set_vdbe_max_steps(stmt, vdbe_max_steps);
	if (column_count > 0) {
		/* Either ROW or DONE or ERROR. */
		while ((rc = sql_step(stmt)) == SQL_ROW) {
			if (sql_row_to_port(stmt, region, port) != 0)
				return -1;
		}
		assert(rc == SQL_DONE || rc != 0);
	} else {
		/* No rows. Either DONE or ERROR. */
		rc = sql_step(stmt);
		assert(rc != SQL_ROW && rc != 0);
	}
	if (rc != SQL_DONE)
		return -1;
	return 0;
}

static int
sql_stmt_execute(struct sql_stmt *stmt, const struct sql_bind *bind,
		 uint32_t bind_count, uint64_t vdbe_max_steps,
		 struct region *region, struct port *port)
{
	assert(stmt != NULL);
	if (!sql_stmt_schema_version_is_valid(stmt)) {
		if (sql_reprepare(&stmt) != 0) {
			diag_set(ClientError, ER_SQL_EXECUTE,
				 "statement reprepare failed");
			return -1;
		}
	}
	if (sql_stmt_busy(stmt)) {
		const char *sql_str = sql_stmt_query_str(stmt);
		return sql_prepare_and_execute(sql_str, strlen(sql_str), bind,
					       bind_count, vdbe_max_steps,
					       region, port);
	}
	/*
	 * Clear all set from previous execution cycle values to be bound and
	 * remove autoincrement IDs generated in that cycle.
	 */
	sql_unbind(stmt);
	if (sql_bind(stmt, bind, bind_count) != 0)
		return -1;
	sql_reset_autoinc_id_list(stmt);
	enum sql_serialization_format format = sql_column_count(stmt) > 0 ?
					       DQL_EXECUTE : DML_EXECUTE;
	port_sql_create(port, stmt, format, false);
	if (sql_stmt_run_vdbe(stmt, vdbe_max_steps, region, port) != 0) {
		port_destroy(port);
		sql_stmt_reset(stmt);
		sql_unbind(stmt);
		return -1;
	}
	sql_stmt_reset(stmt);
	sql_unbind(stmt);

	return 0;
}

int
sql_execute_prepared(uint32_t stmt_id, const struct sql_bind *bind,
		     uint32_t bind_count, uint64_t vdbe_max_steps,
		     struct region *region, struct port *port)
{
	if (!session_check_stmt_id(current_session(), stmt_id)) {
		diag_set(ClientError, ER_WRONG_QUERY_ID, stmt_id);
		return -1;
	}
	struct sql_stmt *stmt = sql_stmt_cache_find(stmt_id);
	return sql_stmt_execute(stmt, bind, bind_count, vdbe_max_steps,
				region, port);
}

int
sql_execute_prepared_ext(uint32_t stmt_id, const char *mp_params,
			 uint64_t vdbe_max_steps, struct obuf *out_buf)
{
	struct port port;
	struct sql_bind *bind = NULL;

	size_t region_svp = region_used(&fiber()->gc);

	int bind_count = sql_bind_list_decode(mp_params, &bind);
	if (bind_count < 0)
		goto cleanup;

	struct sql_stmt *stmt = sql_stmt_cache_find(stmt_id);
	if (stmt == NULL) {
		diag_set(ClientError, ER_WRONG_QUERY_ID, stmt_id);
		goto cleanup;
	}
	/*
	 * If the statement was prepared in some other session, we borrow
	 * it and add to the current session until execution is finished.
	 * It is required to prevent the statement from being removed out
	 * of the cache while the statement is being executed. Then the
	 * statement is removed out of the current session to restore the
	 * original session state.
	 */
	bool stmt_is_borrowed = false;
	if (!session_check_stmt_id(current_session(), stmt_id)) {
		session_add_stmt_id(current_session(), stmt_id);
		stmt_is_borrowed = true;
	}
	int rc = sql_stmt_execute(stmt, bind, (uint32_t)bind_count,
				  vdbe_max_steps, &fiber()->gc, &port);
	if (stmt_is_borrowed) {
		session_remove_stmt_id(current_session(), stmt_id);
		sql_stmt_unref(stmt_id);
	}
	if (rc != 0)
		goto cleanup;

	struct obuf_svp out_svp = obuf_create_svp(out_buf);
	if (port_dump_msgpack(&port, out_buf) != 0) {
		obuf_rollback_to_svp(out_buf, &out_svp);
		port_destroy(&port);
		goto cleanup;
	}

	port_destroy(&port);
	region_truncate(&fiber()->gc, region_svp);
	return 0;
cleanup:
	region_truncate(&fiber()->gc, region_svp);
	return -1;
}

int
sql_prepare_and_execute_ext(const char *sql, int len, const char *mp_params,
			    uint64_t vdbe_max_steps, struct obuf *out_buf)
{
	struct port port;
	struct sql_bind *bind = NULL;

	size_t region_svp = region_used(&fiber()->gc);

	int bind_count = sql_bind_list_decode(mp_params, &bind);
	if (bind_count < 0) {
		region_truncate(&fiber()->gc, region_svp);
		return -1;
	}

	if (sql_prepare_and_execute(sql, len, bind, (uint32_t)bind_count,
				    vdbe_max_steps, &fiber()->gc, &port) != 0) {
		region_truncate(&fiber()->gc, region_svp);
		return -1;
	}

	struct obuf_svp out_svp = obuf_create_svp(out_buf);
	if (port_dump_msgpack(&port, out_buf) != 0) {
		obuf_rollback_to_svp(out_buf, &out_svp);
		port_destroy(&port);
		region_truncate(&fiber()->gc, region_svp);
		return -1;
	}

	port_destroy(&port);
	region_truncate(&fiber()->gc, region_svp);
	return 0;
}

int
sql_prepare_and_execute(const char *sql, int len, const struct sql_bind *bind,
			uint32_t bind_count, uint64_t vdbe_max_steps,
			struct region *region, struct port *port)
{
	struct sql_stmt *stmt;
	if (sql_stmt_compile(sql, len, NULL, &stmt, NULL) != 0)
		return -1;
	assert(stmt != NULL);
	enum sql_serialization_format format = sql_column_count(stmt) > 0 ?
					   DQL_EXECUTE : DML_EXECUTE;
	port_sql_create(port, stmt, format, true);
	if (sql_bind(stmt, bind, bind_count) == 0 &&
		sql_stmt_run_vdbe(stmt, vdbe_max_steps, region, port) == 0)
		return 0;
	port_destroy(port);
	return -1;
}
