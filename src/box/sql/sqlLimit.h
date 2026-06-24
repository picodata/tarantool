#ifndef TARANTOOL_SQL_sqlLIMIT_H_INCLUDED
#define TARANTOOL_SQL_sqlLIMIT_H_INCLUDED
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

/*
 *
 * This file defines various limits of what sql can process.
 */
#include "core/decimal.h"
#include "tt_static.h"
#include <stdbool.h>
#include <stdint.h>

enum {
	/*
	 * The maximum value of a $nnn wildcard that the parser will accept.
	 */
	SQL_BIND_PARAMETER_MAX = 65000,
};

/*
 * The maximum length of a TEXT or BLOB in bytes.   This also
 * limits the size of a row in a table or index.
 *
 * The hard limit is the ability of a 32-bit signed integer
 * to count the size: 2^31-1 or 2147483647.
 */
#ifndef SQL_MAX_LENGTH
#define SQL_MAX_LENGTH 1000000000
#endif

/*
 * This is the maximum number of
 *
 *    * Columns in a table
 *    * Columns in an index
 *    * Columns in a view
 *    * Terms in the SET clause of an UPDATE statement
 *    * Terms in the result set of a SELECT statement
 *    * Terms in the GROUP BY or ORDER BY clauses of a SELECT statement.
 *    * Terms in the VALUES clause of an INSERT statement
 *
 * The hard upper limit here is 32676.  Most database people will
 * tell you that in a well-normalized database, you usually should
 * not have more than a dozen or so columns in any table.  And if
 * that is the case, there is no point in having more than a few
 * dozen values in any of the other situations described above.
 */
#ifndef SQL_MAX_COLUMN
#define SQL_MAX_COLUMN 2000
#endif
/*
 * tt_static_buf() is used to store bitmask for used columns in a table during
 * SQL parsing stage. The following statement checks if static buffer is big
 * enough to store the bitmask.
 */
#if SQL_MAX_COLUMN > TT_STATIC_BUF_LEN * 8
#error "Bitmask for used table columns cannot fit into static buffer"
#endif

/*
 * The maximum length of a single SQL statement in bytes.
 *
 * It used to be the case that setting this value to zero would
 * turn the limit off.  That is no longer true.  It is not possible
 * to turn this limit off.
 */
#ifndef SQL_MAX_SQL_LENGTH
#define SQL_MAX_SQL_LENGTH 1000000000
#endif

/*
 * The maximum depth of an expression tree. This is limited to
 * some extent by sql_MAX_SQL_LENGTH. But sometime you might
 * want to place more severe limits on the complexity of an
 * expression.
 *
 * A value of 0 used to mean that the limit was not enforced.
 * But that is no longer true.  The limit is now strictly enforced
 * at all times.
 */
#ifndef SQL_MAX_EXPR_DEPTH
#define SQL_MAX_EXPR_DEPTH 200
#endif

/*
 * The maximum number of terms in a compound SELECT statement.
 * The code generator for compound SELECT statements does one
 * level of recursion for each term.  A stack overflow can result
 * if the number of terms is too large.  In practice, most SQL
 * never has more than 3 or 4 terms.  Use a value of 0 to disable
 * any limit on the number of terms in a compount SELECT.
 */
#ifndef SQL_MAX_COMPOUND_SELECT
#define SQL_MAX_COMPOUND_SELECT 50
#endif

/*
 * The default number of opcodes Vdbe is allowed
 * to execute.
 */
extern uint64_t default_vdbe_max_steps;

/* The amount of opcodes to execute before running vdbe_yield_cb. */
extern uint64_t OPCODE_YIELD_COUNT;

/* Arguments for vdbe_yield_cb callback. */
struct vdbe_yield_args {
	/* Time since the last fiber switch, controlled by vdbe callback. */
	int64_t *start;
	/* Current time. */
	int64_t current;
};

/* Callback to execute custom logic while running vdbe. */
extern int
(*vdbe_yield_cb)(struct vdbe_yield_args *args);

struct Mem;

enum sql_insert_hook_value_type {
	SQL_INSERT_HOOK_VALUE_UNSUPPORTED = 0,
	SQL_INSERT_HOOK_VALUE_NULL,
	SQL_INSERT_HOOK_VALUE_INT,
	SQL_INSERT_HOOK_VALUE_UINT,
	SQL_INSERT_HOOK_VALUE_BOOL,
	SQL_INSERT_HOOK_VALUE_DOUBLE,
	SQL_INSERT_HOOK_VALUE_DECIMAL,
};

/* Value copied from an SQL Mem cell for external insert hooks. */
struct sql_insert_hook_value {
	/* Kind of the value stored in the union below. */
	enum sql_insert_hook_value_type type;
	union {
		/* Signed integer value. */
		int64_t i;
		/* Unsigned integer value. */
		uint64_t u;
		/* Boolean value. */
		bool b;
		/* Double precision floating point value. */
		double d;
		/* Decimal value. */
		decimal_t dec;
	} u;
};

