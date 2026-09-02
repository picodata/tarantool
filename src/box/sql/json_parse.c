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

#include "json_parse.h"

#include <assert.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <string.h>

#include "box/error.h"
#include "decimal.h"
#include "diag.h"
#include "fiber.h"
#include "mp_decimal.h"
#include "mp_json.h"
#include "msgpuck.h"
#include "small/ibuf.h"
#include "small/region.h"
#include "sqlLimit.h"
#include "trivia/util.h"
#include "tt_static.h"

#include "lua-cjson/cjson_lexer.h"

/*
 * A fixed 5-byte map32/array32 header, so the member count can be backpatched
 * once the container closes. The final tnt_json_normalize() pass re-emits
 * minimal headers, so a placeholder never reaches the stored value.
 */
enum {
	JSON_MAP32_TAG = 0xdf,
	JSON_ARRAY32_TAG = 0xdd,
	JSON_HDR_SIZE = 5,
};

enum {
	/* Minimum buffer capacity; an ibuf cannot grow from a zero capacity. */
	JSON_MIN_CAPACITY = 64,
};

/* Everything the emit helpers below need while walking one document. */
struct json_parse_ctx {
	/* The lexer, over the whole document. */
	json_parse_t lex;
	/* The emitted MessagePack, before normalization. */
	struct ibuf *mp;
};

/* Reserve @a size bytes at the write end of the temporary buffer. */
static char *
json_reserve(struct json_parse_ctx *ctx, size_t size)
{
	char *p = ibuf_alloc(ctx->mp, size);
	if (p == NULL)
		diag_set(OutOfMemory, size, "ibuf_alloc", "json");
	return p;
}

/* Emit a JSON null. */
static int
json_emit_nil(struct json_parse_ctx *ctx)
{
	char *p = json_reserve(ctx, mp_sizeof_nil());
	if (p == NULL)
		return -1;
	mp_encode_nil(p);
	return 0;
}

/* Emit a boolean. */
static int
json_emit_bool(struct json_parse_ctx *ctx, bool val)
{
	char *p = json_reserve(ctx, mp_sizeof_bool(val));
	if (p == NULL)
		return -1;
	mp_encode_bool(p, val);
	return 0;
}

/* Emit a non-negative integer. */
static int
json_emit_uint(struct json_parse_ctx *ctx, uint64_t val)
{
	char *p = json_reserve(ctx, mp_sizeof_uint(val));
	if (p == NULL)
		return -1;
	mp_encode_uint(p, val);
	return 0;
}

/* @a val must be negative: a non-negative one is emitted as MP_UINT. */
static int
json_emit_int(struct json_parse_ctx *ctx, int64_t val)
{
	char *p = json_reserve(ctx, mp_sizeof_int(val));
	if (p == NULL)
		return -1;
	mp_encode_int(p, val);
	return 0;
}

/* Emit a double. */
static int
json_emit_double(struct json_parse_ctx *ctx, double val)
{
	char *p = json_reserve(ctx, mp_sizeof_double(val));
	if (p == NULL)
		return -1;
	mp_encode_double(p, val);
	return 0;
}

/*
 * Append [str, str + len) as MP_STR. The bytes are copied, so a string the
 * lexer borrowed from the input does not have to outlive the next token.
 */
static int
json_emit_str(struct json_parse_ctx *ctx, const char *str, uint32_t len)
{
	char *p = json_reserve(ctx, mp_sizeof_str(len));
	if (p == NULL)
		return -1;
	mp_encode_str(p, str, len);
	return 0;
}

/*
 * Emit a string token, key or value. The lexer copies bytes that need no
 * escape as they are, so this is where text that is not UTF-8 gets refused.
 */
static int
json_emit_str_token(struct json_parse_ctx *ctx, const json_token_t *token)
{
	if (!json_utf8_is_valid(token->value.string, token->string_len)) {
		/*
		 * No context snippet, unlike a syntax error: it would carry
		 * the same bytes into the message.
		 */
		int column_index = (int)(token->start - ctx->lex.cur_line_ptr);
		diag_set(ClientError, ER_JSON_PARSE,
			 tt_sprintf("invalid UTF-8 in string on line %d at "
				    "character %d", ctx->lex.line_count,
				    column_index + 1));
		return -1;
	}
	return json_emit_str(ctx, token->value.string, token->string_len);
}

/*
 * An integer literal outside [int64_min, uint64_max]. Reported exactly like a
 * SQL integer literal: the sign is a separate argument, so split the leading
 * '-' off the token span to match ER_INT_LITERAL_MAX byte-for-byte.
 */
static int
json_int_overflow(const char *num, int num_len)
{
	const char *digits = num;
	int len = num_len;
	const char *sign = "";
	if (len > 0 && digits[0] == '-') {
		sign = "-";
		digits++;
		len--;
	}
	diag_set(ClientError, ER_INT_LITERAL_MAX, sign, tt_cstr(digits, len));
	return -1;
}

