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
 * This file contains the C-language implementations for many of the SQL
 * functions of sql.  (Some function, and in particular the date and
 * time functions, are implemented separately.)
 */
#include "sqlInt.h"
#include "mem.h"
#include "mp_datetime.h"
#include "mp_decimal.h"
#include "mp_interval.h"
#include "mp_json.h"
#include "port.h"
#include "func.h"
#include "vdbeInt.h"
#include "version.h"
#include "coll/coll.h"
#include "tarantoolInt.h"
#include <unicode/ustring.h>
#include <unicode/ucasemap.h>
#include <unicode/ucnv.h>
#include <unicode/uchar.h>
#include <unicode/ucol.h>
#include "box/coll_id_cache.h"
#include "box/func_cache.h"
#include "box/execute.h"
#include "box/session.h"
#include "box/tuple_format.h"
#include "box/user.h"
#include "assoc.h"

static struct mh_strnptr_t *built_in_functions = NULL;
static struct func_sql_builtin **functions;

/** Return true if a built-in scalar function has @a name. */
static bool
sql_builtin_func_is_reserved(const char *name, uint32_t name_len);

/** Derive a common type without changing the values. */
static enum field_type
sql_table_func_resolve_type(enum field_type a, enum field_type b)
{
	if (field_type1_contains_type2(a, b))
		return a;
	if (field_type1_contains_type2(b, a))
		return b;
	const enum field_type common[] = {
		FIELD_TYPE_NUMBER, FIELD_TYPE_SCALAR, FIELD_TYPE_ANY,
	};
	for (uint32_t i = 0; i < nelem(common); i++) {
		if (field_type1_contains_type2(common[i], a) &&
		    field_type1_contains_type2(common[i], b))
			return common[i];
	}
	unreachable();
}

/** Infer the element type without converting the array values. */
static int
unnest_resolve_schema(struct ExprList *args, struct field_def *fields)
{
	struct Expr *arg = sqlExprSkipCollate(args->a[0].pExpr);
	enum field_type type = FIELD_TYPE_ANY;
	if (sql_expr_type(arg) == FIELD_TYPE_JSON) {
		type = FIELD_TYPE_JSON;
	} else if (arg->op == TK_ARRAY && arg->x.pList != NULL) {
		bool first = true;
		for (int i = 0; i < arg->x.pList->nExpr; i++) {
			struct Expr *elem =
				sqlExprSkipCollate(arg->x.pList->a[i].pExpr);
			if (elem->op == TK_NULL)
				continue;
			/* Signs keep an uncast parameter's type unknown. */
			struct Expr *operand = elem;
			while (operand->op == TK_UPLUS ||
			       operand->op == TK_UMINUS)
				operand = sqlExprSkipCollate(operand->pLeft);
			enum field_type elem_type = operand->op == TK_VARIABLE ?
				FIELD_TYPE_ANY : sql_expr_type(elem);
			type = first ? elem_type :
				sql_table_func_resolve_type(type, elem_type);
			first = false;
		}
	}
	fields[0].type = type;
	fields[0].is_nullable = true;
	return 0;
}

/** Number of the arguments of a series with a step. */
#define GENERATE_SERIES_STEP_ARGC 3

/**
 * Return the type of the values of a series, from the types of the
 * arguments at the preparation of the statement:
 *  - DATETIME, if the call has a step and an argument has the DATETIME or
 *    the INTERVAL type;
 *  - DECIMAL, if an argument has the DECIMAL type;
 *  - INTEGER in all other cases.
 */
static enum field_type
generate_series_type(struct ExprList *args)
{
	enum field_type type = FIELD_TYPE_INTEGER;
	for (int i = 0; i < args->nExpr; i++) {
		struct Expr *arg = sqlExprSkipCollate(args->a[i].pExpr);
		enum field_type arg_type = sql_expr_type(arg);
		if ((arg_type == FIELD_TYPE_DATETIME ||
		     arg_type == FIELD_TYPE_INTERVAL) &&
		    args->nExpr == GENERATE_SERIES_STEP_ARGC)
			return FIELD_TYPE_DATETIME;
		if (arg_type == FIELD_TYPE_DECIMAL)
			type = FIELD_TYPE_DECIMAL;
	}
	return type;
}

/** Set the column type of a series. */
static int
generate_series_resolve_schema(struct ExprList *args, struct field_def *fields)
{
	fields[0].type = generate_series_type(args);
	return 0;
}

/** Cast the bounds and the step of a series to the types of the series. */
static const enum field_type *
generate_series_param_types(struct ExprList *args)
{
	static const enum field_type integer_types[] = {
		FIELD_TYPE_INTEGER, FIELD_TYPE_INTEGER, FIELD_TYPE_INTEGER,
	};
	static const enum field_type decimal_types[] = {
		FIELD_TYPE_DECIMAL, FIELD_TYPE_DECIMAL, FIELD_TYPE_DECIMAL,
	};
	static const enum field_type datetime_types[] = {
		FIELD_TYPE_DATETIME, FIELD_TYPE_DATETIME, FIELD_TYPE_INTERVAL,
	};
	enum field_type type = generate_series_type(args);
	if (type == FIELD_TYPE_DATETIME)
		return datetime_types;
	return type == FIELD_TYPE_DECIMAL ? decimal_types : integer_types;
}

/** Set the fixed key and value types of a JSON object iterator. */
static int
json_each_resolve_schema(struct ExprList *args, struct field_def *fields)
{
	(void)args;
	fields[0].type = FIELD_TYPE_STRING;
	fields[1].type = FIELD_TYPE_JSON;
	return 0;
}

/** Read only an integer literal, optionally preceded by a sign. */
static bool
expr_read_int(struct Expr *expr, int64_t *value)
{
	expr = sqlExprSkipCollate(expr);
	bool neg = expr->op == TK_UMINUS;
	if (neg || expr->op == TK_UPLUS)
		expr = expr->pLeft;
	if (expr->op != TK_INTEGER)
		return false;
	uint64_t magnitude;
	if (ExprHasProperty(expr, EP_IntValue)) {
		magnitude = expr->u.iValue;
	} else {
		const char *text = expr->u.zToken;
		if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
			char *end;
			errno = 0;
			magnitude = strtoull(text, &end, 16);
			if (errno != 0 || *end != '\0')
				return false;
		} else {
			int64_t parsed;
			bool sign;
			if (sql_atoi64(text, &parsed, &sign,
				       strlen(text)) != 0 ||
			    sign)
				return false;
			magnitude = (uint64_t)parsed;
		}
	}
	if (magnitude > (uint64_t)INT64_MAX + neg)
		return false;
	if (neg && magnitude == (uint64_t)INT64_MAX + 1)
		*value = INT64_MIN;
	else
		*value = neg ? -(int64_t)magnitude : (int64_t)magnitude;
	return true;
}

/** Read only a decimal literal, optionally preceded by a sign. */
static bool
expr_read_decimal(struct Expr *expr, decimal_t *value)
{
	expr = sqlExprSkipCollate(expr);
	bool neg = expr->op == TK_UMINUS;
	if (neg || expr->op == TK_UPLUS)
		expr = expr->pLeft;
	if (expr->op != TK_DECIMAL ||
	    decimal_from_string(value, expr->u.zToken) == NULL)
		return false;
	if (neg)
		decimal_minus(value, value);
	return true;
}

/** Read a literal argument of a DECIMAL series: a decimal or an integer. */
static bool
expr_read_decimal_arg(struct Expr *expr, decimal_t *value)
{
	int64_t integer;
	if (expr_read_int(expr, &integer)) {
		decimal_from_int64(value, integer);
		return true;
	}
	return expr_read_decimal(expr, value);
}

/** Return the number of the values of a series of integers. */
static uint64_t
generate_series_count_integers(int64_t start, int64_t stop, int64_t step)
{
	bool is_descending = step < 0;
	if (step == 0 || (is_descending ? start < stop : start > stop))
		return 0;
	uint64_t diff = is_descending ? (uint64_t)start - (uint64_t)stop :
					(uint64_t)stop - (uint64_t)start;
	uint64_t abs_step = is_descending ? -(uint64_t)step : (uint64_t)step;
	uint64_t count = diff / abs_step;
	return count == UINT64_MAX ? UINT64_MAX : count + 1;
}

/** Return the number of the values of a series of decimals. */
static uint64_t
generate_series_count_decimals(const decimal_t *start, const decimal_t *stop,
			       const decimal_t *step)
{
	decimal_t zero;
	decimal_zero(&zero);
	int sign = decimal_compare(step, &zero);
	int cmp = decimal_compare(start, stop);
	if (sign == 0 || (sign < 0 ? cmp < 0 : cmp > 0))
		return 0;
	/* The series has floor((stop - start) / step) + 1 values. */
	decimal_t quotient;
	uint64_t count;
	if (decimal_sub(&quotient, stop, start) == NULL ||
	    decimal_div(&quotient, &quotient, step) == NULL ||
	    decimal_floor(&quotient, 0) == NULL ||
	    decimal_to_uint64(&quotient, &count) == NULL ||
	    count == UINT64_MAX)
		return UINT64_MAX;
	return count + 1;
}

/** Estimate a range size from literal arguments without evaluating them. */
static uint64_t
generate_series_estimate_rows(struct ExprList *args)
{
	for (int i = 0; i < args->nExpr; i++) {
		if (sqlExprSkipCollate(args->a[i].pExpr)->op == TK_NULL)
			return 0;
	}
	struct Expr *start_expr = args->a[0].pExpr;
	struct Expr *stop_expr = args->a[1].pExpr;
	/* A series with no step has a step of 1. */
	struct Expr *step_expr = args->nExpr == GENERATE_SERIES_STEP_ARGC ?
				 args->a[2].pExpr : NULL;
	int64_t start, stop;
	int64_t step = 1;
	if (expr_read_int(start_expr, &start) &&
	    expr_read_int(stop_expr, &stop) &&
	    (step_expr == NULL || expr_read_int(step_expr, &step)))
		return generate_series_count_integers(start, stop, step);
	decimal_t dec_start, dec_stop, dec_step;
	decimal_from_int64(&dec_step, 1);
	if (expr_read_decimal_arg(start_expr, &dec_start) &&
	    expr_read_decimal_arg(stop_expr, &dec_stop) &&
	    (step_expr == NULL || expr_read_decimal_arg(step_expr, &dec_step)))
		return generate_series_count_decimals(&dec_start, &dec_stop,
						      &dec_step);
	return 1000;
}

/** Count constructor elements, or use the default array size estimate. */
static uint64_t
unnest_estimate_rows(struct ExprList *args)
{
	struct Expr *arg = sqlExprSkipCollate(args->a[0].pExpr);
	if (arg->op == TK_NULL)
		return 0;
	if (arg->op == TK_ARRAY)
		return arg->x.pList == NULL ? 0 : arg->x.pList->nExpr;
	return 100;
}

/** Estimate object size without evaluating the JSON expression. */
static uint64_t
json_each_estimate_rows(struct ExprList *args)
{
	return sqlExprSkipCollate(args->a[0].pExpr)->op == TK_NULL ? 0 : 100;
}

/*
 * MsgPack fixarray(1) plus the largest encoded value: a decimal with
 * DECIMAL_MAX_DIGITS digits.
 */
#define GENERATE_SERIES_ROW_BUF_SIZE 32

/*
 * A decimal is an ext8 (a 3-byte header) of a scale, an int32 of up to 5
 * bytes, and the digits with the sign, 2 per byte. A datetime is a fixext16
 * (a 2-byte header) of at most the size of struct datetime.
 */
static_assert(GENERATE_SERIES_ROW_BUF_SIZE >=
	      1 + 3 + 5 + DECIMAL_MAX_DIGITS / 2 + 1,
	      "generate_series row buffer is too small for a decimal");
static_assert(GENERATE_SERIES_ROW_BUF_SIZE >= 1 + 2 + sizeof(struct datetime),
	      "generate_series row buffer is too small for a datetime");

/** A bound or the step of a series. */
union generate_series_value {
	/** A bound or the step of an INTEGER series. */
	int64_t integer;
	/** A bound or the step of a DECIMAL series. */
	decimal_t decimal;
	/** A bound of a DATETIME series. */
	struct datetime datetime;
	/** The step of a DATETIME series. */
	struct interval interval;
};

/** Iterator state for generate_series(start, stop[, step]). */
struct generate_series_ctx {
	/** Value to return in the next row. */
	union generate_series_value current;
	/** Inclusive last bound. */
	union generate_series_value stop;
	/** Difference between two adjacent values. */
	union generate_series_value step;
	/** Type of the values of the series. */
	enum field_type type;
	/** True if the step makes the values smaller. */
	bool is_descending;
	/**
	 * Not NULL if the step cannot give the value after the current
	 * one. The next row is then an error with this message.
	 */
	const char *error;
	/** True once the iterator reached EOF. */
	bool done;
	/** Reusable MsgPack row buffer. */
	char row[GENERATE_SERIES_ROW_BUF_SIZE];
};

/**
 * Read a generate_series argument from MsgPack and set its type. Set
 * @a is_null and no type if the argument is NULL.
 */
static int
generate_series_read_arg(const char **data, union generate_series_value *value,
			 enum field_type *type, bool *is_null)
{
	switch (mp_typeof(**data)) {
	case MP_NIL:
		mp_decode_nil(data);
		*is_null = true;
		return 0;
	case MP_UINT:
	case MP_INT:
		if (mp_read_int64(data, &value->integer) != 0) {
			diag_set(ClientError, ER_SQL_EXECUTE,
				 "integer is overflowed");
			return -1;
		}
		*type = FIELD_TYPE_INTEGER;
		return 0;
	case MP_EXT: {
		const char *pos = *data;
		int8_t ext_type;
		mp_decode_extl(&pos, &ext_type);
		if (ext_type == MP_DECIMAL &&
		    mp_decode_decimal(data, &value->decimal) != NULL) {
			*type = FIELD_TYPE_DECIMAL;
			return 0;
		}
		if (ext_type == MP_DATETIME &&
		    mp_decode_datetime(data, &value->datetime) != NULL) {
			*type = FIELD_TYPE_DATETIME;
			return 0;
		}
		if (ext_type == MP_INTERVAL &&
		    mp_decode_interval(data, &value->interval) != NULL) {
			*type = FIELD_TYPE_INTERVAL;
			return 0;
		}
		break;
	}
	default:
		break;
	}
	diag_set(ClientError, ER_PROC_C,
		 "generate_series got invalid arguments");
	return -1;
}

/** Compare two values of a series of the given type. */
static int
generate_series_compare(enum field_type type,
			const union generate_series_value *lhs,
			const union generate_series_value *rhs)
{
	switch (type) {
	case FIELD_TYPE_DECIMAL:
		return decimal_compare(&lhs->decimal, &rhs->decimal);
	case FIELD_TYPE_DATETIME:
		return datetime_compare(&lhs->datetime, &rhs->datetime);
	default:
		return (lhs->integer > rhs->integer) -
		       (lhs->integer < rhs->integer);
	}
}

/**
 * Add the step of a series to a value. Return a negative value if the
 * result is too small for the type of the series, a positive value if it
 * is too large, and 0 if it is correct. Set @a next in the last case.
 */
static int
generate_series_add_step(const struct generate_series_ctx *state,
			 const union generate_series_value *value,
			 union generate_series_value *next)
{
	switch (state->type) {
	case FIELD_TYPE_DECIMAL:
		if (decimal_add(&next->decimal, &value->decimal,
				&state->step.decimal) != NULL)
			return 0;
		return decimal_is_neg(&state->step.decimal) ? -1 : 1;
	case FIELD_TYPE_DATETIME:
		next->datetime = value->datetime;
		return datetime_increment_by(&next->datetime, 1,
					     &state->step.interval);
	default: {
		int64_t step = state->step.integer;
		if (step > 0 && value->integer > INT64_MAX - step)
			return 1;
		if (step < 0 && value->integer < INT64_MIN - step)
			return -1;
		next->integer = value->integer + step;
		return 0;
	}
	}
}

/**
 * Return the sign of an INTERVAL: a positive or a negative value, or 0.
 * The effect of an INTERVAL with parts of different signs depends on the
 * date: one month minus 30 days is 1 day from January 1 and 0 days from
 * March 31. So the sign comes from a fixed rule, the same as in PostgreSQL:
 * a year is 12 months, a month is 30 days and a day is 24 hours.
 */
static int
interval_sign(const struct interval *itv)
{
	/*
	 * All parts are integer numbers, and the sum is much less than
	 * 2^53, so the result in double is exact.
	 */
	double months = (double)itv->year * 12 + itv->month;
	double days = months * 30 + (double)itv->week * 7 + itv->day;
	double secs = days * 24 * 3600 + itv->hour * 3600 + itv->min * 60 +
		      itv->sec + itv->nsec / NANOS_PER_SEC;
	int nsec = itv->nsec % NANOS_PER_SEC;
	if (secs != 0)
		return secs > 0 ? 1 : -1;
	return (nsec > 0) - (nsec < 0);
}

