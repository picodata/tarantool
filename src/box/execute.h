#ifndef TARANTOOL_SQL_EXECUTE_H_INCLUDED
#define TARANTOOL_SQL_EXECUTE_H_INCLUDED
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

#include <stdint.h>
#include <stdbool.h>
#include "port.h"

#if defined(__cplusplus)
extern "C" {
#endif

/** Keys of IPROTO_SQL_INFO map. */
enum sql_info_key {
	SQL_INFO_ROW_COUNT = 0,
	SQL_INFO_AUTOINCREMENT_IDS = 1,
	sql_info_key_MAX,
};

extern const char *sql_info_key_strs[];

struct region;
struct sql_bind;
struct sql_stmt;

int
sql_unprepare(uint32_t stmt_id);

/**
 * Execute prepared query (exported version).
 * @param stmt_id prepared statement ID.
 * @param mp_params MessagePack array of parameters.
 * @param vdbe_max_steps Maximum number of VDBE instructions to execute.
 * @param[out] out_buf Output buffer for SQL response.
 *
 * @retval  0 Success.
 * @retval -1 Error.
 */
int
sql_execute_prepared_ext(uint32_t stmt_id, const char *mp_params,
			 uint64_t vdbe_max_steps, struct obuf *out_buf);

int
sql_execute_prepared(uint32_t query_id, const struct sql_bind *bind,
		     uint32_t bind_count, uint64_t vdbe_max_steps,
		     struct region *region, struct port *port);

/**
 * Prepare and execute an SQL statement (exported version).
 * @param sql SQL text.
 * @param len Length of the SQL text.
 * @param mp_params MessagePack array of parameters.
 * @param vdbe_max_steps Maximum number of VDBE instructions to execute.
 * @param[out] out_buf Output buffer for SQL response.
 */
int
sql_prepare_and_execute_ext(const char *sql, int len, const char *mp_params,
			    uint64_t vdbe_max_steps, struct obuf *out_buf);

/**
 * Prepare and execute an SQL statement.
 * @param sql SQL statement.
 * @param len Length of @a sql.
 * @param bind Array of parameters.
 * @param bind_count Length of @a bind.
 * @param vdbe_max_steps Maximum number of VDBE instructions to execute.
 * @param region Runtime allocator for temporary objects
 *        (columns, tuples ...).
 * @param[out] port Port to store SQL response.
 *
 * @retval  0 Success.
 * @retval -1 Client or memory error.
 */
int
sql_prepare_and_execute(const char *sql, int len, const struct sql_bind *bind,
			uint32_t bind_count, uint64_t vdbe_max_steps,
			struct region *region, struct port *port);

int
sql_stmt_finalize(struct sql_stmt *stmt);

/**
 * Calculate estimated size of memory occupied by VM.
 * See sqlVdbeMakeReady() for details concerning allocated
 * memory.
 */
size_t
sql_stmt_est_size(const struct sql_stmt *stmt);

/**
 * Return string of SQL query.
 */
const char *
sql_stmt_query_str(const struct sql_stmt *stmt);

/** Return true if statement executes right now. */
int
sql_stmt_busy(const struct sql_stmt *stmt);

/**
 * Prepare (compile into VDBE byte-code) statement.
 *
 * @param sql UTF-8 encoded SQL query.
 * @param len Length of @param sql in bytes.
 * @param port Port to store request response.
 */
int
sql_prepare(const char *sql, int len, struct port *port);

/**
 * Unprepare statement from the session (exported version).
 *
 * @param stmt_id ID of prepared stmt.
 * @param sid session ID.
 */
int
sql_unprepare_ext(uint32_t stmt_id, uint64_t sid);

/**
 * Prepare statement (exported version).
 *
 * @param sql UTF-8 encoded SQL query.
 * @param len Length of @param sql in bytes.
 * @param[out] stmt_id Prepared statement ID.
 * @param[out] session_id session ID.
 */
int
sql_prepare_ext(const char *sql, int len, uint32_t *stmt_id,
		uint64_t *session_id);

#if defined(__cplusplus)
} /* extern "C" { */
#endif

#endif /* TARANTOOL_SQL_EXECUTE_H_INCLUDED */