/*
 * Count the literal's significant digits: skip the sign, the point, and any
 * leading zero before the first nonzero digit. No exponent can appear here,
 * since a literal with one is typed T_DOUBLE, not T_DECIMAL.
 */
static bool
json_decimal_too_wide(const char *num, int num_len)
{
	int digits = 0;
	bool seen_nonzero = false;
	for (int i = 0; i < num_len; i++) {
		char c = num[i];
		if (c == '-' || c == '.')
			continue;
		if (c == '0' && !seen_nonzero)
			continue;
		seen_nonzero = true;
		digits++;
	}
	return digits > DECIMAL_MAX_DIGITS;
}

/*
 * A fraction with no exponent: build a decimal from the literal text.
 * strtodec() stops at the first character outside the numeric grammar rather
 * than at a NUL, so the literal is normally read straight out of the input.
 * The exception is num_at_end, where nothing stops the scan, so terminate a
 * copy on the region first. The token's own end would not do, since strtodec()
 * can run past it ("1e" tokenizes as just "1").
 */
static int
json_emit_decimal(struct json_parse_ctx *ctx, const char *num, int num_len,
		  bool num_at_end)
{
	/*
	 * decimal_check_status() masks DEC_Rounded, so decNumber would
	 * otherwise round a longer fraction to DECIMAL_MAX_DIGITS and return
	 * a value that does not round-trip. Count digits on the literal text
	 * instead, before strtodec() sees it.
	 */
	if (json_decimal_too_wide(num, num_len)) {
		diag_set(ClientError, ER_INVALID_DEC, tt_cstr(num, num_len));
		return -1;
	}
	if (num_at_end) {
		struct region *region = &fiber()->gc;
		char *copy = region_alloc(region, (size_t)num_len + 1);
		if (copy == NULL) {
			diag_set(OutOfMemory, (size_t)num_len + 1,
				 "region_alloc", "json decimal");
			return -1;
		}
		memcpy(copy, num, num_len);
		copy[num_len] = '\0';
		num = copy;
	}

	decimal_t dec;
	const char *endptr;
	if (strtodec(&dec, num, &endptr) == NULL || endptr != num + num_len) {
		diag_set(ClientError, ER_INVALID_DEC, tt_cstr(num, num_len));
		return -1;
	}
	char *p = json_reserve(ctx, mp_sizeof_decimal(&dec));
	if (p == NULL)
		return -1;
	mp_encode_decimal(p, &dec);
	return 0;
}

/* Set ER_JSON_PARSE with cjson's "Expected X but found Y" character context. */
static int
json_syntax_error(struct json_parse_ctx *ctx, const char *expected,
		  const json_token_t *token)
{
	const char *found = token->type == JSON_T_ERROR ? token->value.string :
			    json_token_type_name[token->type];
	char err_context[ERR_CONTEXT_MAX_LENGTH + 1];
	int column_index = (int)(token->start - ctx->lex.cur_line_ptr);
	json_fill_err_context(err_context, &ctx->lex, column_index);
	/* column_index is 0 based; display from 1. */
	diag_set(ClientError, ER_JSON_PARSE,
		 tt_sprintf("Expected %s but found %s on line %d at "
			    "character %d here '%s'", expected, found,
			    ctx->lex.line_count, column_index + 1,
			    err_context));
	return -1;
}

/*
 * Fill in the container header reserved at @a hdr_off. The 32-bit form is
 * always reserved, since the element count is only known once the container
 * has been read; tnt_json_normalize() shrinks it later.
 */
static void
json_patch_header(struct json_parse_ctx *ctx, size_t hdr_off, uint8_t tag,
		  uint32_t count)
{
	char *h = ctx->mp->rpos + hdr_off;
	h[0] = (char)tag;
	mp_store_u32(h + 1, count);
}

/*
 * Append the value @a token opens, reading whatever more of it the lexer still
 * holds. @a depth is the container nesting of the value itself.
 */
static int
json_emit_value(struct json_parse_ctx *ctx, json_token_t *token, int depth);