/**
 * Return the direction of a series: a positive value if the step makes
 * the values larger, a negative value if it makes them smaller, and 0 if
 * the step is zero.
 */
static int
generate_series_direction(const struct generate_series_ctx *state)
{
	switch (state->type) {
	case FIELD_TYPE_DECIMAL: {
		decimal_t zero;
		decimal_zero(&zero);
		return decimal_compare(&state->step.decimal, &zero);
	}
	case FIELD_TYPE_DATETIME:
		return interval_sign(&state->step.interval);
	default:
		return (state->step.integer > 0) - (state->step.integer < 0);
	}
}

/** Set the default step of a series with no step argument: 1. */
static void
generate_series_set_default_step(struct generate_series_ctx *state)
{
	if (state->type == FIELD_TYPE_DECIMAL)
		decimal_from_int64(&state->step.decimal, 1);
	else
		state->step.integer = 1;
}

/** Open a generate_series iterator. */
static int
generate_series_open(const char *args, const char *args_end, void **ctx)
{
	if (args >= args_end || mp_typeof(*args) != MP_ARRAY) {
		diag_set(ClientError, ER_PROC_C,
			 "generate_series expects arguments array");
		return -1;
	}
	uint32_t argc = mp_decode_array(&args);
	if (argc != 2 && argc != GENERATE_SERIES_STEP_ARGC) {
		diag_set(ClientError, ER_PROC_C,
			 "generate_series expects 2 or 3 arguments");
		return -1;
	}
	union generate_series_value values[GENERATE_SERIES_STEP_ARGC];
	enum field_type types[GENERATE_SERIES_STEP_ARGC];
	bool has_null_arg = false;
	for (uint32_t i = 0; i < argc; i++) {
		if (generate_series_read_arg(&args, &values[i], &types[i],
					     &has_null_arg) != 0)
			return -1;
	}
	if (args != args_end) {
		diag_set(ClientError, ER_PROC_C,
			 "generate_series got invalid arguments");
		return -1;
	}
	struct generate_series_ctx *state = xmalloc(sizeof(*state));
	state->type = FIELD_TYPE_INTEGER;
	state->is_descending = false;
	state->error = NULL;
	state->done = true;
	*ctx = state;
	if (has_null_arg)
		return 0;
	/*
	 * After the implicit cast the bounds have the type of the series,
	 * and the step has the type of the difference of two values. The
	 * iterator does not trust the caller for this: a value of a wrong
	 * type must not be read as a value of the series.
	 */
	state->type = types[0];
	state->current = values[0];
	state->stop = values[1];
	bool has_step = argc == GENERATE_SERIES_STEP_ARGC;
	bool is_valid = types[1] == state->type;
	switch (state->type) {
	case FIELD_TYPE_INTEGER:
	case FIELD_TYPE_DECIMAL:
		/* The step of a series of numbers is optional. */
		is_valid = is_valid && (!has_step || types[2] == state->type);
		break;
	case FIELD_TYPE_DATETIME:
		is_valid = is_valid && has_step &&
			   types[2] == FIELD_TYPE_INTERVAL;
		break;
	default:
		is_valid = false;
		break;
	}
	if (!is_valid) {
		diag_set(ClientError, ER_PROC_C,
			 "generate_series got invalid arguments");
		goto error;
	}
	if (has_step)
		state->step = values[2];
	else
		generate_series_set_default_step(state);
	int direction = generate_series_direction(state);
	if (direction == 0) {
		diag_set(ClientError, ER_SQL_EXECUTE,
			 "the step of generate_series cannot be zero");
		goto error;
	}
	state->is_descending = direction < 0;
	int cmp = generate_series_compare(state->type, &state->current,
					  &state->stop);
	state->done = state->is_descending ? cmp < 0 : cmp > 0;
	return 0;
error:
	free(state);
	*ctx = NULL;
	return -1;
}

/** Return the next generate_series row. */
static int
generate_series_next(void *ctx, const char **row, const char **row_end)
{
	struct generate_series_ctx *state = ctx;
	if (state->error != NULL) {
		diag_set(ClientError, ER_SQL_EXECUTE, state->error);
		return -1;
	}
	if (state->done) {
		*row = NULL;
		*row_end = NULL;
		return 0;
	}
	char *pos = state->row;
	pos = mp_encode_array(pos, 1);
	switch (state->type) {
	case FIELD_TYPE_DECIMAL:
		assert(mp_sizeof_decimal(&state->current.decimal) <
		       GENERATE_SERIES_ROW_BUF_SIZE);
		pos = mp_encode_decimal(pos, &state->current.decimal);
		break;
	case FIELD_TYPE_DATETIME:
		assert(mp_sizeof_datetime(&state->current.datetime) <
		       GENERATE_SERIES_ROW_BUF_SIZE);
		pos = mp_encode_datetime(pos, &state->current.datetime);
		break;
	default:
		if (state->current.integer < 0)
			pos = mp_encode_int(pos, state->current.integer);
		else
			pos = mp_encode_uint(pos, state->current.integer);
		break;
	}
	*row = state->row;
	*row_end = pos;
	/* The series ends at the last bound. */
	union generate_series_value next;
	if (generate_series_compare(state->type, &state->current,
				    &state->stop) == 0) {
		state->done = true;
		return 0;
	}
	if (generate_series_add_step(state, &state->current, &next) != 0) {
		/*
		 * A number out of the range of its type is past the last
		 * bound, so the series ends. A DATETIME step is added part
		 * by part, and a part out of the range does not mean that
		 * the full step is: this is an error, as for `+`.
		 */
		if (state->type == FIELD_TYPE_DATETIME)
			state->error = "datetime is overflowed";
		else
			state->done = true;
		return 0;
	}
	int step_cmp = generate_series_compare(state->type, &next,
					       &state->current);
	int stop_cmp = generate_series_compare(state->type, &next,
					       &state->stop);
	if (step_cmp == 0) {
		/*
		 * The step does not change the value, so the series
		 * cannot reach the last bound. A step with parts of
		 * different signs, or a step that is too small for the
		 * precision of the value, has this effect.
		 */
		state->error = "the step of generate_series does not change "
			       "the value";
	} else if (state->is_descending ? step_cmp > 0 : step_cmp < 0) {
		/*
		 * The step moves the value away from the last bound. Only
		 * a step of a DATETIME series with parts of different
		 * signs has this effect: its sign comes from a fixed rule,
		 * and for some dates the step goes the other way.
		 */
		state->error = "the step of generate_series moves the value "
			       "against the direction of the series";
	} else if (state->is_descending ? stop_cmp < 0 : stop_cmp > 0) {
		state->done = true;
	} else {
		state->current = next;
	}
	return 0;
}

/** Close a generate_series iterator. */
static void
generate_series_close(void *ctx)
{
	free(ctx);
}

static const struct sql_table_func_ops generate_series_ops = {
	.resolve_schema = generate_series_resolve_schema,
	.estimate_rows = generate_series_estimate_rows,
	.param_types = generate_series_param_types,
	.open = generate_series_open,
	.next = generate_series_next,
	.close = generate_series_close,
};

static const struct field_def generate_series_fields[] = {
	{
		.type = FIELD_TYPE_INTEGER,
		.name = (char *)"VALUE",
		.is_nullable = false,
		.nullable_action = ON_CONFLICT_ACTION_DEFAULT,
	},
};

/** Iterator state for unnest(array). */
struct unnest_ctx {
	/** Next array element to return. */
	const char *next;
	/** Number of elements left to return. */
	uint32_t left;
	/** True if @a next points into a JSON inner array. */
	bool is_json;
	/** Reusable MsgPack row buffer. */
	char *row;
	/** Allocated size of @a row. */
	size_t row_capacity;
};

/** Open an unnest iterator. */
static int
unnest_open(const char *args, const char *args_end, void **ctx)
{
	if (args >= args_end || mp_typeof(*args) != MP_ARRAY) {
		diag_set(ClientError, ER_PROC_C,
			 "unnest expects arguments array");
		return -1;
	}
	uint32_t argc = mp_decode_array(&args);
	if (argc != 1) {
		diag_set(ClientError, ER_PROC_C, "unnest expects 1 argument");
		return -1;
	}
	if (args >= args_end) {
		diag_set(ClientError, ER_PROC_C,
			 "unnest got invalid arguments");
		return -1;
	}
#ifndef NDEBUG
	/*
	 * Arguments are trusted SQL values. Rechecking the whole array on
	 * every open would visit elements that the query may never read.
	 */
	const char *arg_end = args;
	assert(mp_check(&arg_end, args_end) == 0 && arg_end == args_end);
#endif
	enum mp_type type = mp_typeof(*args);
	if (type != MP_ARRAY && type != MP_NIL && type != MP_EXT) {
		diag_set(ClientError, ER_PROC_C,
			 "unnest expects array argument");
		return -1;
	}
	struct unnest_ctx *state = xmalloc(sizeof(*state));
	state->next = NULL;
	state->left = 0;
	state->is_json = false;
	state->row = NULL;
	state->row_capacity = 0;
	if (type == MP_ARRAY) {
		state->left = mp_decode_array(&args);
		state->next = args;
	} else if (type == MP_EXT) {
		uint32_t len;
		const char *inner = mp_decode_json(&args, &len);
		if (inner == NULL ||
		    mp_typeof(*inner) != MP_ARRAY) {
			free(state);
			diag_set(ClientError, ER_PROC_C,
				 "unnest expects array or json array argument");
			return -1;
		}
		state->left = mp_decode_array(&inner);
		state->next = inner;
		state->is_json = true;
	}
	*ctx = state;
	return 0;
}

/** Return a native SQL element, or wrap a normalized JSON subtree. */
static int
unnest_next(void *ctx, const char **row, const char **row_end)
{
	struct unnest_ctx *state = ctx;
	if (state->left == 0) {
		*row = NULL;
		*row_end = NULL;
		return 0;
	}
	const char *element = state->next;
	mp_next(&state->next);
	uint32_t element_size = state->next - element;
	size_t value_size = state->is_json ?
		mp_sizeof_json_len(element_size) : element_size;
	size_t row_size = mp_sizeof_array(1) + value_size;
	if (row_size > state->row_capacity) {
		state->row = xrealloc(state->row, row_size);
		state->row_capacity = row_size;
	}
	char *pos = mp_encode_array(state->row, 1);
	if (state->is_json) {
		/* A subtree of a trusted SQL JSON value is normalized.
		 * See doc/json-perimeter.md#table-function-iterators.
		 */
		struct json_norm norm =
			json_norm_from_trusted(element, element_size);
		mp_encode_json(pos, norm);
	} else {
		memcpy(pos, element, element_size);
	}
	*row = state->row;
	*row_end = state->row + row_size;
	state->left--;
	return 0;
}

/** Close an unnest iterator. */
static void
unnest_close(void *ctx)
{
	struct unnest_ctx *state = ctx;
	free(state->row);
	free(state);
}

static const struct sql_table_func_ops unnest_ops = {
	.resolve_schema = unnest_resolve_schema,
	.estimate_rows = unnest_estimate_rows,
	.open = unnest_open,
	.next = unnest_next,
	.close = unnest_close,
};

static const struct field_def unnest_fields[] = {
	{
		.type = FIELD_TYPE_ANY,
		.name = (char *)"VALUE",
		.is_nullable = true,
		.nullable_action = ON_CONFLICT_ACTION_DEFAULT,
	},
};

/** Iterator state for json_each(json_object). */
struct json_each_ctx {
	/** Next object key to return. */
	const char *next;
	/** Number of key-value pairs left to return. */
	uint32_t left;
	/** Reusable MsgPack row buffer. */
	char *row;
	/** Allocated size of @a row. */
	size_t row_capacity;
};

/** Open a json_each iterator. */
static int
json_each_open(const char *args, const char *args_end, void **ctx)
{
	if (args >= args_end || mp_typeof(*args) != MP_ARRAY) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each expects arguments array");
		return -1;
	}
	uint32_t argc = mp_decode_array(&args);
	if (argc != 1) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each expects 1 argument");
		return -1;
	}
	if (args >= args_end) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each got invalid arguments");
		return -1;
	}
	const char *arg_end = args;
	if (mp_check(&arg_end, args_end) != 0 || arg_end != args_end) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each got invalid arguments");
		return -1;
	}
	enum mp_type type = mp_typeof(*args);
	if (type != MP_EXT && type != MP_NIL) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each expects json object argument");
		return -1;
	}
	struct json_each_ctx *state = xmalloc(sizeof(*state));
	state->next = NULL;
	state->left = 0;
	state->row = NULL;
	state->row_capacity = 0;
	if (type == MP_EXT) {
		uint32_t len;
		const char *inner = mp_decode_json(&args, &len);
		if (inner == NULL ||
		    mp_typeof(*inner) != MP_MAP) {
			free(state);
			diag_set(ClientError, ER_PROC_C,
				 "json_each expects json object argument");
			return -1;
		}
		state->left = mp_decode_map(&inner);
		state->next = inner;
	}
	*ctx = state;
	return 0;
}

/** Return the next json_each row. */
static int
json_each_next(void *ctx, const char **row, const char **row_end)
{
	struct json_each_ctx *state = ctx;
	if (state->left == 0) {
		*row = NULL;
		*row_end = NULL;
		return 0;
	}
	uint32_t key_len;
	const char *key = mp_decode_str(&state->next, &key_len);
	const char *value = state->next;
	mp_next(&state->next);
	size_t value_size = state->next - value;
	if (value_size > UINT32_MAX) {
		diag_set(ClientError, ER_PROC_C,
			 "json_each got too large json value");
		return -1;
	}
	/* A trusted SQL JSON subtree remains in normal form.
	 * See doc/json-perimeter.md#table-function-iterators.
	 */
	struct json_norm norm = json_norm_from_trusted(value, value_size);
	size_t row_size = mp_sizeof_array(2) + mp_sizeof_str(key_len) +
			  mp_sizeof_json(norm);
	if (row_size > state->row_capacity) {
		state->row = xrealloc(state->row, row_size);
		state->row_capacity = row_size;
	}
	char *pos = mp_encode_array(state->row, 2);
	pos = mp_encode_str(pos, key, key_len);
	pos = mp_encode_json(pos, norm);
	assert(pos == state->row + row_size);
	*row = state->row;
	*row_end = state->row + row_size;
	state->left--;
	return 0;
}

/** Close a json_each iterator. */
static void
json_each_close(void *ctx)
{
	struct json_each_ctx *state = ctx;
	free(state->row);
	free(state);
}

static const struct sql_table_func_ops json_each_ops = {
	.resolve_schema = json_each_resolve_schema,
	.estimate_rows = json_each_estimate_rows,
	.open = json_each_open,
	.next = json_each_next,
	.close = json_each_close,
};

static const struct field_def json_each_fields[] = {
	{
		.type = FIELD_TYPE_STRING,
		.name = (char *)"KEY",
		.is_nullable = false,
		.nullable_action = ON_CONFLICT_ACTION_DEFAULT,
	},
	{
		.type = FIELD_TYPE_JSON,
		.name = (char *)"VALUE",
		.is_nullable = false,
		.nullable_action = ON_CONFLICT_ACTION_DEFAULT,
	},
};

static const struct sql_table_func_def sql_builtin_table_funcs[] = {
	{
		.name = "GENERATE_SERIES",
		.param_count = 2,
		.param_count_max = GENERATE_SERIES_STEP_ARGC,
		.fields = generate_series_fields,
		.field_count = nelem(generate_series_fields),
		.ops = &generate_series_ops,
	},
	{
		.name = "UNNEST",
		.param_count = 1,
		.fields = unnest_fields,
		.field_count = nelem(unnest_fields),
		.ops = &unnest_ops,
	},
	{
		.name = "JSON_EACH",
		.param_count = 1,
		.fields = json_each_fields,
		.field_count = nelem(json_each_fields),
		.ops = &json_each_ops,
	},
};

static const struct sql_table_func_def **sql_table_funcs = NULL;
static uint32_t sql_table_func_count = 0;
static uint32_t sql_table_func_capacity = 0;
static bool sql_table_func_registry_sealed = false;

/**
 * Compare SQL names without requiring either input to end with NUL. The
 * names are case-sensitive, as the names of built-in scalar functions are.
 */
static bool
name_is_equal(const char *lhs, uint32_t lhs_len, const char *rhs,
	      uint32_t rhs_len)
{
	return lhs_len == rhs_len && memcmp(lhs, rhs, lhs_len) == 0;
}

/** Find a registered SQL table function without reporting an error. */
static const struct sql_table_func_def *
sql_table_func_registry_find(const char *name, uint32_t name_len)
{
	for (uint32_t i = 0; i < sql_table_func_count; i++) {
		const struct sql_table_func_def *def = sql_table_funcs[i];
		if (name_is_equal(name, name_len, def->name, strlen(def->name)))
			return def;
	}
	return NULL;
}

