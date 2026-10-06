#pragma once
/*
 * Copyright 2010-2026, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <stdbool.h>
#include <stdint.h>

#include "box/field_def.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct ExprList;

/** Static SQL table function callbacks. */
struct sql_table_func_ops {
	/** Resolve this call's fields from the argument expressions. */
	int (*resolve_schema)(struct ExprList *args, struct field_def *fields);
	/** Estimate rows without evaluating argument expressions. */
	uint64_t (*estimate_rows)(struct ExprList *args);
	/**
	 * Open an iterator over trusted SQL arguments encoded as a MsgPack
	 * array. The cursor owns these bytes until close. On error, release
	 * partial state and leave *ctx NULL; close is called only on success.
	 */
	int (*open)(const char *args, const char *args_end, void **ctx);
	/**
	 * Return next row as a MsgPack array, or NULL row at EOF.
	 *
	 * The row must be a valid MsgPack array matching the function result
	 * fields. The buffer must live until the next next/close call. VDBE
	 * copies the row and reports incompatible field values as SQL errors.
	 * JSON values must remain normalized (doc/json-perimeter.md).
	 */
	int (*next)(void *ctx, const char **row, const char **row_end);
	/** Close an iterator context returned by open. */
	void (*close)(void *ctx);
};

/** Per-call result schema owned by the VDBE instruction. */
struct sql_table_func_call {
	/** Shared definition in the immutable registry. */
	const struct sql_table_func_def *func;
	/** Number of output fields, including optional ordinality. */
	uint32_t field_count;
	/** True if the cursor appends an ordinality column. */
	bool has_ordinality;
	/** Names point into the immutable registry. */
	struct field_def fields[];
};

/** Static SQL table function descriptor. */
struct sql_table_func_def {
	/** SQL-visible function name. */
	const char *name;
	/** Exact argument count, or -1 for a variadic function. */
	int param_count;
	/**
	 * Types of the arguments, or NULL. With the types, the arguments get
	 * the type check and the implicit cast of a built-in scalar function
	 * before the iterator opens. The argument count must be exact.
	 */
	const enum field_type *param_types;
	/** Result column definitions. */
	const struct field_def *fields;
	/** Number of result columns. */
	uint32_t field_count;
	/** Iterator callbacks. */
	const struct sql_table_func_ops *ops;
};

/**
 * Register statically linked SQL table functions.
 *
 * The descriptors and their field definitions must outlive SQL statements.
 * Registration is expected during bootstrap, before SQL statements are
 * prepared.
 */
int
sql_table_func_register(const struct sql_table_func_def *defs, uint32_t count);

/** Find a registered SQL table function by name. */
const struct sql_table_func_def *
sql_table_func_find(const char *name, uint32_t name_len, bool is_runtime);

/**
 * Check that the arguments of a call can have the types that the function
 * accepts. Set the diagnostics area and return -1 if they cannot.
 */
int
sql_table_func_check_arg_types(const struct sql_table_func_def *func,
			       struct ExprList *args);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