/* Convert an SQL Mem cell to a hook value. */
int
sql_insert_hook_mem_value(const struct Mem *mem,
			  struct sql_insert_hook_value *out);

/* Convert an SQL aVar slot to a hook value. */
int
sql_insert_hook_var_value(const struct Mem *a_var, int n_var, int slot,
			  struct sql_insert_hook_value *out);

/* Arguments for sql_insert_hook callback. */
struct sql_insert_hook_args {
	/* Identifier of the target persistent space. */
	uint32_t space_id;
	/* MessagePack tuple data. */
	const char *tuple;
	/* End of MessagePack tuple data. */
	const char *tuple_end;
	/* Values available to OP_Variable opcodes in the current VDBE. */
	const struct Mem *a_var;
	/* Number of entries in a_var. */
	int n_var;
	/* Opaque context owned by the hook installer. */
	void *ctx;
};

/* Callback for OP_IdxInsert hook payloads. */
typedef int
(*sql_insert_hook_f)(struct sql_insert_hook_args *args);

/* Optional hook payload for OP_IdxInsert opcodes marked with P4_PTR. */
struct sql_insert_hook {
	/* Callback to run instead of the default insert path. */
	sql_insert_hook_f run;
	/* Opaque context passed to the callback. */
	void *ctx;
};

/* Arguments for sql_explain_hook callback. */
struct sql_explain_hook_args {
	/* OP_Explain P1, exposed as the selectid column. */
	int select_id;
	/* OP_Explain P2, exposed as the order column. */
	int order;
	/* OP_Explain P3, exposed as the from column. */
	int from;
	/* Opaque context owned by the hook installer. */
	void *ctx;
};

/* Callback for OP_Explain detail payloads. */
typedef const char *
(*sql_explain_hook_f)(struct sql_explain_hook_args *args);

/* Optional detail payload for OP_Explain opcodes marked with P4_PTR. */
struct sql_explain_hook {
	/* Callback returning the detail column value. */
	sql_explain_hook_f run;
	/* Opaque context passed to the callback. */
	void *ctx;
};

enum sql_raw_explain_event {
	SQL_RAW_EXPLAIN_IDX_INSERT = 1,
};

/* Callback to resolve optional OP_Explain hook during VDBE construction. */
typedef struct sql_explain_hook *
(*sql_raw_explain_resolve_f)(enum sql_raw_explain_event event, void *ctx);

/** Provider for optional RAW EXPLAIN hooks during VDBE construction. */
struct sql_raw_explain_provider {
	/* Callback returning a hook for the requested construction event. */
	sql_raw_explain_resolve_f resolve;
	/* Opaque context passed to the callback. */
	void *ctx;
};

/*
 * The maximum number of arguments to an SQL function.
 */
#ifndef SQL_MAX_FUNCTION_ARG
#define SQL_MAX_FUNCTION_ARG 127
#endif

/*
 * The suggested maximum number of in-memory pages to use for
 * the main database table and for temporary tables.
 *
 * IMPLEMENTATION-OF: R-30185-15359 The default suggested cache size is -2000,
 * which means the cache size is limited to 2048000 bytes of memory.
 * IMPLEMENTATION-OF: R-48205-43578 The default suggested cache size can be
 * altered using the sql_DEFAULT_CACHE_SIZE compile-time options.
 */
#ifndef SQL_DEFAULT_CACHE_SIZE
#define SQL_DEFAULT_CACHE_SIZE  -2000
#endif

/*
 * The maximum number of attached databases.  This must be between 0
 * and 125.  The upper bound of 125 is because the attached databases are
 * counted using a signed 8-bit integer which has a maximum value of 127
 * and we have to allow 2 extra counts for the "main" and "temp" databases.
 */
#ifndef SQL_MAX_ATTACHED
#define SQL_MAX_ATTACHED 10
#endif

/*
 * Maximum length (in bytes) of the pattern in a LIKE operator.
 */
#ifndef SQL_MAX_LIKE_PATTERN_LENGTH
#define SQL_MAX_LIKE_PATTERN_LENGTH 50000
#endif

/*
 * Maximum depth of recursion for triggers.
 *
 * A value of 1 means that a trigger program will not be able to itself
 * fire any triggers. A value of 0 means that no trigger programs at all
 * may be executed.
 */
#ifndef SQL_MAX_TRIGGER_DEPTH
#define SQL_MAX_TRIGGER_DEPTH 1000
#endif

/*
 * Tarantool: gh-2550: Fiber stack is 64KB by default, so maximum
 * number of entities (in chain of compiling trigger programs) should be less than
 * 40 or stack guard will be triggered.
 */
#define SQL_MAX_COMPILING_TRIGGERS 30

#endif /* TARANTOOL_SQL_sqlLIMIT_H_INCLUDED */