/** Return true if @a name is a registered SQL table function name. */
static bool
sql_table_func_is_registered(const char *name, uint32_t name_len)
{
	return sql_table_func_registry_find(name, name_len) != NULL;
}

int
sql_table_func_register(const struct sql_table_func_def *defs, uint32_t count)
{
	if (sql_table_func_registry_sealed) {
		diag_set(IllegalParams,
			 "SQL table function registry is sealed");
		return -1;
	}
	for (uint32_t i = 0; i < count; i++) {
		const struct sql_table_func_def *def = &defs[i];
		if (def->name == NULL || def->name[0] == '\0' ||
		    def->fields == NULL || def->field_count == 0 ||
		    def->ops == NULL || def->ops->resolve_schema == NULL ||
		    def->ops->estimate_rows == NULL || def->ops->open == NULL ||
		    def->ops->next == NULL || def->ops->close == NULL ||
		    (def->ops->param_types != NULL && def->param_count <= 0) ||
		    (def->param_count_max != 0 &&
		     (def->param_count < 0 ||
		      def->param_count_max <= def->param_count))) {
			diag_set(IllegalParams,
				 "invalid SQL table function definition");
			return -1;
		}
		uint32_t name_len = strlen(def->name);
		if (sql_table_func_is_registered(def->name, name_len)) {
			diag_set(IllegalParams,
				 "duplicate SQL table function name");
			return -1;
		}
		for (uint32_t j = 0; j < i; j++) {
			if (name_is_equal(def->name, name_len, defs[j].name,
					  strlen(defs[j].name))) {
				diag_set(IllegalParams,
					 "duplicate SQL table function name");
				return -1;
			}
		}
		if (sql_builtin_func_is_reserved(def->name, name_len)) {
			diag_set(IllegalParams,
				 "SQL table function name conflicts with "
				 "SQL scalar function");
			return -1;
		}
	}

	if (count == 0)
		return 0;
	if (sql_table_func_count + count > sql_table_func_capacity) {
		uint32_t capacity = sql_table_func_capacity == 0 ? 4 :
				    sql_table_func_capacity;
		while (capacity < sql_table_func_count + count)
			capacity *= 2;
		size_t size = capacity * sizeof(sql_table_funcs[0]);
		sql_table_funcs = xrealloc(sql_table_funcs, size);
		sql_table_func_capacity = capacity;
	}
	for (uint32_t i = 0; i < count; i++)
		sql_table_funcs[sql_table_func_count + i] = &defs[i];
	sql_table_func_count += count;
	return 0;
}

/** Release the registry storage and reset its startup state. */
static void
sql_table_func_registry_free(void)
{
	free(sql_table_funcs);
	sql_table_funcs = NULL;
	sql_table_func_count = 0;
	sql_table_func_capacity = 0;
	sql_table_func_registry_sealed = false;
}

const struct sql_table_func_def *
sql_table_func_find(const char *name, uint32_t name_len, bool is_runtime)
{
	const struct sql_table_func_def *def =
		sql_table_func_registry_find(name, name_len);
	if (def != NULL)
		return def;

	diag_set(ClientError, is_runtime ? ER_SQL_EXECUTE :
		 ER_SQL_PARSER_GENERIC,
		 tt_sprintf("'%.*s' is not a function",
			    (int)name_len, name));
	return NULL;
}

/** Helper structure that keeps last_value data. **/
struct last_value {
	/** Memory cell with the last value. **/
	struct Mem mem;
	/** Reference counter used by inverse function. **/
	uint32_t count;
};

/** Implementation of the LAST_VALUE() function. */
static void
step_last_value(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	assert(mem_is_null(ctx->pOut) || mem_is_bin(ctx->pOut));
	struct last_value *data;
	if (mem_is_null(ctx->pOut)) {
		size_t size = sizeof(struct last_value);
		data = sql_xmalloc(size);
		data->count = 0;
		mem_create(&data->mem);
		mem_set_bin_allocated(ctx->pOut, (char *)data, size);
	}
	data = (struct last_value *)ctx->pOut->z;
	data->count++;
	mem_copy(&data->mem, &argv[0]);
}

/** Value for the LAST_VALUE() function. */
static int
value_last_value(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_bin(mem));
	if (mem_is_null(mem))
		return 0;
	struct last_value *data = (struct last_value *)mem->z;
	struct Mem tmp;
	mem_create(&tmp);
	/*
	 * In the current implementation of last_value, one memory cell
	 * is embedded inside the zMalloc buffer of another cell (which
	 * is opaque to all mem.c routines). That inner cell may itself
	 * have data in its own zMalloc (for example, strings).
	 * By the time we reach the window function's value() callback,
	 * the original cell has already been copied via the OP_Copy
	 * opcode's mem_copy. However, since mem_copy knows nothing about
	 * these zMalloc hacks, the copy isn't truly deep.
	 * As a result, the last_value->mem.zMalloc pointer in both the
	 * original and the copy refers to the same memory region.
	 * To avoid radically changing the memory-cell structure, we perform
	 * a deep copy of last_value->mem.zMalloc in the value() callback
	 * so that when the VDBE machinery later frees the copied cell, it
	 * won't accidentally release the original cell's memory.
	 */
	mem_copy(&tmp, &data->mem);
	mem_destroy(mem);
	memcpy(mem, &tmp, sizeof(tmp));
	return 0;
}

/** Finalizer for the LAST_VALUE() function. */
static int
fin_last_value(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_bin(mem));
	if (mem_is_null(mem))
		return 0;
	struct last_value *data = (struct last_value *)mem->z;
	struct Mem tmp;
	/*
	 * Since no one else refers to last_value->mem.zMalloc,
	 * it's safe to perform memory move. When the VDBE machinery
	 * frees the memory cell, there will be no dangling pointers
	 * to released memory.
	 */
	memcpy(&tmp, &data->mem, sizeof(tmp));
	mem_destroy(mem);
	memcpy(mem, &tmp, sizeof(tmp));
	return 0;
}

/** Inversion for the LAST_VALUE() function. */
static void
inverse_last_value(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	(void)argv;
	if (mem_is_null(ctx->pOut))
		return;
	struct last_value *data = (struct last_value *)ctx->pOut->z;
	data->count--;
	if (data->count == 0) {
		mem_destroy(&data->mem);
		mem_destroy(ctx->pOut);
	}
}

/*
 * Implementation of built-in window function row_number(). Assumes that the
 * window frame has been coerced to:
 *
 *   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
 */
static void
step_row_number(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 0);
	(void)argc;
	(void)argv;
	if (mem_is_null(ctx->pOut))
		mem_set_int(ctx->pOut, 0);
	++ctx->pOut->u.u;
}

/** Implementation of the SUM() function. */
static void
step_sum(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	struct Mem *mem = ctx->pOut;
	assert(mem_is_null(mem) || mem_is_num(mem));
	if (mem_is_null(&argv[0]))
		return;
	uint64_t count = mem_is_null(mem) ? 0 : mem->n;
	if (mem_is_null(mem))
		mem_copy_as_ephemeral(mem, &argv[0]);
	else if (mem_add_aggregate(mem, &argv[0], mem) != 0)
		ctx->is_aborted = true;
	mem->n = count + 1;
}

static void
inverse_sum(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	struct Mem *mem = ctx->pOut;
	if (mem_is_null(&argv[0]) || mem_is_null(mem))
		return;
	uint64_t count = mem->n == 0 ? 0 : mem->n - 1;
	if (count == 0)
		mem_set_null(mem);
	else if (mem_sub(mem, &argv[0], mem) != 0)
		ctx->is_aborted = true;
	mem->n = count;

}

/**
 * Finalizer for the SUM() function on an integer. Sum on an integer must
 * return a decimal, as PostgreSQL does. The accumulator is an integer while
 * the sum fits in one. Thus this makes one conversion for each result, not
 * one for each row.
 */
static int
fin_sum(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_num(mem));
	if (mem_is_int(mem) && mem_cast_implicit(mem, FIELD_TYPE_DECIMAL) != 0)
		return -1;
	return 0;
}

/** Implementation of the TOTAL() function. */
static void
step_total(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	assert(mem_is_null(ctx->pOut) || mem_is_num(ctx->pOut));
	if (mem_is_null(&argv[0]))
		return;
	if (mem_is_null(ctx->pOut))
		mem_set_double(ctx->pOut, 0.0);
	if (mem_add(ctx->pOut, &argv[0], ctx->pOut) != 0)
		ctx->is_aborted = true;
}

/** Finalizer for the TOTAL() function. */
static int
fin_total(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_double(mem));
	if (mem_is_null(mem))
		mem_set_double(mem, 0.0);
	return 0;
}

/** Implementation of the AVG() function. */
static void
step_avg(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	assert(mem_is_null(ctx->pOut) || mem_is_bin(ctx->pOut));
	if (mem_is_null(&argv[0]))
		return;
	struct Mem *mem;
	uint64_t *count;
	if (mem_is_null(ctx->pOut)) {
		uint32_t size = sizeof(struct Mem) + sizeof(uint64_t);
		mem = sql_xmalloc(size);
		count = (uint64_t *)(mem + 1);
		mem_create(mem);
		*count = 1;
		mem_copy_as_ephemeral(mem, &argv[0]);
		mem_set_bin_allocated(ctx->pOut, (char *)mem, size);
		return;
	}
	mem = (struct Mem *)ctx->pOut->z;
	count = (uint64_t *)(mem + 1);
	++*count;
	if (mem_add_aggregate(mem, &argv[0], mem) != 0)
		ctx->is_aborted = true;
}

/** Finalizer for the AVG() function. */
static int
fin_avg(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_bin(mem));
	if (mem_is_null(mem))
		return 0;
	struct Mem *sum = (struct Mem *)mem->z;
	uint64_t *count_val = (uint64_t *)(sum + 1);
	assert(mem_is_trivial(sum));
	/*
	 * A division of an integer by an integer truncates the result.
	 * But avg on an integer must return a decimal, as PostgreSQL
	 * does. Make the sum a decimal, then mem_div() does a decimal
	 * division. The accumulation is still an integer. Thus this
	 * makes one conversion for each result, not one for each row.
	 */
	if (mem_is_int(sum) &&
	    mem_cast_implicit(sum, FIELD_TYPE_DECIMAL) != 0)
		return -1;
	struct Mem count;
	mem_create(&count);
	mem_set_uint(&count, *count_val);
	return mem_div(sum, &count, mem);
}

/** Inversion for the AVG() function. */
static void
inverse_avg(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	if (mem_is_null(&argv[0]) || mem_is_null(ctx->pOut))
		return;
	struct Mem *sum = (struct Mem *)ctx->pOut->z;
	uint64_t *count = (uint64_t *)(sum + 1);
	if (*count == 0) {
		mem_set_null(sum);
		return;
	}
	if (mem_sub(sum, &argv[0], sum) != 0)
		ctx->is_aborted = true;
	--*count;
}

/** Implementation of the COUNT() function. */
static void
step_count(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 0 || argc == 1);
	if (mem_is_null(ctx->pOut))
		mem_set_uint(ctx->pOut, 0);
	if (argc == 1 && mem_is_null(&argv[0]))
		return;
	assert(mem_is_uint(ctx->pOut));
	++ctx->pOut->u.u;
}

static void
inverse_count(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 0 || argc == 1);
	if (mem_is_null(ctx->pOut))
		mem_set_uint(ctx->pOut, 0);
	if (argc == 1 && mem_is_null(&argv[0]))
		return;
	assert(mem_is_uint(ctx->pOut));
	--ctx->pOut->u.u;
}

/** Finalizer for the COUNT() function. */
static int
fin_count(struct Mem *mem)
{
	assert(mem_is_null(mem) || mem_is_uint(mem));
	if (mem_is_null(mem))
		mem_set_uint(mem, 0);
	return 0;
}

/** Implementation of the MIN() and MAX() functions. */
static void
step_minmax(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	if (mem_is_null(&argv[0])) {
		if (!mem_is_null(ctx->pOut))
			ctx->skipFlag = 1;
		return;
	}
	if (mem_is_null(ctx->pOut)) {
		if (mem_copy(ctx->pOut, &argv[0]) != 0)
			ctx->is_aborted = true;
		return;
	}

	uint32_t flags = ((struct func_sql_builtin *)ctx->func)->flags;
	bool is_max = (flags & SQL_FUNC_MAX) != 0;
	/*
	 * This step function is used for both the min() and max() aggregates,
	 * the only difference between the two being that the sense of the
	 * comparison is inverted.
	 */
	int cmp = mem_cmp_scalar(ctx->pOut, &argv[0], ctx->coll);
	if ((is_max && cmp < 0) || (!is_max && cmp > 0)) {
		if (mem_copy(ctx->pOut, &argv[0]) != 0)
			ctx->is_aborted = true;
		return;
	}
	ctx->skipFlag = 1;
}

/** Implementation of the GROUP_CONCAT() function. */
static void
step_group_concat(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1 || argc == 2);
	(void)argc;
	if (mem_is_null(&argv[0]))
		return;
	assert(mem_is_str(&argv[0]) || mem_is_bin(&argv[0]));
	if (mem_is_null(ctx->pOut)) {
		if (mem_copy(ctx->pOut, &argv[0]) != 0)
			ctx->is_aborted = true;
		return;
	}
	const char *sep = NULL;
	int sep_len = 0;
	if (argc == 1) {
		sep = ",";
		sep_len = 1;
	} else if (mem_is_null(&argv[1])) {
		sep = "";
		sep_len = 0;
	} else {
		assert(mem_is_same_type(&argv[0], &argv[1]));
		sep = argv[1].z;
		sep_len = argv[1].n;
	}
	uint64_t len = ctx->pOut->n + argv[0].n + sep_len;
	if (len > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	if (mem_append(ctx->pOut, sep, sep_len) != 0) {
		ctx->is_aborted = true;
		return;
	}
	if (mem_append(ctx->pOut, argv[0].z, argv[0].n) != 0)
		ctx->is_aborted = true;
}

static void
inverse_group_concat(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1 || argc == 2);
	(void)argc;
	if (mem_is_null(&argv[0]) || mem_is_null(ctx->pOut))
		return;
	assert(mem_is_str(&argv[0]) || mem_is_bin(&argv[0]));
	size_t n = argv[0].n;
	if (argc == 2)
		n += argv[1].n;
	else
		n++;
	if (n >= ctx->pOut->n) {
		mem_set_null(ctx->pOut);
	} else {
		ctx->pOut->n -= n;
		memmove(ctx->pOut->z, &ctx->pOut->z[n], ctx->pOut->n);
	}
}

/** Implementations of the ABS() function. */
#if ENABLE_UB_SANITIZER
static void
func_abs_int(struct sql_context *ctx, int argc, const struct Mem *argv)
  __attribute__((no_sanitize("signed-integer-overflow")));
#endif
static void
func_abs_int(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_int(arg));
	uint64_t u = mem_is_uint(arg) ? arg->u.u : (uint64_t)-arg->u.i;
	mem_set_uint(ctx->pOut, u);
}

static void
func_abs_double(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_double(arg));
	mem_set_double(ctx->pOut, arg->u.r < 0 ? -arg->u.r : arg->u.r);
}

static void
func_abs_dec(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_dec(arg));
	mem_set_dec(ctx->pOut, &arg->u.d);
	decimal_abs(&ctx->pOut->u.d, &ctx->pOut->u.d);
}

/** Implementation of the CHAR_LENGTH() function. */
static void
func_char_length(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_str(arg));
	if (arg->n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	int32_t n = arg->n;
	uint32_t len = 0;
	int32_t offset = 0;
	while (offset < n) {
		UChar32 c;
		U8_NEXT((uint8_t *)arg->z, offset, n, c);
		++len;
	}
	mem_set_uint(ctx->pOut, len);
}

/** Implementation of the UPPER() and LOWER() functions. */
static void
func_lower_upper(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_str(arg));
	if (arg->n == 0)
		return mem_set_str0_static(ctx->pOut, "");
	const char *str = arg->z;
	if (arg->n > SQL_MAX_LENGTH) {
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		ctx->is_aborted = true;
		return;
	}
	int32_t len = arg->n;
	char *res = sql_xmalloc(len);
	UErrorCode status = U_ZERO_ERROR;
	const char *locale = NULL;
	if (ctx->coll != NULL && ctx->coll->type == COLL_TYPE_ICU) {
		locale = ucol_getLocaleByType(ctx->coll->collator,
					      ULOC_VALID_LOCALE, &status);
	}
	UCaseMap *cm = ucasemap_open(locale, 0, &status);
	assert(cm != NULL);
	assert(ctx->func->def->name[0] == 'U' ||
	       ctx->func->def->name[0] == 'L');
	bool is_upper = ctx->func->def->name[0] == 'U';
	int32_t size =
		is_upper ?
		ucasemap_utf8ToUpper(cm, res, len, str, len, &status) :
		ucasemap_utf8ToLower(cm, res, len, str, len, &status);
	if (size > len) {
		res = sql_xrealloc(res, size);
		status = U_ZERO_ERROR;
		if (is_upper)
			ucasemap_utf8ToUpper(cm, res, size, str, len, &status);
		else
			ucasemap_utf8ToLower(cm, res, size, str, len, &status);
	}
	ucasemap_close(cm);
	mem_set_str_allocated(ctx->pOut, res, size);
}