/* Emit an object, whose opening brace the lexer has just returned. */
static int
json_emit_object(struct json_parse_ctx *ctx, int depth)
{
	size_t hdr_off = ibuf_used(ctx->mp);
	if (json_reserve(ctx, JSON_HDR_SIZE) == NULL)
		return -1;
	uint32_t count = 0;

	json_token_t token;
	json_next_token(&ctx->lex, &token);
	if (token.type != JSON_T_OBJ_END) {
		while (true) {
			if (token.type != JSON_T_STRING)
				return json_syntax_error(ctx,
							 "object key string",
							 &token);
			if (json_emit_str_token(ctx, &token) != 0)
				return -1;
			json_next_token(&ctx->lex, &token);
			if (token.type != JSON_T_COLON)
				return json_syntax_error(ctx, "colon", &token);
			json_next_token(&ctx->lex, &token);
			if (json_emit_value(ctx, &token, depth + 1) != 0)
				return -1;
			count++;
			json_next_token(&ctx->lex, &token);
			if (token.type == JSON_T_OBJ_END)
				break;
			if (token.type != JSON_T_COMMA)
				return json_syntax_error(ctx, "comma or '}'",
							 &token);
			json_next_token(&ctx->lex, &token);
		}
	}
	json_patch_header(ctx, hdr_off, JSON_MAP32_TAG, count);
	return 0;
}

/* Emit an array, whose opening bracket the lexer has just returned. */
static int
json_emit_array(struct json_parse_ctx *ctx, int depth)
{
	size_t hdr_off = ibuf_used(ctx->mp);
	if (json_reserve(ctx, JSON_HDR_SIZE) == NULL)
		return -1;
	uint32_t count = 0;

	json_token_t token;
	json_next_token(&ctx->lex, &token);
	if (token.type != JSON_T_ARR_END) {
		while (true) {
			if (json_emit_value(ctx, &token, depth + 1) != 0)
				return -1;
			count++;
			json_next_token(&ctx->lex, &token);
			if (token.type == JSON_T_ARR_END)
				break;
			if (token.type != JSON_T_COMMA)
				return json_syntax_error(ctx, "comma or ']'",
							 &token);
			json_next_token(&ctx->lex, &token);
		}
	}
	json_patch_header(ctx, hdr_off, JSON_ARRAY32_TAG, count);
	return 0;
}

/*
 * Emit one JSON value at nesting @a depth. The depth bound matches
 * tnt_json_normalize(), so normalization never trips on nesting the parser
 * accepted.
 */
static int
json_emit_value(struct json_parse_ctx *ctx, json_token_t *token, int depth)
{
	if (depth >= JSON_MAX_NESTING_DEPTH) {
		diag_set(ClientError, ER_JSON_PARSE,
			 tt_sprintf("too many nested structures (max %d)",
				    JSON_MAX_NESTING_DEPTH));
		return -1;
	}
	switch (token->type) {
	case JSON_T_STRING:
		return json_emit_str_token(ctx, token);
	case JSON_T_UINT:
		if (token->num_overflow)
			return json_int_overflow(token->start, token->num_len);
		return json_emit_uint(ctx, (uint64_t)token->value.ival);
	case JSON_T_INT:
		if (token->num_overflow)
			return json_int_overflow(token->start, token->num_len);
		if (token->value.ival >= 0)
			return json_emit_uint(ctx, (uint64_t)token->value.ival);
		return json_emit_int(ctx, token->value.ival);
	case JSON_T_DECIMAL:
		return json_emit_decimal(ctx, token->start, token->num_len,
					 token->num_at_end);
	case JSON_T_DOUBLE:
		/*
		 * decode_invalid_numbers only rejects literal nan/inf words;
		 * a literal that overflows strtod (1e400) still arrives as a
		 * non-finite JSON_T_DOUBLE. JSON forbids NaN/Inf, so mirror
		 * the luaL_checkfinite() the Lua consumer does.
		 */
		if (!isfinite(token->value.number)) {
			diag_set(ClientError, ER_JSON_PARSE,
				 tt_sprintf("number %.*s must not be "
					    "NaN or Inf", token->num_len,
					    token->start));
			return -1;
		}
		return json_emit_double(ctx, token->value.number);
	case JSON_T_BOOLEAN:
		return json_emit_bool(ctx, token->value.boolean != 0);
	case JSON_T_NULL:
		return json_emit_nil(ctx);
	case JSON_T_OBJ_BEGIN:
		return json_emit_object(ctx, depth);
	case JSON_T_ARR_BEGIN:
		return json_emit_array(ctx, depth);
	default:
		return json_syntax_error(ctx, "value", token);
	}
}