/** Implementation of the NULLIF() function. */
static void
func_nullif(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 2);
	(void)argc;
	if (!mem_is_comparable(&argv[1])) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_TYPE_MISMATCH, mem_str(&argv[1]),
			 "scalar");
		return;
	}
	if (mem_cmp_scalar(&argv[0], &argv[1], ctx->coll) == 0)
		return;
	if (mem_copy(ctx->pOut, &argv[0]) != 0)
		ctx->is_aborted = true;
}

/** Return the position of the last not removed byte. */
static inline size_t
trim_bin_end(const char *str, size_t end, const char *octets,
	     size_t octets_size, int flags)
{
	if ((flags & TRIM_TRAILING) == 0)
		return end;
	while (end > 0) {
		bool is_trimmed = false;
		char c = str[end - 1];
		for (size_t i = 0; i < octets_size && !is_trimmed; ++i)
			is_trimmed = c == octets[i];
		if (!is_trimmed)
			break;
		--end;
	}
	return end;
}

/** Return the position of the first not removed byte. */
static inline size_t
trim_bin_start(const char *str, size_t end, const char *octets,
	       size_t octets_size, int flags)
{
	if ((flags & TRIM_LEADING) == 0)
		return 0;
	size_t start = 0;
	while (start < end) {
		bool is_trimmed = false;
		char c = str[start];
		for (size_t i = 0; i < octets_size && !is_trimmed; ++i)
			is_trimmed = c == octets[i];
		if (!is_trimmed)
			break;
		++start;
	}
	return start;
}

/** Implementation of the TRIM() function for VARBINARY. */
static void
func_trim_bin(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	if (mem_is_null(&argv[0]) || (argc == 3 && mem_is_null(&argv[2])))
		return;
	assert(argc == 2 || (argc == 3 && mem_is_bin(&argv[2])));
	assert(mem_is_bin(&argv[0]) && mem_is_uint(&argv[1]));
	const char *str = argv[0].z;
	size_t size = argv[0].n;
	const char *octets;
	size_t octets_size;
	if (argc == 3) {
		octets = argv[2].z;
		octets_size = argv[2].n;
	} else {
		octets = "\0";
		octets_size = 1;
	}

	int flags = argv[1].u.u;
	size_t end = trim_bin_end(str, size, octets, octets_size, flags);
	size_t start = trim_bin_start(str, end, octets, octets_size, flags);

	if (start >= end)
		return mem_set_bin_static(ctx->pOut, "", 0);
	mem_copy_bin(ctx->pOut, &str[start], end - start);
}

/** Return the position of the last not removed character. */
static inline int32_t
trim_str_end(const char *str, int32_t end, const char *chars,
	     uint8_t *chars_len, size_t chars_count, int flags)
{
	if ((flags & TRIM_TRAILING) == 0)
		return end;
	while (end > 0) {
		bool is_trimmed = false;
		const char *c = chars;
		int32_t len;
		for (size_t i = 0; i < chars_count && !is_trimmed; ++i) {
			len = chars_len[i];
			const char *s = str + end - len;
			is_trimmed = len <= end && memcmp(c, s, len) == 0;
			c += len;
		}
		if (!is_trimmed)
			break;
		assert(len > 0);
		end -= len;
	}
	return end;
}

/** Return the position of the first not removed character. */
static inline int32_t
trim_str_start(const char *str, int32_t end, const char *chars,
	       uint8_t *chars_len, size_t chars_count, int flags)
{
	if ((flags & TRIM_LEADING) == 0)
		return 0;
	int32_t start = 0;
	while (start < end) {
		bool is_trimmed = false;
		const char *c = chars;
		int32_t len;
		for (size_t i = 0; i < chars_count && !is_trimmed; ++i) {
			len = chars_len[i];
			const char *s = str + start;
			is_trimmed = start + len <= end &&
				     memcmp(c, s, len) == 0;
			c += len;
		}
		if (!is_trimmed)
			break;
		assert(len > 0);
		start += len;
	}
	return start;
}

/** Implementation of the TRIM() function for STRING. */
static void
func_trim_str(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	if (mem_is_null(&argv[0]) || (argc == 3 && mem_is_null(&argv[2])))
		return;
	assert(argc == 2 || (argc == 3 && mem_is_str(&argv[2])));
	assert(mem_is_str(&argv[0]) && mem_is_uint(&argv[1]));
	const char *str = argv[0].z;
	if (argv[0].n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	int32_t size = argv[0].n;
	const char *chars;
	int32_t chars_size;
	if (argc == 3) {
		if (argv[2].n > SQL_MAX_LENGTH) {
			ctx->is_aborted = true;
			diag_set(ClientError, ER_SQL_EXECUTE,
				 "string or blob too big");
			return;
		}
		chars = argv[2].z;
		chars_size = argv[2].n;
	} else {
		chars = " ";
		chars_size = 1;
	}

	struct region *region = &fiber()->gc;
	size_t svp = region_used(region);
	uint8_t *chars_len = NULL;
	if (chars_size > 0)
		chars_len = xregion_alloc(region, chars_size);
	size_t chars_count = 0;

	int32_t offset = 0;
	while (offset < chars_size) {
		UChar32 c;
		size_t prev = offset;
		U8_NEXT((uint8_t *)chars, offset, chars_size, c);
		chars_len[chars_count++] = offset - prev;
	}

	uint64_t flags = argv[1].u.u;
	int32_t end = trim_str_end(str, size, chars, chars_len, chars_count,
				   flags);
	int32_t start = trim_str_start(str, end, chars, chars_len, chars_count,
				       flags);
	region_truncate(region, svp);

	if (start >= end)
		return mem_set_str0_static(ctx->pOut, "");
	mem_copy_str(ctx->pOut, &str[start], end - start);
}

/** Implementation of the POSITION() function. */
static void
func_position_octets(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 2);
	(void)argc;
	if (mem_is_any_null(&argv[0], &argv[1]))
		return;
	assert(mem_is_bytes(&argv[0]) && mem_is_bytes(&argv[1]));

	const char *key = argv[0].z;
	const char *str = argv[1].z;
	size_t key_size = argv[0].n;
	size_t str_size = argv[1].n;
	if (key_size <= 0)
		return mem_set_uint(ctx->pOut, 1);
	const char *pos = memmem(str, str_size, key, key_size);
	return mem_set_uint(ctx->pOut, pos == NULL ? 0 : pos - str + 1);
}

static void
func_position_characters(struct sql_context *ctx, int argc,
			 const struct Mem *argv)
{
	assert(argc == 2);
	(void)argc;
	if (mem_is_any_null(&argv[0], &argv[1]))
		return;
	assert(mem_is_str(&argv[0]) && mem_is_str(&argv[1]));
	if (argv[0].n > SQL_MAX_LENGTH || argv[1].n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}

	const char *key = argv[0].z;
	const char *str = argv[1].z;
	int32_t key_size = argv[0].n;
	int32_t str_size = argv[1].n;
	if (key_size <= 0)
		return mem_set_uint(ctx->pOut, 1);

	int32_t key_end = 0;
	int32_t str_end = 0;
	while (key_end < key_size && str_end < str_size) {
		UChar32 c;
		U8_NEXT((uint8_t *)key, key_end, key_size, c);
		U8_NEXT((uint8_t *)str, str_end, str_size, c);
	}
	if (key_end < key_size)
		return mem_set_uint(ctx->pOut, 0);

	struct coll *coll = ctx->coll;
	if (coll->cmp(key, key_size, str, str_end, coll) == 0)
		return mem_set_uint(ctx->pOut, 1);

	int32_t i = 2;
	int32_t str_pos = 0;
	while (str_end < str_size) {
		UChar32 c;
		U8_NEXT((uint8_t *)str, str_pos, str_size, c);
		U8_NEXT((uint8_t *)str, str_end, str_size, c);
		const char *s = str + str_pos;
		if (coll->cmp(key, key_size, s, str_end - str_pos, coll) == 0)
			return mem_set_uint(ctx->pOut, i);
		++i;
	}
	return mem_set_uint(ctx->pOut, 0);
}

/** Implementation of the SUBSTR() function. */
int
substr_normalize(int64_t base_start, bool is_start_neg, uint64_t base_length,
		 uint64_t *start, uint64_t *length)
{
	if (!is_start_neg && base_start > 0) {
		*start = (uint64_t)base_start - 1;
		*length = base_length;
		return 0;
	}
	*start = 0;
	if (base_length == 0) {
		*length = 0;
		return 0;
	}
	/*
	 * We are subtracting 1 from base_length instead of subtracting from
	 * base_start, since base_start can be INT64_MIN. At the same time,
	 * base_length is not less than 1.
	 */
	int64_t a = base_start;
	int64_t b = (int64_t)(base_length - 1);
	int64_t res;
	bool is_neg;
	/*
	 * Integer cannot overflow since non-positive value is added to positive
	 * value.
	 */
	if (sql_add_int(a, a != 0, b, false, &res, &is_neg) != 0) {
		diag_set(ClientError, ER_SQL_EXECUTE, "integer is overflowed");
		return -1;
	}
	*length = is_neg ? 0 : (uint64_t)res;
	return 0;
}

static void
func_substr_octets(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 2 || argc == 3);
	if (mem_is_any_null(&argv[0], &argv[1]))
		return;
	assert(mem_is_bytes(&argv[0]) && mem_is_int(&argv[1]));

	bool is_str = mem_is_str(&argv[0]);
	uint64_t size = argv[0].n;

	if (argc == 2) {
		uint64_t start = mem_is_uint(&argv[1]) && argv[1].u.u > 1 ?
				 argv[1].u.u - 1 : 0;
		if (start >= size) {
			if (is_str)
				return mem_set_str0_static(ctx->pOut, "");
			else
				return mem_set_bin_static(ctx->pOut, "", 0);
		}
		char *s = &argv[0].z[start];
		uint64_t n = size - start;
		if (is_str)
			mem_copy_str(ctx->pOut, s, n);
		else
			mem_copy_bin(ctx->pOut, s, n);
		return;
	}

	assert(argc == 3);
	if (mem_is_null(&argv[2]))
		return;
	assert(mem_is_int(&argv[2]));
	if (!mem_is_uint(&argv[2])) {
		diag_set(ClientError, ER_SQL_EXECUTE, "Length of the result "
			 "cannot be less than 0");
		ctx->is_aborted = true;
		return;
	}
	uint64_t start;
	uint64_t length;
	if (substr_normalize(argv[1].u.i, !mem_is_uint(&argv[1]), argv[2].u.u,
			     &start, &length) != 0) {
		ctx->is_aborted = true;
		return;
	}
	if (start >= size || length == 0) {
		if (is_str)
			return mem_set_str0_static(ctx->pOut, "");
		else
			return mem_set_bin_static(ctx->pOut, "", 0);
	}
	char *str = &argv[0].z[start];
	uint64_t len = MIN(size - start, length);
	if (is_str)
		mem_copy_str(ctx->pOut, str, len);
	else
		mem_copy_bin(ctx->pOut, str, len);
}

static void
func_substr_characters(struct sql_context *ctx, int argc, const
		       struct Mem *argv)
{
	assert(argc == 2 || argc == 3);
	(void)argc;
	if (mem_is_any_null(&argv[0], &argv[1]))
		return;
	assert(mem_is_str(&argv[0]) && mem_is_int(&argv[1]));
	if (argv[0].n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}

	const char *str = argv[0].z;
	int32_t pos = 0;
	int32_t end = argv[0].n;
	if (argc == 2) {
		uint64_t start = mem_is_uint(&argv[1]) && argv[1].u.u > 1 ?
				 argv[1].u.u - 1 : 0;
		for (uint64_t i = 0; i < start && pos < end; ++i) {
			UChar32 c;
			U8_NEXT((uint8_t *)str, pos, end, c);
		}
		if (pos == end)
			return mem_set_str_static(ctx->pOut, "", 0);
		mem_copy_str(ctx->pOut, str + pos, end - pos);
		return;
	}

	assert(argc == 3);
	if (mem_is_null(&argv[2]))
		return;
	assert(mem_is_int(&argv[2]));
	if (!mem_is_uint(&argv[2])) {
		diag_set(ClientError, ER_SQL_EXECUTE, "Length of the result "
			 "cannot be less than 0");
		ctx->is_aborted = true;
		return;
	}
	uint64_t start;
	uint64_t length;
	if (substr_normalize(argv[1].u.i, !mem_is_uint(&argv[1]), argv[2].u.u,
			     &start, &length) != 0) {
		ctx->is_aborted = true;
		return;
	}
	if (length == 0)
		return mem_set_str_static(ctx->pOut, "", 0);

	for (uint64_t i = 0; i < start && pos < end; ++i) {
		UChar32 c;
		U8_NEXT((uint8_t *)str, pos, end, c);
	}
	if (pos == end)
		return mem_set_str_static(ctx->pOut, "", 0);

	int32_t cur = pos;
	for (uint64_t i = 0; i < length && cur < end; ++i) {
		UChar32 c;
		U8_NEXT((uint8_t *)str, cur, end, c);
	}
	assert(cur > pos);
	mem_copy_str(ctx->pOut, str + pos, cur - pos);
}

/**
 * Implementation of the CHAR() function.
 *
 * This function takes zero or more arguments, each of which is an integer. It
 * constructs a string where each character of the string is the unicode
 * character for the corresponding integer argument.
 *
 * If an argument is negative or greater than 0x10ffff, the symbol "�" is used.
 * Symbol '\0' used instead of NULL argument.
 */
static void
func_char(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	if (argc == 0)
		return mem_set_str_static(ctx->pOut, "", 0);
	struct region *region = &fiber()->gc;
	size_t svp = region_used(region);
	UChar32 *buf = xregion_alloc_array(region, typeof(*buf), argc);
	size_t len = 0;
	for (int i = 0; i < argc; ++i) {
		if (mem_is_null(&argv[i]))
			buf[i] = 0;
		else if (!mem_is_uint(&argv[i]) || argv[i].u.u > 0x10ffff)
			buf[i] = 0xfffd;
		else
			buf[i] = argv[i].u.u;
		len += U8_LENGTH(buf[i]);
	}

	char *str = sql_xmalloc(len);
	size_t pos = 0;
	for (int i = 0; i < argc; ++i) {
		UBool is_error = false;
		U8_APPEND((uint8_t *)str, pos, len, buf[i], is_error);
		assert(!is_error);
		(void)is_error;
	}
	region_truncate(region, svp);
	assert(pos == len);
	(void)pos;
	mem_set_str_allocated(ctx->pOut, str, len);
}

/**
 * Implementation of the GREATEST() and LEAST() functions.
 *
 * The GREATEST() function returns the largest of the given arguments.
 * The LEAST() function returns the smallest of the given arguments.
 */
static void
func_greatest_least(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc > 1);
	int mask = ctx->func->def->name[0] == 'G' ? -1 : 0;
	assert(ctx->func->def->name[0] == 'G' ||
	       ctx->func->def->name[0] == 'L');

	if (mem_is_null(&argv[0]))
		return;
	size_t best = 0;
	for (int i = 1; i < argc; ++i) {
		if (mem_is_null(&argv[i]))
			return;
		int cmp = mem_cmp_scalar(&argv[best], &argv[i], ctx->coll);
		if ((cmp ^ mask) >= 0)
			best = i;
	}
	if (mem_copy(ctx->pOut, &argv[best]) != 0)
		ctx->is_aborted = true;
}

/**
 * Implementation of the HEX() function.
 *
 * The HEX() function returns the hexadecimal representation of the argument.
 */
static const char hexdigits[] = {
	'0', '1', '2', '3', '4', '5', '6', '7',
	'8', '9', 'A', 'B', 'C', 'D', 'E', 'F'
};

static void
func_hex(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;

	assert(mem_is_bin(arg));
	if (arg->n == 0)
		return mem_set_str0_static(ctx->pOut, "");

	uint32_t size = 2 * arg->n;
	char *str = sql_xmalloc(size);
	for (size_t i = 0; i < arg->n; ++i) {
		char c = arg->z[i];
		str[2 * i] = hexdigits[(c >> 4) & 0xf];
		str[2 * i + 1] = hexdigits[c & 0xf];
	}
	mem_set_str_allocated(ctx->pOut, str, size);
}

/** Implementation of the OCTET_LENGTH() function. */
static void
func_octet_length(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_bytes(arg));
	mem_set_uint(ctx->pOut, arg->n);
}

/** Implementation of the PRINTF() function. */
static void
func_printf(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	if (argc < 1 || mem_is_null(&argv[0]))
		return;
	if (argc == 1 || !mem_is_str(&argv[0])) {
		char *str = mem_strdup(&argv[0]);
		if (str == NULL)
			ctx->is_aborted = true;
		else
			mem_set_str0_allocated(ctx->pOut, str);
		return;
	}
	struct PrintfArguments pargs;
	struct StrAccum acc;
	char *format = argv[0].z;
	pargs.nArg = argc - 1;
	pargs.nUsed = 0;
	pargs.apArg = argv + 1;
	sqlStrAccumInit(&acc, NULL, 0, SQL_MAX_LENGTH);
	acc.printfFlags = SQL_PRINTF_SQLFUNC;
	sqlXPrintf(&acc, format, &pargs);
	assert(acc.accError == 0 || acc.accError == STRACCUM_TOOBIG);
	if (acc.accError == STRACCUM_TOOBIG) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	mem_set_str_allocated(ctx->pOut, sqlStrAccumFinish(&acc), acc.nChar);
}

/**
 * Implementation of the RANDOM() function.
 *
 * This function returns a random INT64 value.
 */
static void
func_random(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	(void)argc;
	(void)argv;
	int64_t r;
	sql_randomness(sizeof(r), &r);
	mem_set_int_with_sign(ctx->pOut, r, r < 0);
}

/**
 * Implementation of the RANDOMBLOB() function.
 *
 * This function returns a random VARBINARY value. The size of this value is
 * specified as an argument of the function.
 */
static void
func_randomblob(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	assert(mem_is_null(arg) || mem_is_int(arg));
	if (mem_is_null(arg) || !mem_is_uint(arg))
		return;
	if (arg->u.u == 0)
		return mem_set_bin_static(ctx->pOut, "", 0);
	uint64_t len = arg->u.u;
	if (len > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	char *res = sql_xmalloc(len);
	sql_randomness(len, res);
	mem_set_bin_allocated(ctx->pOut, res, len);
}

/**
 * Implementation of the ZEROBLOB() function.
 *
 * This function returns a zero-filled VARBINARY value. The size of this value
 * is specified as an argument of the function.
 */
static void
func_zeroblob(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	assert(mem_is_null(arg) || mem_is_int(arg));
	if (mem_is_null(arg) || !mem_is_uint(arg))
		return;
	if (arg->u.u == 0)
		return mem_set_bin_static(ctx->pOut, "", 0);
	uint64_t len = arg->u.u;
	if (len > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	char *res = sql_xmalloc0(len);
	mem_set_bin_allocated(ctx->pOut, res, len);
}

/** Implementation of the TYPEOF() function. */
static void
func_typeof(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	return mem_set_str0_static(ctx->pOut, mem_type_to_str(&argv[0]));
}

/** Implementation of the ROUND() function for DOUBLE argument. */
static void
func_round_double(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1 || argc == 2);
	if (mem_is_null(&argv[0]) || (argc == 2 && mem_is_null(&argv[1])))
		return;
	assert(mem_is_double(&argv[0]));
	assert(argc == 1 || mem_is_int(&argv[1]));
	uint64_t n = (argc == 2 && mem_is_uint(&argv[1])) ? argv[1].u.u : 0;
	/*
	 * The smallest positive double value is 2.225E-307, and the value
	 * before the exponent has a maximum of 15 digits after the decimal
	 * point. This means that double values cannot have more than 307 + 15
	 * digits after the decimal point.
	 */
	if (n > 322)
		return mem_copy_as_ephemeral(ctx->pOut, &argv[0]);

	double d = argv[0].u.r;
	struct Mem *res = ctx->pOut;
	if (n != 0) {
		d = atof(tt_sprintf("%.*lf", (int)n, d));
		return mem_set_double(res, d);
	}
	/*
	 * DOUBLE values greater than 2^53 or less than -2^53 have no digits
	 * after the decimal point.
	 */
	assert(9007199254740992 == (int64_t)1 << 53);
	if (d <= -9007199254740992.0 || d >= 9007199254740992.0)
		return mem_set_double(res, d);
	double delta = d < 0 ? -0.5 : 0.5;
	return mem_set_double(res, (double)(int64_t)(d + delta));
}

/** Implementation of the ROUND() function for DECIMAL argument. */
static void
func_round_dec(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1 || argc == 2);
	if (mem_is_null(&argv[0]) || (argc == 2 && mem_is_null(&argv[1])))
		return;
	assert(mem_is_dec(&argv[0]));
	assert(argc == 1 || mem_is_int(&argv[1]));
	uint64_t n = (argc == 2 && mem_is_uint(&argv[1])) ? argv[1].u.u : 0;

	mem_set_dec(ctx->pOut, &argv[0].u.d);
	if (n < DECIMAL_MAX_DIGITS)
		decimal_round(&ctx->pOut->u.d, n);
}

/** Implementation of the ROUND() function for INTEGER argument. */
static void
func_round_int(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1 || argc == 2);
	if (mem_is_null(&argv[0]) || (argc == 2 && mem_is_null(&argv[1])))
		return;
	assert(mem_is_int(&argv[0]));
	assert(argc == 1 || mem_is_int(&argv[1]));
	return mem_copy_as_ephemeral(ctx->pOut, &argv[0]);
}

/** Implementation of the ROW_COUNT() function. */
static void
func_row_count(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	(void)argc;
	(void)argv;
	assert(sql_get()->nChange >= 0);
	return mem_set_uint(ctx->pOut, sql_get()->nChange);
}

/**
 * Implementation of the UUID() function.
 *
 * Returns a randomly generated UUID value.
 */
static void
func_uuid(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	if (argc == 1) {
		if (mem_is_null(&argv[0]))
			return;
		if (!mem_is_uint(&argv[0]) || argv[0].u.u != 4) {
			diag_set(ClientError, ER_UNSUPPORTED, "Function UUID",
				 "versions other than 4");
			ctx->is_aborted = true;
			return;
		}
	}
	struct tt_uuid uuid;
	tt_uuid_create(&uuid);
	mem_set_uuid(ctx->pOut, &uuid);
}

/**
 * Implementation of the JSON_NULL() function.
 *
 * A JSON null is distinct from SQL NULL: SQL NULL means "no value" (IS NULL is
 * true), JSON null is a present value whose content is the literal null (IS
 * NULL is false).
 */
static void
func_json_null(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 0);
	(void)argc;
	(void)argv;
	/*
	 * What mp_encode_json() emits for a one-byte nil payload: fixext1
	 * (0xd4), subtype MP_JSON, MP_NIL (0xc0). A constant keeps the
	 * function allocation- and branch-free.
	 */
	static const char json_null_mp[] = {(char)0xd4, MP_JSON, (char)0xc0};
	mem_set_json_static(ctx->pOut, (char *)json_null_mp,
			    sizeof(json_null_mp));
}

/**
 * Implementation of the JSON_PARSE() function.
 *
 * Parses the string argument as a JSON document. The numeric-literal rules
 * match SQL's own, and a malformed document or an out-of-range literal raises
 * the error SQL raises for that literal. SQL NULL yields SQL NULL.
 */
static void
func_json_parse(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_str(arg));
	if (mem_set_json_text(ctx->pOut, arg->z, arg->n) != 0)
		ctx->is_aborted = true;
}

/** Implementation of the VERSION() function. */
static void
func_version(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	(void)argc;
	(void)argv;
	return mem_set_str0_static(ctx->pOut, (char *)tarantool_version());
}

/**
 * Implementation of the UNICODE() function.
 *
 * Return the Unicode code point value for the first character of the input
 * string.
 */
static void
func_unicode(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	(void)argc;
	const struct Mem *arg = &argv[0];
	if (mem_is_null(arg))
		return;
	assert(mem_is_str(arg));
	if (arg->n == 0)
		return mem_set_uint(ctx->pOut, 0);
	if (arg->n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}

	int32_t pos = 0;
	int32_t n = arg->n;
	UChar32 c;
	U8_NEXT((uint8_t *)arg->z, pos, n, c);
	(void)pos;
	mem_set_uint(ctx->pOut, (uint64_t)c);
}

/**
 * Implementation of the NOW() function.
 *
 * Return the current date and time.
 */
static void
func_now(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 0);
	(void)argc;
	(void)argv;
	struct datetime dt;
	datetime_ev_now(&dt);
	mem_set_datetime(ctx->pOut, &dt);
}

/**
 * Implementation of the TO_CHAR() function.
 */