char *
tnt_json_parse(const char *text, uint32_t len, uint32_t *out_len)
{
	struct region *region = &fiber()->gc;

	/*
	 * strbuf_create() takes an int and sizes its buffer len + 1, so
	 * INT_MAX and up overflow it: a longer text would arrive negative,
	 * quietly get the default 1023-byte buffer, and the lexer's unchecked
	 * appends would run off the end of it. This guards against that
	 * overflow; it is not a limit on how big a JSON document may be, since
	 * this function is exported and knows nothing about SQL. SQL callers
	 * never get here anyway, because SQL_MAX_LENGTH caps any TEXT or BLOB
	 * mem first (sqlVdbeMemTooBig()). That is asserted rather than just
	 * written down, so raising SQL_MAX_LENGTH later cannot quietly break
	 * it.
	 */
	static_assert(SQL_MAX_LENGTH < INT_MAX,
		      "this function's own overflow bound must stay above "
		      "SQL_MAX_LENGTH for that claim to hold");
	if (len >= INT_MAX) {
		diag_set(ClientError, ER_JSON_PARSE, "text is too long");
		return NULL;
	}

	/*
	 * The MessagePack ends up about as large as the text, so start there
	 * rather than doubling up from a few bytes.
	 */
	struct ibuf str_buf, mp_buf;
	ibuf_create(&mp_buf, cord_slab_cache(), MAX(len, JSON_MIN_CAPACITY));

	/*
	 * Only ever holds a string the lexer had to unescape; an escape-free
	 * one is borrowed straight from the text. Unescaping only shrinks, so
	 * len + 1 covers it. Sized up front so it never has to grow, because
	 * strbuf's growth path kills the process on OOM.
	 */
	int str_len = memchr(text, '\\', len) != NULL ? (int)len : 0;
	size_t str_size = str_len > 0 ? (size_t)str_len + 1 :
			  STRBUF_DEFAULT_SIZE;
	ibuf_create(&str_buf, cord_slab_cache(), str_size);
	/* Same reason: strbuf_create() dies instead of failing. */
	if (ibuf_reserve(&str_buf, str_size) == NULL) {
		diag_set(OutOfMemory, str_size, "ibuf_reserve", "json str");
		ibuf_destroy(&str_buf);
		ibuf_destroy(&mp_buf);
		return NULL;
	}
	strbuf_t strbuf;
	strbuf_create(&strbuf, str_len, &str_buf);

	/*
	 * The lexer is length bounded, so it scans the caller's bytes in
	 * place; they may point into tuple data, where text[len] is not ours
	 * to read. An embedded NUL still ends the scan, which the check after
	 * the top-level value turns into an error.
	 */
	struct json_parse_ctx ctx;
	ctx.lex.ptr = text;
	ctx.lex.end = text + len;
	ctx.lex.tmp = &strbuf;
	ctx.lex.decode_invalid_numbers = false;
	/*
	 * The strict grammar rejects a raw control character inside a string,
	 * as RFC 8259 requires. Lua's json.decode() keeps taking it.
	 */
	ctx.lex.reject_control_chars = true;
	ctx.lex.line_count = 1;
	ctx.lex.cur_line_ptr = text;
	ctx.mp = &mp_buf;

	char *result = NULL;
	json_token_t token;
	json_next_token(&ctx.lex, &token);
	if (json_emit_value(&ctx, &token, 0) != 0)
		goto out;
	/*
	 * Two conditions: nothing may follow the top-level value, and it must
	 * reach the end of the text. The lexer keeps the ch2token['\0'] ==
	 * JSON_T_END dispatch its NUL-terminated callers rely on, and SQL
	 * strings may carry a NUL, so text that stops early is malformed
	 * rather than done.
	 */
	json_next_token(&ctx.lex, &token);
	if (token.start != text + len) {
		if (token.type == JSON_T_END)
			diag_set(ClientError, ER_JSON_PARSE,
				 "text contains an embedded zero byte");
		else
			json_syntax_error(&ctx, "the end", &token);
		goto out;
	}

	/*
	 * Not bounded by the text length: a short number literal can expand
	 * and every container spends a fixed 5-byte header, so with len up to
	 * INT_MAX the raw size can exceed UINT32_MAX. Check the size_t before
	 * the cast below, since a wrap would under-allocate norm.
	 */
	size_t raw_size = ibuf_used(&mp_buf);
	if (raw_size > UINT32_MAX) {
		diag_set(ClientError, ER_JSON_PARSE,
			 "encoded value is too large");
		goto out;
	}
	uint32_t raw_len = (uint32_t)raw_size;
	char *norm = region_alloc(region, raw_len);
	if (norm == NULL) {
		diag_set(OutOfMemory, raw_len, "region_alloc", "json norm");
		goto out;
	}
	/*
	 * What the emitter produced is well formed but not yet in normal
	 * form: keys come out in the order the text had them, and headers are
	 * whatever was convenient. Normalizing only ever shrinks, so raw_len
	 * is enough room. The same call also refuses a bad value, which puts
	 * the parser through the same check as everything else rather than
	 * leaving its correctness to an argument in a comment.
	 */
	char *norm_end = tnt_json_normalize(mp_buf.rpos, raw_len, norm,
					    norm + raw_len, NULL);
	if (norm_end == NULL) {
		diag_set(ClientError, ER_JSON_PARSE, "invalid structure");
		goto out;
	}
	*out_len = (uint32_t)(norm_end - norm);
	result = norm;
out:
	strbuf_destroy(&strbuf);
	ibuf_destroy(&str_buf);
	ibuf_destroy(&mp_buf);
	return result;
}