static void
func_to_char(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 2);
	(void)argc;
	const struct Mem *date = &argv[0];
	const struct Mem *fmt = &argv[1];
	if (mem_is_any_null(date, fmt))
		return;
	assert(mem_is_datetime(date) && mem_is_str(fmt));
	if (fmt->n > SQL_MAX_LENGTH) {
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	struct region *region = &fiber()->gc;
	size_t svp = region_used(region);
	/* tt_cstr() truncates long strings. */
	char *format = xregion_alloc(region, fmt->n + 1);
	memcpy(format, fmt->z, fmt->n);
	format[fmt->n] = '\0';
	char buf[128];
	char *res = buf;
	size_t len = datetime_strftime(&date->u.dt, buf, sizeof(buf), format);
	/* A short format can expand to a long result, e.g. "%c". */
	if (len > SQL_MAX_LENGTH) {
		region_truncate(region, svp);
		ctx->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	if (len >= sizeof(buf)) {
		res = xregion_alloc(region, len + 1);
		datetime_strftime(&date->u.dt, res, len + 1, format);
	}
	mem_copy_str(ctx->pOut, res, len);
	region_truncate(region, svp);
}

/**
 * Implementation of the DATE_PART() function.
 *
 * Returns the requested information from a DATETIME value.
 */
static void
func_date_part(struct sql_context *ctx, int argc, const struct Mem *argv)
{
	assert(argc == 2);
	(void)argc;
	const struct Mem *part = &argv[0];
	const struct Mem *date = &argv[1];
	if (mem_is_any_null(part, date))
		return;
	assert(mem_is_str(part) && mem_is_datetime(date));
	const char *str = tt_cstr(part->z, part->n);
	const struct datetime *dt = &date->u.dt;
	if (strcasecmp("millennium", str) == 0)
		return mem_set_int(ctx->pOut, datetime_millennium(dt));
	if (strcasecmp("century", str) == 0)
		return mem_set_int(ctx->pOut, datetime_century(dt));
	if (strcasecmp("decade", str) == 0)
		return mem_set_int(ctx->pOut, datetime_decade(dt));
	if (strcasecmp("year", str) == 0)
		return mem_set_int(ctx->pOut, datetime_year(dt));
	if (strcasecmp("quarter", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_quarter(dt));
	if (strcasecmp("month", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_month(dt));
	if (strcasecmp("week", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_week(dt));
	if (strcasecmp("day", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_day(dt));
	if (strcasecmp("dow", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_dow(dt));
	if (strcasecmp("doy", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_doy(dt));
	if (strcasecmp("hour", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_hour(dt));
	if (strcasecmp("minute", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_min(dt));
	if (strcasecmp("second", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_sec(dt));
	if (strcasecmp("millisecond", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_msec(dt));
	if (strcasecmp("microsecond", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_usec(dt));
	if (strcasecmp("nanosecond", str) == 0)
		return mem_set_uint(ctx->pOut, datetime_nsec(dt));
	if (strcasecmp("epoch", str) == 0)
		return mem_set_int(ctx->pOut, datetime_epoch(dt));
	if (strcasecmp("timezone_offset", str) == 0)
		return mem_set_int(ctx->pOut, datetime_tzoffset(dt));
}

#define Utf8Read(s, e) \
	ucnv_getNextUChar(icu_utf8_conv, &(s), (e), &status)

#define SQL_END_OF_STRING        0xffff
#define SQL_INVALID_UTF8_SYMBOL  0xfffd

/**
 * Returns codes from sql_utf8_pattern_compare().
 */
enum pattern_match_status {
	MATCH = 0,
	NO_MATCH = 1,
	/** No match in spite of having * or % wildcards. */
	NO_WILDCARD_MATCH = 2,
	/** Pattern contains invalid UTF-8 symbol. */
	INVALID_PATTERN = 3
};

/**
 * Read an UTF-8 character from string, and move pointer to the
 * next character. Save current character and its length to output
 * params - they are served as arguments of coll->cmp() call.
 *
 * @param[out] str Ptr to string.
 * @param str_end Ptr the last symbol in @str.
 * @param[out] char_ptr Ptr to the UTF-8 character.
 * @param[out] char_len Ptr to length of the UTF-8 character in
 * bytes.
 *
 * @retval UTF-8 character.
 */
static UChar32
step_utf8_char(const char **str, const char *str_end, const char **char_ptr,
	       size_t *char_len)
{
	UErrorCode status = U_ZERO_ERROR;
	*char_ptr = *str;
	UChar32 next_utf8 = Utf8Read(*str, str_end);
	*char_len = *str - *char_ptr;
	return next_utf8;
}

/**
 * Compare two UTF-8 strings for equality where the first string
 * is a LIKE expression.
 *
 * Like matching rules:
 *
 *      '%'       Matches any sequence of zero or more
 *                characters.
 *
 *      '_'       Matches any one character.
 *
 *      Ec        Where E is the "esc" character and c is any
 *                other character, including '%', '_', and esc,
 *                match exactly c.
 *
 * This routine is usually quick, but can be N**2 in the worst
 * case.
 *
 * 'pattern_end' and 'string_end' params are used to determine
 * the end of strings, because '\0' is not supposed to be
 * end-of-string signal.
 *
 * @param pattern String containing comparison pattern.
 * @param string String being compared.
 * @param pattern_end Ptr to pattern last symbol.
 * @param string_end Ptr to string last symbol.
 * @param coll Pointer to collation.
 * @param match_other The escape char for LIKE.
 *
 * @retval One of pattern_match_status values.
 */
static int
sql_utf8_pattern_compare(const char *pattern,
			 const char *string,
			 const char *pattern_end,
			 const char *string_end,
			 struct coll *coll,
			 UChar32 match_other)
{
	/* Next pattern and input string chars. */
	UChar32 c, c2;
	/* One past the last escaped input char. */
	const char *zEscaped = 0;
	UErrorCode status = U_ZERO_ERROR;
	const char *pat_char_ptr = NULL;
	const char *str_char_ptr = NULL;
	size_t pat_char_len = 0;
	size_t str_char_len = 0;

	while (pattern < pattern_end) {
		c = step_utf8_char(&pattern, pattern_end, &pat_char_ptr,
				   &pat_char_len);
		if (c == SQL_INVALID_UTF8_SYMBOL)
			return INVALID_PATTERN;
		if (c == MATCH_ALL_WILDCARD) {
			/*
			 * Skip over multiple "%" characters in
			 * the pattern. If there are also "_"
			 * characters, skip those as well, but
			 * consume a single character of the
			 * input string for each "_" skipped.
			 */
			while ((c = step_utf8_char(&pattern, pattern_end,
						   &pat_char_ptr,
						   &pat_char_len)) !=
			       SQL_END_OF_STRING) {
				if (c == SQL_INVALID_UTF8_SYMBOL)
					return INVALID_PATTERN;
				if (c == MATCH_ONE_WILDCARD) {
					c2 = Utf8Read(string, string_end);
					if (c2 == SQL_INVALID_UTF8_SYMBOL)
						return NO_MATCH;
					if (c2 == SQL_END_OF_STRING)
						return NO_WILDCARD_MATCH;
				} else if (c != MATCH_ALL_WILDCARD) {
					break;
				}
			}
			/*
			 * "%" at the end of the pattern matches.
			 */
			if (c == SQL_END_OF_STRING) {
				return MATCH;
			}
			if (c == match_other) {
				c = step_utf8_char(&pattern, pattern_end,
						   &pat_char_ptr,
						   &pat_char_len);
				if (c == SQL_INVALID_UTF8_SYMBOL)
					return INVALID_PATTERN;
				if (c == SQL_END_OF_STRING)
					return NO_WILDCARD_MATCH;
			}

			/*
			 * At this point variable c contains the
			 * first character of the pattern string
			 * past the "%". Search in the input
			 * string for the first matching
			 * character and recursively continue the
			 * match from that point.
			 *
			 * For a case-insensitive search, set
			 * variable cx to be the same as c but in
			 * the other case and search the input
			 * string for either c or cx.
			 */

			int bMatch;
			while (string < string_end){
				/*
				 * This loop could have been
				 * implemented without if
				 * converting c2 to lower case
				 * by holding c_upper and
				 * c_lower,however it is
				 * implemented this way because
				 * lower works better with German
				 * and Turkish languages.
				 */
				c2 = step_utf8_char(&string, string_end,
						    &str_char_ptr,
						    &str_char_len);
				if (c2 == SQL_INVALID_UTF8_SYMBOL)
					return NO_MATCH;
				if (coll->cmp(pat_char_ptr, pat_char_len,
					      str_char_ptr, str_char_len, coll)
					!= 0)
					continue;
				bMatch = sql_utf8_pattern_compare(pattern,
								  string,
								  pattern_end,
								  string_end,
								  coll,
								  match_other);
				if (bMatch != NO_MATCH)
					return bMatch;
			}
			return NO_WILDCARD_MATCH;
		}
		if (c == match_other) {
			c = step_utf8_char(&pattern, pattern_end, &pat_char_ptr,
					   &pat_char_len);
			if (c == SQL_INVALID_UTF8_SYMBOL)
				return INVALID_PATTERN;
			if (c == SQL_END_OF_STRING)
				return NO_MATCH;
			zEscaped = pattern;
		}
		c2 = step_utf8_char(&string, string_end, &str_char_ptr,
				    &str_char_len);
		if (c2 == SQL_INVALID_UTF8_SYMBOL)
			return NO_MATCH;
		if (coll->cmp(pat_char_ptr, pat_char_len, str_char_ptr,
			      str_char_len, coll) == 0)
			continue;
		if (c == MATCH_ONE_WILDCARD && pattern != zEscaped &&
		    c2 != SQL_END_OF_STRING)
			continue;
		return NO_MATCH;
	}
	return string == string_end ? MATCH : NO_MATCH;
}

/**
 * Implementation of the like() SQL function. This function
 * implements the built-in LIKE operator. The first argument to
 * the function is the pattern and the second argument is the
 * string. So, the SQL statements of the following type:
 *
 *       A LIKE B
 *
 * are implemented as like(B,A).
 *
 * Both arguments (A and B) must be of type TEXT. If one arguments
 * is NULL then result is NULL as well.
 */
static void
likeFunc(sql_context *context, int argc, const struct Mem *argv)
{
	u32 escape = SQL_END_OF_STRING;
	assert(argc == 2 || argc == 3);
	if (mem_is_any_null(&argv[0], &argv[1]))
		return;
	assert(mem_is_str(&argv[0]) && mem_is_str(&argv[1]));
	if (argv[0].n > SQL_MAX_LENGTH || argv[1].n > SQL_MAX_LENGTH) {
		context->is_aborted = true;
		diag_set(ClientError, ER_SQL_EXECUTE, "string or blob too big");
		return;
	}
	const char *zB = argv[0].z;
	const char *zA = argv[1].z;
	const char *zB_end = zB + argv[0].n;
	const char *zA_end = zA + argv[1].n;

	/*
	 * Limit the length of the LIKE pattern to avoid problems
	 * of deep recursion and N*N behavior in
	 * sql_utf8_pattern_compare().
	 */
	int32_t nPat = argv[0].n;
	if (nPat > sql_get()->aLimit[SQL_LIMIT_LIKE_PATTERN_LENGTH]) {
		diag_set(ClientError, ER_SQL_EXECUTE, "LIKE pattern is too "\
			 "complex");
		context->is_aborted = true;
		return;
	}

	if (argc == 3) {
		if (mem_is_null(&argv[2]))
			return;
		assert(mem_is_str(&argv[2]));
		if (argv[2].n > SQL_MAX_LENGTH) {
			context->is_aborted = true;
			diag_set(ClientError, ER_SQL_EXECUTE,
				 "string or blob too big");
			return;
		}
		/*
		 * The escape character string must consist of a
		 * single UTF-8 character. Otherwise, return an
		 * error.
		 */
		const char *str = argv[2].z;
		int32_t pos = 0;
		int32_t end = argv[2].n;
		if (end != 0)
			U8_NEXT((uint8_t *)str, pos, end, escape);
		if (end == 0 || pos != end) {
			diag_set(ClientError, ER_SQL_EXECUTE, "ESCAPE "\
				 "expression must be a single character");
			context->is_aborted = true;
			return;
		}
	}
	if (!zA || !zB)
		return;
	int res;
	struct coll *coll = context->coll;
	assert(coll != NULL);
	res = sql_utf8_pattern_compare(zB, zA, zB_end, zA_end, coll, escape);

	if (res == INVALID_PATTERN) {
		diag_set(ClientError, ER_SQL_EXECUTE, "LIKE pattern can only "\
			 "contain UTF-8 characters");
		context->is_aborted = true;
		return;
	}
	mem_set_bool(context->pOut, res == MATCH);
}

/*
 * Implementation of the QUOTE() function.  This function takes a single
 * argument.  If the argument is numeric, the return value is the same as
 * the argument.  If the argument is NULL, the return value is the string
 * "NULL".  Otherwise, the argument is enclosed in single quotes with
 * single-quote escapes.
 */
static void
quoteFunc(struct sql_context *context, int argc, const struct Mem *argv)
{
	assert(argc == 1);
	UNUSED_PARAMETER(argc);
	switch (argv[0].type) {
	case MEM_TYPE_UUID: {
		char buf[UUID_STR_LEN + 1];
		tt_uuid_to_string(&argv[0].u.uuid, &buf[0]);
		mem_copy_str(context->pOut, buf, UUID_STR_LEN);
		break;
	}
	case MEM_TYPE_DATETIME: {
		char buf[DT_TO_STRING_BUFSIZE];
		uint32_t len = datetime_to_string(&context->pOut->u.dt, buf,
						  DT_TO_STRING_BUFSIZE);
		assert(len == strlen(buf));
		mem_copy_str(context->pOut, buf, len);
		break;
	}
	case MEM_TYPE_INTERVAL: {
		char buf[DT_IVAL_TO_STRING_BUFSIZE];
		uint32_t len = interval_to_string(&context->pOut->u.itv, buf,
						  DT_IVAL_TO_STRING_BUFSIZE);
		assert(len == strlen(buf));
		mem_copy_str(context->pOut, buf, len);
		break;
	}
	case MEM_TYPE_DOUBLE:
	case MEM_TYPE_DEC:
	case MEM_TYPE_UINT:
	case MEM_TYPE_INT: {
		if (mem_copy(context->pOut, &argv[0]) != 0)
			context->is_aborted = true;
		break;
	}
	case MEM_TYPE_MAP:
	case MEM_TYPE_ARRAY:
	case MEM_TYPE_JSON: {
		char *buf = NULL;
		int size = mp_snprint(buf, 0, argv[0].z) + 1;
		assert(size > 0);
		buf = sql_xmalloc(size);
		mp_snprint(buf, size, argv[0].z);
		mem_set_str0_allocated(context->pOut, buf);
		break;
	}
	case MEM_TYPE_BIN: {
		const char *zBlob = argv[0].z;
		size_t nBlob = argv[0].n;
		uint32_t size = 2 * nBlob + 3;
		char *zText = sql_xmalloc(size);
		for (size_t i = 0; i < nBlob; i++) {
			zText[(i * 2) + 2] = hexdigits[(zBlob[i] >> 4) & 0x0F];
			zText[(i * 2) + 3] = hexdigits[(zBlob[i]) & 0x0F];
		}
		zText[(nBlob * 2) + 2] = '\'';
		zText[0] = 'X';
		zText[1] = '\'';
		mem_set_str_allocated(context->pOut, zText, size);
		break;
	}
	case MEM_TYPE_STR: {
		const char *str = argv[0].z;
		uint32_t len = argv[0].n;
		uint32_t count = 0;
		for (uint32_t i = 0; i < len; ++i) {
			if (str[i] == '\'')
				++count;
		}
		uint32_t size = len + count + 2;

		char *res = sql_xmalloc(size);
		res[0] = '\'';
		for (uint32_t i = 0, j = 1; i < len; ++i) {
			res[j++] = str[i];
			if (str[i] == '\'')
				res[j++] = '\'';
		}
		res[size - 1] = '\'';
		mem_set_str_allocated(context->pOut, res, size);
		break;
	}
	case MEM_TYPE_BOOL: {
		mem_set_str0_static(context->pOut,
				    SQL_TOKEN_BOOLEAN(argv[0].u.b));
		break;
	}
	default:{
		assert(mem_is_null(&argv[0]));
		mem_set_str0_static(context->pOut, "NULL");
	}
	}
}

/*
 * The replace() function.  Three arguments are all strings: call
 * them A, B, and C. The result is also a string which is derived
 * from A by replacing every occurrence of B with C.  The match
 * must be exact.  Collating sequences are not used.
 */
static void
replaceFunc(struct sql_context *context, int argc, const struct Mem *argv)
{
	const unsigned char *zStr;	/* The input string A */
	const unsigned char *zPattern;	/* The pattern string B */
	const unsigned char *zRep;	/* The replacement string C */
	unsigned char *zOut;	/* The output */
	/* Size of zStr. */
	size_t nStr;
	/* Size of zPattern. */
	size_t nPattern;
	/* Size of zRep. */
	size_t nRep;
	/* Maximum size of zOut. */
	size_t nOut;
	/* Last zStr[] that might match zPattern[]. */
	size_t loopLimit;
	/* Loop counters. */
	size_t i, j;

	assert(argc == 3);
	(void)argc;
	if (mem_is_any_null(&argv[0], &argv[1]) || mem_is_null(&argv[2]))
		return;
	assert(mem_is_bytes(&argv[0]) && mem_is_bytes(&argv[1]) &&
	       mem_is_bytes(&argv[2]));
	zStr = (const unsigned char *)argv[0].z;
	nStr = argv[0].n;
	zPattern = (const unsigned char *)argv[1].z;
	nPattern = argv[1].n;
	if (nPattern == 0 || nPattern > nStr) {
		/* Copy string if it is not empty. */
		if (nStr == 0)
			mem_set_str_static(context->pOut, "", 0);
		else if (mem_copy(context->pOut, &argv[0]) != 0)
			context->is_aborted = true;
		return;
	}
	zRep = (const unsigned char *)argv[2].z;
	nRep = argv[2].n;
	nOut = nStr + 1;
	zOut = sql_xmalloc(nOut);
	loopLimit = nStr - nPattern;
	for (i = j = 0; i <= loopLimit; i++) {
		if (zStr[i] != zPattern[0]
		    || memcmp(&zStr[i], zPattern, nPattern)) {
			zOut[j++] = zStr[i];
		} else {
			nOut += nRep - nPattern;
			if (nOut > SQL_MAX_LENGTH) {
				sql_xfree(zOut);
				context->is_aborted = true;
				diag_set(ClientError, ER_SQL_EXECUTE,
					 "string or blob too big");
				return;
			}
			zOut = sql_xrealloc(zOut, nOut);
			memcpy(&zOut[j], zRep, nRep);
			j += nRep;
			i += nPattern - 1;
		}
	}
	assert(j + nStr - i + 1 == nOut);
	memcpy(&zOut[j], &zStr[i], nStr - i);
	j += nStr - i;
	assert(j <= nOut);
	zOut[j] = 0;
	if (context->func->def->returns == FIELD_TYPE_STRING)
		mem_set_str_allocated(context->pOut, (char *)zOut, j);
	else
		mem_set_bin_allocated(context->pOut, (char *)zOut, j);
}

/*
 * Compute the soundex encoding of a word.
 *
 * IMP: R-59782-00072 The soundex(X) function returns a string that is the
 * soundex encoding of the string X.
 */
static void
soundexFunc(struct sql_context *context, int argc, const struct Mem *argv)
{
	(void) argc;
	char zResult[8];
	const u8 *zIn;
	int i, j;
	static const unsigned char iCode[] = {
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 1, 2, 3, 0, 1, 2, 0, 0, 2, 2, 4, 5, 5, 0,
		1, 2, 6, 2, 3, 0, 1, 0, 2, 0, 2, 0, 0, 0, 0, 0,
		0, 0, 1, 2, 3, 0, 1, 2, 0, 0, 2, 2, 4, 5, 5, 0,
		1, 2, 6, 2, 3, 0, 1, 0, 2, 0, 2, 0, 0, 0, 0, 0,
	};
	assert(argc == 1);
	assert(mem_is_null(&argv[0]) || mem_is_str(&argv[0]));
	if (mem_is_null(&argv[0]) || argv[0].n == 0)
		zIn = (u8 *) "";
	else
		zIn = (unsigned char *)argv[0].z;
	for (i = 0; zIn[i] && !sqlIsalpha(zIn[i]); i++) {
	}
	if (zIn[i]) {
		u8 prevcode = iCode[zIn[i] & 0x7f];
		zResult[0] = sqlToupper(zIn[i]);
		for (j = 1; j < 4 && zIn[i]; i++) {
			int code = iCode[zIn[i] & 0x7f];
			if (code > 0) {
				if (code != prevcode) {
					prevcode = code;
					zResult[j++] = code + '0';
				}
			} else {
				prevcode = 0;
			}
		}
		while (j < 4) {
			zResult[j++] = '0';
		}
		zResult[j] = 0;
		mem_copy_str(context->pOut, zResult, 4);
	} else {
		mem_set_str_static(context->pOut, "?000", 4);
	}
}

int
sql_is_like_func(struct Expr *expr)
{
	if (expr->op != TK_FUNCTION || !expr->x.pList ||
	    expr->x.pList->nExpr != 2)
		return 0;
	assert(!ExprHasProperty(expr, EP_xIsSelect));
	struct func *func = sql_func_find(expr);
	if (func == NULL || !sql_func_flag_is_set(func, SQL_FUNC_LIKE))
		return 0;
	return 1;
}

static int
func_sql_builtin_call_stub(struct func *func, struct port *args,
			   struct port *ret)
{
	(void) func; (void) args; (void) ret;
	diag_set(ClientError, ER_UNSUPPORTED,
		 "sql builtin function", "Lua frontend");
	return -1;
}

static void
sql_builtin_stub(sql_context *ctx, int argc, const struct Mem *argv)
{
	(void) argc; (void) argv;
	diag_set(ClientError, ER_SQL_EXECUTE,
		 tt_sprintf("function '%s' is not implemented",
			    ctx->func->def->name));
	ctx->is_aborted = true;
}

/**
 * A structure that defines the relationship between a function and its
 * implementations.
 */
 struct sql_func_dictionary {
	/** Name of the function. */
	const char *name;
	/** The minimum number of arguments for all implementations. */
	int32_t argc_min;
	/** The maximum number of arguments for all implementations. */
	int32_t argc_max;
	/** Additional informations about the function. */
	uint32_t flags;
	/**
	 * True if the function is deterministic (can give only one result with
	 * the given arguments).
	 */
	bool is_deterministic;
	/** Count of function's implementations. */
	uint32_t count;
	/** Array of function implementations. */
	struct func_sql_builtin **functions;
};

static struct sql_func_dictionary dictionaries[] = {
	{"ABS", 1, 1, 0, true, 0, NULL},
	{"AVG", 1, 1, SQL_FUNC_AGG, false, 0, NULL},
	{"CHAR", 0, SQL_MAX_FUNCTION_ARG, 0, true, 0, NULL},
	{"CHARACTER_LENGTH", 1, 1, 0, true, 0, NULL},
	{"CHAR_LENGTH", 1, 1, 0, true, 0, NULL},
	{"COALESCE", 2, SQL_MAX_FUNCTION_ARG, SQL_FUNC_COALESCE, true, 0, NULL},
	{"COUNT", 0, 1, SQL_FUNC_AGG, false, 0, NULL},
	{"DATE_PART", 2, 2, 0, true, 0, NULL},
	{"GREATEST", 2, SQL_MAX_FUNCTION_ARG, SQL_FUNC_NEEDCOLL, true, 0, NULL},
	{"GROUP_CONCAT", 1, 2, SQL_FUNC_AGG, false, 0, NULL},
	{"HEX", 1, 1, 0, true, 0, NULL},
	{"IFNULL", 2, 2, SQL_FUNC_COALESCE, true, 0, NULL},
	{"JSON_NULL", 0, 0, 0, true, 0, NULL},
	{"JSON_PARSE", 1, 1, 0, true, 0, NULL},
	{"LAST_VALUE", 1, 1, SQL_FUNC_WINDOW, false, 0, NULL},
	{"LEAST", 2, SQL_MAX_FUNCTION_ARG, SQL_FUNC_NEEDCOLL, true, 0, NULL},
	{"LENGTH", 1, 1, SQL_FUNC_LENGTH, true, 0, NULL},
	{"LIKE", 2, 3, SQL_FUNC_LIKE | SQL_FUNC_NEEDCOLL, true, 0, NULL},
	{"LIKELIHOOD", 2, 2, SQL_FUNC_UNLIKELY, true, 0, NULL},
	{"LIKELY", 1, 1, SQL_FUNC_UNLIKELY, true, 0, NULL},
	{"LOWER", 1, 1, SQL_FUNC_DERIVEDCOLL | SQL_FUNC_NEEDCOLL, true, 0,
	 NULL},
	{"MAX", 1, 1, SQL_FUNC_MAX | SQL_FUNC_AGG | SQL_FUNC_NEEDCOLL,
	 false, 0, NULL},
	{"MIN", 1, 1, SQL_FUNC_MIN | SQL_FUNC_AGG | SQL_FUNC_NEEDCOLL, false,
	 0, NULL},
	{"NOW", 0, 0, 0, true, 0, NULL},
	{"NULLIF", 2, 2, SQL_FUNC_NEEDCOLL, true, 0, NULL},
	{"POSITION", 2, 2, SQL_FUNC_NEEDCOLL, true, 0, NULL},
	{"PRINTF", 0, SQL_MAX_FUNCTION_ARG, 0, true, 0, NULL},
	{"QUOTE", 1, 1, 0, true, 0, NULL},
	{"RANDOM", 0, 0, 0, false, 0, NULL},
	{"RANDOMBLOB", 1, 1, 0, false, 0, NULL},
	{"REPLACE", 3, 3, SQL_FUNC_DERIVEDCOLL, true, 0, NULL},
	{"ROUND", 1, 2, 0, true, 0, NULL},
	{"ROW_COUNT", 0, 0, 0, true, 0, NULL},
	{"ROW_NUMBER", 0, 0, SQL_FUNC_WINDOW, false, 0, NULL},
	{"SOUNDEX", 1, 1, 0, true, 0, NULL},
	{"SUBSTR", 2, 3, SQL_FUNC_DERIVEDCOLL, true, 0, NULL},
	{"SUM", 1, 1, SQL_FUNC_AGG, false, 0, NULL},
	{"TO_CHAR", 2, 2, 0, true, 0, NULL},
	{"TOTAL", 1, 1, SQL_FUNC_AGG, false, 0, NULL},
	{"TRIM", 2, 3, SQL_FUNC_DERIVEDCOLL, true, 0, NULL},
	{"TYPEOF", 1, 1, SQL_FUNC_TYPEOF, true, 0, NULL},
	{"UNICODE", 1, 1, 0, true, 0, NULL},
	{"UNLIKELY", 1, 1, SQL_FUNC_UNLIKELY, true, 0, NULL},
	{"UPPER", 1, 1, SQL_FUNC_DERIVEDCOLL | SQL_FUNC_NEEDCOLL, true, 0,
	 NULL},
	{"UUID", 0, 1, 0, false, 0, NULL},
	{"VERSION", 0, 0, 0, true, 0, NULL},
	{"ZEROBLOB", 1, 1, 0, true, 0, NULL},
};

static bool
sql_builtin_func_is_reserved(const char *name, uint32_t name_len)
{
	for (uint32_t i = 0; i < nelem(dictionaries); i++) {
		const char *builtin_name = dictionaries[i].name;
		if (name_is_equal(name, name_len, builtin_name,
				  strlen(builtin_name)))
			return true;
	}
	return false;
}

/**
 * The structure that defines the implementation of the function. These
 * definitions are used during initialization to create all descibed
 * implementations of all built-in SQL functions.
 */
struct sql_func_definition {
	/** Name of the function. */
	const char *name;
	/** The number of arguments of the implementation. */
	int32_t argc;
	/**
	 * Types of implementation arguments. Only the first three arguments are
	 * described, but this should be sufficient, since all built-in SQL
	 * functions either have up to three arguments, or the number of their
	 * arguments is not limited here (but limited globally). If a function
	 * has an unlimited number of arguments, all arguments are of the same
	 * type.
	 */
	enum field_type argt[3];
	/** Type of the result of the implementation. */
	enum field_type result;
	/** Call implementation with given arguments. */
	void (*call)(sql_context *ctx, int argc, const struct Mem *argv);
	/** Call finalization function for this implementation. */
	int (*finalize)(struct Mem *mem);
	/** Current aggregated value. */
	int (*value)(struct Mem *mem);
	/** Inverse aggregation step. */
	void (*inverse)(sql_context * ctx, int argc, const struct Mem *argv);

};

/**
 * Array of function implementation definitions. All implementations of the same
 * function should be defined in succession.
 */
static struct sql_func_definition definitions[] = {
	{"ABS", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, func_abs_dec,
	 NULL, NULL, NULL},
	{"ABS", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER, func_abs_int,
	 NULL, NULL, NULL},
	{"ABS", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, func_abs_double,
	 NULL, NULL, NULL},
	{"AVG", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, step_avg, fin_avg,
	 fin_avg, inverse_avg},
	{"AVG", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_DECIMAL, step_avg, fin_avg,
	 fin_avg, inverse_avg},
	{"AVG", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, step_avg, fin_avg,
	 fin_avg, inverse_avg},
	{"CHAR", -1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_STRING, func_char, NULL,
	 NULL, NULL},
	{"CHAR_LENGTH", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_INTEGER,
	 func_char_length, NULL, NULL, NULL},
	{"COALESCE", -1, {field_type_MAX}, FIELD_TYPE_SCALAR, sql_builtin_stub,
	 NULL, NULL, NULL},
	{"COUNT", 0, {}, FIELD_TYPE_INTEGER, step_count, fin_count,
	 fin_count, inverse_count},
	{"COUNT", 1, {field_type_MAX}, FIELD_TYPE_INTEGER, step_count,
	 fin_count, fin_count, inverse_count},
	{"DATE_PART", 2, {FIELD_TYPE_STRING, FIELD_TYPE_DATETIME},
	 FIELD_TYPE_INTEGER, func_date_part, NULL, NULL, NULL},

	{"GREATEST", -1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_NUMBER}, FIELD_TYPE_NUMBER,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_UUID}, FIELD_TYPE_UUID,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING,
	 func_greatest_least, NULL, NULL, NULL},
	{"GREATEST", -1, {FIELD_TYPE_SCALAR}, FIELD_TYPE_SCALAR,
	 func_greatest_least, NULL, NULL, NULL},

	{"GROUP_CONCAT", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING,
	 step_group_concat, NULL, NULL, inverse_group_concat},
	{"GROUP_CONCAT", 2, {FIELD_TYPE_STRING, FIELD_TYPE_STRING},
	 FIELD_TYPE_STRING, step_group_concat, NULL, NULL,
	 inverse_group_concat},
	{"GROUP_CONCAT", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY,
	 step_group_concat, NULL, NULL, inverse_group_concat},
	{"GROUP_CONCAT", 2, {FIELD_TYPE_VARBINARY, FIELD_TYPE_VARBINARY},
	 FIELD_TYPE_VARBINARY, step_group_concat, NULL, NULL,
	 inverse_group_concat},

	{"HEX", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_STRING, func_hex, NULL,
	 NULL, NULL},
	{"IFNULL", 2, {field_type_MAX, field_type_MAX}, FIELD_TYPE_SCALAR,
	 sql_builtin_stub, NULL, NULL, NULL},
	{"JSON_NULL", 0, {}, FIELD_TYPE_JSON, func_json_null, NULL, NULL, NULL},
	{"JSON_PARSE", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_JSON, func_json_parse,
	 NULL, NULL, NULL},

	{"LAST_VALUE", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_NUMBER}, FIELD_TYPE_NUMBER,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_UUID}, FIELD_TYPE_UUID, step_last_value,
	 fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},
	{"LAST_VALUE", 1, {FIELD_TYPE_SCALAR}, FIELD_TYPE_SCALAR,
	 step_last_value, fin_last_value, value_last_value, inverse_last_value},

	{"LEAST", -1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_NUMBER}, FIELD_TYPE_NUMBER,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_UUID}, FIELD_TYPE_UUID,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING,
	 func_greatest_least, NULL, NULL, NULL},
	{"LEAST", -1, {FIELD_TYPE_SCALAR}, FIELD_TYPE_SCALAR,
	 func_greatest_least, NULL, NULL, NULL},

	{"LENGTH", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_INTEGER, func_char_length,
	 NULL, NULL, NULL},
	{"LENGTH", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_INTEGER,
	 func_octet_length, NULL, NULL, NULL},
	{"LIKE", 2, {FIELD_TYPE_STRING, FIELD_TYPE_STRING},
	 FIELD_TYPE_BOOLEAN, likeFunc, NULL, NULL, NULL},
	{"LIKE", 3, {FIELD_TYPE_STRING, FIELD_TYPE_STRING, FIELD_TYPE_STRING},
	 FIELD_TYPE_BOOLEAN, likeFunc, NULL, NULL, NULL},
	{"LIKELIHOOD", 2, {field_type_MAX, FIELD_TYPE_DOUBLE},
	 FIELD_TYPE_BOOLEAN, sql_builtin_stub, NULL, NULL, NULL},
	{"LIKELY", 1, {field_type_MAX}, FIELD_TYPE_BOOLEAN, sql_builtin_stub,
	 NULL, NULL, NULL},
	{"LOWER", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING, func_lower_upper,
	 NULL, NULL, NULL},

	{"MAX", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_NUMBER}, FIELD_TYPE_NUMBER, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY, step_minmax,
	 NULL, NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_UUID}, FIELD_TYPE_UUID, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING, step_minmax, NULL,
	 NULL, NULL},
	{"MAX", 1, {FIELD_TYPE_SCALAR}, FIELD_TYPE_SCALAR, step_minmax, NULL,
	 NULL, NULL},

	{"MIN", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_NUMBER}, FIELD_TYPE_NUMBER, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_VARBINARY}, FIELD_TYPE_VARBINARY, step_minmax,
	 NULL, NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_UUID}, FIELD_TYPE_UUID, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING, step_minmax, NULL,
	 NULL, NULL},
	{"MIN", 1, {FIELD_TYPE_SCALAR}, FIELD_TYPE_SCALAR, step_minmax, NULL,
	 NULL, NULL},
	{"NOW", 0, {}, FIELD_TYPE_DATETIME, func_now, NULL, NULL, NULL},

	{"NULLIF", 2, {FIELD_TYPE_SCALAR, field_type_MAX}, FIELD_TYPE_SCALAR,
	 func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_UNSIGNED, field_type_MAX},
	 FIELD_TYPE_UNSIGNED, func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_STRING, field_type_MAX}, FIELD_TYPE_STRING,
	 func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_DOUBLE, field_type_MAX}, FIELD_TYPE_DOUBLE,
	 func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_INTEGER, field_type_MAX},
	 FIELD_TYPE_INTEGER, func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_BOOLEAN, field_type_MAX},
	 FIELD_TYPE_BOOLEAN, func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_VARBINARY, field_type_MAX},
	 FIELD_TYPE_VARBINARY, func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_DECIMAL, field_type_MAX},
	 FIELD_TYPE_DECIMAL, func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_UUID, field_type_MAX}, FIELD_TYPE_UUID,
	 func_nullif, NULL, NULL, NULL},
	{"NULLIF", 2, {FIELD_TYPE_DATETIME, field_type_MAX},
	 FIELD_TYPE_DATETIME, func_nullif, NULL, NULL, NULL},

	{"POSITION", 2, {FIELD_TYPE_STRING, FIELD_TYPE_STRING},
	 FIELD_TYPE_INTEGER, func_position_characters, NULL, NULL, NULL},
	{"POSITION", 2, {FIELD_TYPE_VARBINARY, FIELD_TYPE_VARBINARY},
	 FIELD_TYPE_INTEGER, func_position_octets, NULL, NULL, NULL},
	{"PRINTF", -1, {field_type_MAX}, FIELD_TYPE_STRING, func_printf, NULL,
	 NULL, NULL},
	{"QUOTE", 1, {field_type_MAX}, FIELD_TYPE_STRING, quoteFunc, NULL,
	 NULL, NULL},
	{"RANDOM", 0, {}, FIELD_TYPE_INTEGER, func_random, NULL, NULL, NULL},
	{"RANDOMBLOB", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_VARBINARY,
	 func_randomblob, NULL, NULL, NULL},
	{"REPLACE", 3,
	 {FIELD_TYPE_STRING, FIELD_TYPE_STRING, FIELD_TYPE_STRING},
	 FIELD_TYPE_STRING, replaceFunc, NULL, NULL, NULL},
	{"REPLACE", 3,
	 {FIELD_TYPE_VARBINARY, FIELD_TYPE_VARBINARY, FIELD_TYPE_VARBINARY},
	 FIELD_TYPE_VARBINARY, replaceFunc, NULL, NULL, NULL},
	{"ROUND", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, func_round_dec,
	 NULL, NULL, NULL},
	{"ROUND", 2, {FIELD_TYPE_DECIMAL, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_DECIMAL, func_round_dec, NULL, NULL, NULL},
	{"ROUND", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, func_round_double,
	 NULL, NULL, NULL},
	{"ROUND", 2, {FIELD_TYPE_DOUBLE, FIELD_TYPE_INTEGER}, FIELD_TYPE_DOUBLE,
	 func_round_double, NULL, NULL, NULL},
	{"ROUND", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_INTEGER, func_round_int,
	 NULL, NULL, NULL},
	{"ROUND", 2, {FIELD_TYPE_INTEGER, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_INTEGER, func_round_int, NULL, NULL, NULL},
	{"ROW_COUNT", 0, {}, FIELD_TYPE_INTEGER, func_row_count, NULL,
	 NULL, NULL},
	{"ROW_NUMBER", 0, {}, FIELD_TYPE_INTEGER, step_row_number, NULL,
	 NULL, NULL},
	{"SOUNDEX", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING, soundexFunc,
	 NULL, NULL, NULL},
	{"SUBSTR", 2, {FIELD_TYPE_STRING, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_STRING, func_substr_characters, NULL, NULL, NULL},
	{"SUBSTR", 3,
	 {FIELD_TYPE_STRING, FIELD_TYPE_INTEGER, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_STRING, func_substr_characters, NULL, NULL, NULL},
	{"SUBSTR", 2, {FIELD_TYPE_VARBINARY, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_VARBINARY, func_substr_octets, NULL, NULL, NULL},
	{"SUBSTR", 3,
	 {FIELD_TYPE_VARBINARY, FIELD_TYPE_INTEGER, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_VARBINARY, func_substr_octets, NULL, NULL, NULL},
	{"SUM", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DECIMAL, step_sum, NULL,
	 NULL, inverse_sum},
	{"SUM", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_DECIMAL, step_sum, fin_sum,
	 fin_sum, inverse_sum},
	{"SUM", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, step_sum, NULL,
	 NULL, inverse_sum},
	{"TO_CHAR", 2, {FIELD_TYPE_DATETIME, FIELD_TYPE_STRING},
	 FIELD_TYPE_STRING, func_to_char, NULL, NULL, NULL},
	{"TOTAL", 1, {FIELD_TYPE_DECIMAL}, FIELD_TYPE_DOUBLE, step_total,
	 fin_total, fin_total, inverse_sum},
	{"TOTAL", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_DOUBLE, step_total,
	 fin_total, fin_total, inverse_sum},
	{"TOTAL", 1, {FIELD_TYPE_DOUBLE}, FIELD_TYPE_DOUBLE, step_total,
	 fin_total, fin_total, inverse_sum},

	{"TRIM", 2, {FIELD_TYPE_STRING, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_STRING, func_trim_str, NULL, NULL, NULL},
	{"TRIM", 3, {FIELD_TYPE_STRING, FIELD_TYPE_INTEGER, FIELD_TYPE_STRING},
	 FIELD_TYPE_STRING, func_trim_str, NULL, NULL, NULL},
	{"TRIM", 2, {FIELD_TYPE_VARBINARY, FIELD_TYPE_INTEGER},
	 FIELD_TYPE_VARBINARY, func_trim_bin, NULL, NULL, NULL},
	{"TRIM", 3,
	 {FIELD_TYPE_VARBINARY, FIELD_TYPE_INTEGER, FIELD_TYPE_VARBINARY},
	 FIELD_TYPE_VARBINARY, func_trim_bin, NULL, NULL, NULL},

	{"TYPEOF", 1, {field_type_MAX}, FIELD_TYPE_STRING, func_typeof, NULL,
	 NULL, NULL},
	{"UNICODE", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_INTEGER, func_unicode,
	 NULL, NULL, NULL},
	{"UNLIKELY", 1, {field_type_MAX}, FIELD_TYPE_BOOLEAN, sql_builtin_stub,
	 NULL, NULL, NULL},
	{"UPPER", 1, {FIELD_TYPE_STRING}, FIELD_TYPE_STRING, func_lower_upper,
	 NULL, NULL, NULL},
	{"UUID", 0, {}, FIELD_TYPE_UUID, func_uuid, NULL, NULL, NULL},
	{"UUID", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_UUID, func_uuid, NULL,
	 NULL, NULL},
	{"VERSION", 0, {}, FIELD_TYPE_STRING, func_version, NULL, NULL, NULL},
	{"ZEROBLOB", 1, {FIELD_TYPE_INTEGER}, FIELD_TYPE_VARBINARY,
	 func_zeroblob, NULL, NULL, NULL},
};

static struct sql_func_dictionary *
built_in_func_get(const char *name)
{
	uint32_t len = strlen(name);
	mh_int_t k = mh_strnptr_find_str(built_in_functions, name, len);
	if (k == mh_end(built_in_functions))
		return NULL;
	return mh_strnptr_node(built_in_functions, k)->val;
}

static void
built_in_func_put(struct sql_func_dictionary *dict)
{
	const char *name = dict->name;
	uint32_t len = strlen(name);
	assert(built_in_func_get(name) == NULL);

	uint32_t hash = mh_strn_hash(name, len);
	const struct mh_strnptr_node_t strnode = {name, len, hash, dict};
	mh_strnptr_put(built_in_functions, &strnode, NULL, NULL);
}

/**
 * Check if there is no need to cast argument to accepted type. Also, in some
 * cases operation 'op' may be important, for example when given argument is
 * NULL or is variable.
 *
 * Returns TRUE when:
 *  - when operation is NULL;
 *  - when accepted type and argument type are equal;
 *  - when accepted type is ANY;
 *  - when accepted type is INTEGER and argument type is UNSIGNED.
 */
static inline bool
is_exact(int op, enum field_type a, enum field_type b)
{
	return op == TK_NULL || a == b || a == field_type_MAX ||
	       (a == FIELD_TYPE_INTEGER && b == FIELD_TYPE_UNSIGNED);
}

/**
 * Check if the argument MEM type will not change during cast. It means that
 * either is_exact() returns TRUE or accepted type is metatype that includes
 * argument type.
 *
 * Returns TRUE when:
 *  - is_exact() returns TRUE;
 *  - when accepted type is NUMBER and argument type is numeric type;
 *  - when accepted type is SCALAR and argument type is not MAP, ARRAY,
 *    INTERVAL or JSON.
 */
static inline bool
is_upcast(int op, enum field_type a, enum field_type b)
{
	return is_exact(op, a, b) ||
	       (a == FIELD_TYPE_NUMBER && sql_type_is_numeric(b)) ||
	       (a == FIELD_TYPE_SCALAR && b != FIELD_TYPE_MAP &&
		b != FIELD_TYPE_INTERVAL && b != FIELD_TYPE_ARRAY &&
		b != FIELD_TYPE_JSON);
}

/**
 * Check if there is a chance that the argument can be cast to accepted type
 * according to implicit cast rules.
 *
 * Returns TRUE when:
 *  - is_upcast() returns TRUE;
 *  - when accepted type and argument type are numeric types;
 *  - when argument is binded value;
 *  - when argument type is ANY, which means that is was not resolved.
 */
static inline bool
is_castable(int op, enum field_type a, enum field_type b)
{
	return is_upcast(op, a, b) || op == TK_VARIABLE || op == TK_ID ||
	       (sql_type_is_numeric(a) && sql_type_is_numeric(b)) ||
	       b == FIELD_TYPE_ANY;
}

const enum field_type *
sql_table_func_param_types(const struct sql_table_func_def *func,
			   struct ExprList *args)
{
	if (func->ops->param_types == NULL)
		return NULL;
	return func->ops->param_types(args);
}

int
sql_table_func_check_arg_types(const struct sql_table_func_def *func,
			       struct ExprList *args)
{
	const enum field_type *types = sql_table_func_param_types(func, args);
	if (types == NULL)
		return 0;
	assert(args != NULL && args->nExpr >= func->param_count);
	for (int i = 0; i < args->nExpr; i++) {
		struct Expr *e = sqlExprSkipCollate(args->a[i].pExpr);
		if (is_castable(e->op, types[i], sql_expr_type(e)))
			continue;
		diag_set(ClientError, ER_SQL_EXECUTE,
			 tt_sprintf("wrong arguments for function %s()",
				    func->name));
		return -1;
	}
	return 0;
}

enum check_type {
	CHECK_TYPE_EXACT,
	CHECK_TYPE_UPCAST,
	CHECK_TYPE_CASTABLE,
};

static struct func *
find_compatible(struct Expr *expr, struct sql_func_dictionary *dict,
		enum check_type check)
{
	int n = expr->x.pList != NULL ? expr->x.pList->nExpr : 0;
	for (uint32_t i = 0; i < dict->count; ++i) {
		struct func_sql_builtin *func = dict->functions[i];
		int argc = func->base.def->param_count;
		if (argc != n && argc != -1)
			continue;
		if (n == 0)
			return &func->base;

		enum field_type *types = func->param_list;
		bool is_match = true;
		for (int j = 0; j < n && is_match; ++j) {
			struct Expr *e = expr->x.pList->a[j].pExpr;
			while (e->op == TK_COLLATE)
				e = e->pLeft;
			enum field_type a = types[argc != -1 ? j : 0];
			enum field_type b = sql_expr_type(e);
			switch (check) {
			case CHECK_TYPE_EXACT:
				is_match = is_exact(e->op, a, b);
				break;
			case CHECK_TYPE_UPCAST:
				is_match = is_upcast(e->op, a, b);
				break;
			case CHECK_TYPE_CASTABLE:
				is_match = is_castable(e->op, a, b);
				break;
			default:
				unreachable();
			}
		}
		if (is_match)
			return &func->base;
	}
	return NULL;
}

static struct func *
find_built_in_func(struct Expr *expr, struct sql_func_dictionary *dict)
{
	const char *name = expr->u.zToken;
	int n = expr->x.pList != NULL ? expr->x.pList->nExpr : 0;
	int argc_min = dict->argc_min;
	int argc_max = dict->argc_max;
	if (n < argc_min || n > argc_max) {
		const char *str;
		if (argc_min == argc_max)
			str = tt_sprintf("%d", argc_min);
		else if (argc_max == SQL_MAX_FUNCTION_ARG && n < argc_min)
			str = tt_sprintf("at least %d", argc_min);
		else
			str = tt_sprintf("from %d to %d", argc_min, argc_max);
		diag_set(ClientError, ER_FUNC_WRONG_ARG_COUNT, name, str, n);
		return NULL;
	}
	struct func *func = find_compatible(expr, dict, CHECK_TYPE_EXACT);
	if (func != NULL)
		return func;
	func = find_compatible(expr, dict, CHECK_TYPE_UPCAST);
	if (func != NULL)
		return func;
	func = find_compatible(expr, dict, CHECK_TYPE_CASTABLE);
	if (func != NULL)
		return func;
	diag_set(ClientError, ER_SQL_EXECUTE,
		 tt_sprintf("wrong arguments for function %s()", name));
	return NULL;
}

struct func *
sql_func_find(struct Expr *expr)
{
	const char *name = expr->u.zToken;
	struct sql_func_dictionary *dict = built_in_func_get(name);
	if (dict != NULL)
		return find_built_in_func(expr, dict);
	struct func *func = func_by_name(name, strlen(name));
	if (func == NULL &&
	    sql_table_func_is_registered(name, strlen(name))) {
		diag_set(ClientError, ER_SQL_PARSER_GENERIC,
			 tt_sprintf("table function %s() cannot be used as "
				    "a scalar function", name));
		return NULL;
	}
	if (func == NULL) {
		diag_set(ClientError, ER_NO_SUCH_FUNCTION, name);
		return NULL;
	}
	if (!func->def->exports.sql) {
		diag_set(ClientError, ER_SQL_PARSER_GENERIC,
			 tt_sprintf("function %s() is not available in SQL",
				     name));
		return NULL;
	}
	if (func->def->param_count == -1)
		return func;

	int n = expr->x.pList != NULL ? expr->x.pList->nExpr : 0;
	int argc = func->def->aggregate == FUNC_AGGREGATE_GROUP ?
		   func->def->param_count - 1 : func->def->param_count;
	assert(argc >= 0);
	if (argc != n) {
		diag_set(ClientError, ER_FUNC_WRONG_ARG_COUNT, name,
			 tt_sprintf("%d", argc), n);
		return NULL;
	}
	return func;
}

struct func *
sql_func_finalize(const char *name)
{
	const char *finalize_name = tt_sprintf("%s_finalize", name);
	uint32_t len = strlen(finalize_name);
	struct func *finalize = func_by_name(finalize_name, len);
	if (finalize == NULL ||
	    finalize->def->param_count != 1 ||
	    finalize->def->aggregate == FUNC_AGGREGATE_GROUP)
		return NULL;
	return finalize;
}

uint32_t
sql_func_flags(const char *name)
{
	struct sql_func_dictionary *dict = built_in_func_get(name);
	if (dict != NULL)
		return dict->flags;
	struct func *func = func_by_name(name, strlen(name));
	if (func == NULL || func->def->aggregate != FUNC_AGGREGATE_GROUP)
		return 0;
	return SQL_FUNC_AGG;
}

static struct func_vtab func_sql_builtin_vtab;

void
sql_built_in_functions_cache_init(void)
{
	built_in_functions = mh_strnptr_new();
	for (uint32_t i = 0; i < nelem(dictionaries); ++i)
		built_in_func_put(&dictionaries[i]);

	functions = malloc(sizeof(*functions) * nelem(definitions));
	for (uint32_t i = 0; i < nelem(definitions); ++i) {
		struct sql_func_definition *desc = &definitions[i];
		const char *name = desc->name;
		struct sql_func_dictionary *dict = built_in_func_get(name);
		assert(dict != NULL);

		uint32_t len = strlen(name);
		struct func_def *def = func_def_new(i, ADMIN, name, len,
						    FUNC_LANGUAGE_SQL_BUILTIN,
						    NULL, 0, NULL, 0);
		def->setuid = true;
		def->is_deterministic = dict->is_deterministic;
		assert(desc->argc != -1 || dict->argc_min != dict->argc_max);
		def->param_count = desc->argc;
		def->returns = desc->result;
		def->aggregate = (dict->flags & SQL_FUNC_AGG) == 0 ?
				 FUNC_AGGREGATE_NONE : FUNC_AGGREGATE_GROUP;
		def->exports.sql = true;

		struct func_sql_builtin *func = xmalloc(sizeof(*func));
		func->base.def = def;
		rlist_create(&func->base.func_cache_pin_list);
		func->base.vtab = &func_sql_builtin_vtab;
		credentials_create_empty(&func->base.owner_credentials);
		access_map_create(&func->base.access);

		func->param_list = desc->argt;
		func->flags = dict->flags;
		func->call = desc->call;
		func->finalize = desc->finalize;
		func->value = desc->value;
		func->inverse = desc->inverse;
		functions[i] = func;
		assert(dict->count == 0 || dict->functions != NULL);
		if (dict->functions == NULL)
			dict->functions = &functions[i];
		++dict->count;
	}
	/*
	 * Initialization of CHARACTER_LENGTH() function, which is actually
	 * another name for CHAR_LENGTH().
	 */
	const char *name = "CHARACTER_LENGTH";
	struct sql_func_dictionary *dict = built_in_func_get(name);
	name = "CHAR_LENGTH";
	struct sql_func_dictionary *dict_original = built_in_func_get(name);
	dict->count = dict_original->count;
	dict->functions = dict_original->functions;
	if (sql_table_func_register(sql_builtin_table_funcs,
				    nelem(sql_builtin_table_funcs)) != 0)
		panic("failed to initialize SQL table functions");
	sql_table_func_registry_sealed = true;
}

void
sql_built_in_functions_cache_free(void)
{
	sql_table_func_registry_free();
	if (built_in_functions == NULL)
		return;
	for (uint32_t i = 0; i < nelem(definitions); ++i)
		func_delete(&functions[i]->base);
	for (uint32_t i = 0; i < nelem(dictionaries); ++i) {
		const char *name = dictionaries[i].name;
		uint32_t len = strlen(name);
		mh_int_t k = mh_strnptr_find_str(built_in_functions, name, len);
		if (k == mh_end(built_in_functions))
			continue;
		mh_strnptr_del(built_in_functions, k, NULL);
	}
	assert(mh_size(built_in_functions) == 0);
	mh_strnptr_delete(built_in_functions);
}

static void
func_sql_builtin_destroy(struct func *func)
{
	assert(func->vtab == &func_sql_builtin_vtab);
	assert(func->def->language == FUNC_LANGUAGE_SQL_BUILTIN);
	free(func);
}

static struct func_vtab func_sql_builtin_vtab = {
	.call = func_sql_builtin_call_stub,
	.destroy = func_sql_builtin_destroy,
};

/** Table of methods of SQL user-defined functions. */
static struct func_vtab func_sql_expr_vtab;

/** SQL user-defined function. */
struct func_sql_expr {
	/** Function object base class. */
	struct func base;
	/** Prepared SQL statement. */
	struct Vdbe *stmt;
};

struct func *
func_sql_expr_new(const struct func_def *def)
{
	const char *body = def->body;
	uint32_t body_len = body == NULL ? 0 : strlen(body);
	struct Expr *expr = sql_expr_compile(body, body_len);
	if (expr == NULL)
		return NULL;
	struct Parse parser;
	sql_parser_create(&parser, SQL_DEFAULT_FLAGS);
	struct Vdbe *v = sqlGetVdbe(&parser);
	int ref_reg = ++parser.nMem;
	sqlVdbeAddOp2(v, OP_Variable, ++parser.nVar, ref_reg);
	v->is_sandboxed = 1;
	parser.vdbe_field_ref_reg = ref_reg;

	sqlVdbeSetNumCols(v, 1);
	vdbe_metadata_set_col_name(v, 0, def->name);
	vdbe_metadata_set_col_type(v, 0, field_type_strs[def->returns]);
	int res_reg = sqlExprCodeTarget(&parser, expr, ++parser.nMem);
	sqlVdbeAddOp2(v, OP_ResultRow, res_reg, 1);

	bool is_error = parser.is_aborted;
	sql_finish_coding(&parser);
	sql_parser_destroy(&parser);
	sql_expr_delete(expr);

	if (is_error) {
		sql_stmt_finalize((struct sql_stmt *)v);
		return NULL;
	}
	struct func_sql_expr *func = xmalloc(sizeof(*func));
	func->stmt = v;
	func->base.vtab = &func_sql_expr_vtab;
	return &func->base;
}

int
func_sql_expr_call(struct func *func, struct port *args, struct port *ret)
{
	struct func_sql_expr *func_sql = (struct func_sql_expr *)func;
	struct sql_stmt *stmt = (struct sql_stmt *)func_sql->stmt;
	if (args->vtab != &port_c_vtab || ((struct port_c *)args)->size != 2) {
		diag_set(ClientError, ER_UNSUPPORTED, "Tarantool",
			 "SQL functions");
		return -1;
	}
	struct port_c_entry *pe = ((struct port_c *)args)->first;
	const char *data = pe->mp;
	uint32_t mp_size = pe->mp_size;
	struct tuple_format *format = pe->mp_format;
	struct region *region = &fiber()->gc;
	size_t svp = region_used(region);
	port_sql_create(ret, stmt, DQL_EXECUTE, false);
	/*
	 * Currently, SQL EXPR functions can only be called in a tuple or field
	 * constraint. If the format is NULL then it is a field constraint,
	 * otherwise it is a tuple constraint.
	 */
	uint32_t count = format != NULL ? format->total_field_count : 1;
	struct vdbe_field_ref *ref;
	size_t size = sizeof(ref->slots[0]) * count + sizeof(*ref);
	ref = xregion_aligned_alloc(region, size, alignof(*ref));
	vdbe_field_ref_create(ref, count);
	if (format != NULL)
		vdbe_field_ref_prepare_data(ref, data, mp_size);
	else
		vdbe_field_ref_prepare_array(ref, 1, data, mp_size);
	ref->format = format;
	if (sql_bind_ptr(stmt, 1, ref) != 0)
		goto error;

	if (sql_step(stmt) != SQL_ROW)
		goto error;

	uint32_t res_size;
	char *pos = sql_stmt_func_result_to_msgpack(stmt, &res_size, region);
	if (pos == NULL)
		goto error;
	int rc = port_c_add_mp(ret, pos, pos + res_size);
	if (rc != 0)
		goto error;

	if (sql_step(stmt) != SQL_DONE)
		goto error;

	sql_stmt_reset(stmt);
	region_truncate(region, svp);
	return 0;
error:
	sql_stmt_reset(stmt);
	region_truncate(region, svp);
	port_destroy(ret);
	return -1;
}

void
func_sql_expr_destroy(struct func *base)
{
	struct func_sql_expr *func = (struct func_sql_expr *)base;
	sql_stmt_finalize((struct sql_stmt *)func->stmt);
	free(func);
}

static struct func_vtab func_sql_expr_vtab = {
	.call = func_sql_expr_call,
	.destroy = func_sql_expr_destroy,
};

bool
func_sql_expr_has_single_arg(const struct func *base, const char *name)
{
	assert(base->def->language == FUNC_LANGUAGE_SQL_EXPR);
	struct func_sql_expr *func = (struct func_sql_expr *)base;
	struct Vdbe *v = func->stmt;
	for (int i = 0; i < v->nOp; ++i) {
		if (v->aOp[i].opcode != OP_FetchByName)
			continue;
		if (name == NULL) {
			name = v->aOp[i].p4.z;
			continue;
		}
		if (strcmp(name, v->aOp[i].p4.z) != 0)
			return false;
	}
	return true;
}
