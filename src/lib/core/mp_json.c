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

#include "mp_json.h"

#include "mp_json_norm.h"

#include <assert.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "decimal.h"
#include "mp_decimal.h"
#include "mp_extension_types.h"
#include "msgpuck.h"
#include "small/region.h"
#include "trivia/util.h"

/** See the contract in mp_json.h. */
struct json_norm
json_norm_from_trusted(const char *data, uint32_t len)
{
	return (struct json_norm){ .data = data, .len = len };
}

uint32_t
mp_sizeof_json_len(uint32_t len)
{
	return mp_sizeof_ext(len);
}

uint32_t
mp_sizeof_json(struct json_norm value)
{
	return mp_sizeof_json_len(value.len);
}

char *
mp_encode_json(char *data, struct json_norm value)
{
	data = mp_encode_extl(data, MP_JSON, value.len);
	memcpy(data, value.data, value.len);
	return data + value.len;
}

const char *
mp_decode_json(const char **data, uint32_t *len)
{
	if (mp_typeof(**data) != MP_EXT)
		return NULL;
	int8_t type;
	const char *const svp = *data;
	uint32_t l = mp_decode_extl(data, &type);
	if (type != MP_JSON) {
		*data = svp;
		return NULL;
	}
	const char *value = *data;
	*data += l;
	*len = l;
	return value;
}

#ifndef NDEBUG
bool
tnt_json_is_normalized(const char *data, uint32_t len)
{
	return json_is_normalized(data, len);
}
#endif /* NDEBUG */

char *
tnt_json_normalize(const char *data, uint32_t len, char *out, char *out_end,
		   uint32_t *err_off)
{
	/*
	 * Look before rewriting. One read-only pass is enough to tell whether
	 * a value is already in normal form, most values that have been
	 * through storage or a client already are, and rebuilding the same
	 * bytes key by key is where the time goes.
	 *
	 * The walk is the expensive part, not the copy, so even the
	 * already-normal path writes the bytes out instead of pointing back
	 * into @a data. Pointing back would save one region bump, at the cost
	 * of every caller having to keep track of which it got.
	 */
	switch (json_verify(data, len, err_off)) {
	case JSON_NORM_OK:
		if ((size_t)(out_end - out) < (size_t)len)
			return NULL;
		memcpy(out, data, len);
		return out + len;
	case JSON_NORM_REWRITABLE:
		return json_normalize_rewrite(data, len, out, out_end);
	default:
		return NULL;
	}
}

/** What one MessagePack header turned out to introduce. */
enum mp_header_kind {
	/** A scalar, header and body already consumed. */
	MP_HEADER_SCALAR,
	/** A container header; its elements are owed by the stream. */
	MP_HEADER_CONTAINER,
	/** An MP_EXT header; the cursor sits on the payload. */
	MP_HEADER_EXT,
	MP_HEADER_INVALID,
};

/**
 * Decode exactly one MessagePack header at *@a data and skip a scalar body,
 * bounds-checked against @a end.
 *
 * One header at a time, deliberately: mp_check() consumes a whole subtree per
 * call, so delegating to it would hide every nested MP_JSON from the range
 * walk. The lead-byte dispatch is mp_check()'s own, via mp_parser_hint, so it
 * cannot drift from msgpuck.
 *
 * @param[out] slots for a container, the values it owes the stream: its
 *         element count, doubled for a map.
 * @param[out] ext_type, ext_len for MP_EXT, its subtype and payload length.
 *         The caller skips the payload.
 */
static enum mp_header_kind
mp_range_next_header(const char **data, const char *end, uint64_t *slots,
		     int8_t *ext_type, uint32_t *ext_len)
{
	if ((size_t)(end - *data) < 1)
		return MP_HEADER_INVALID;
	uint8_t c = mp_load_u8(data);
	int l = mp_parser_hint[c];
	uint32_t len;
	if (l >= 0) {
		if ((size_t)(end - *data) < (size_t)l)
			return MP_HEADER_INVALID;
		if (c >= 0xd4 && c <= 0xd8) {
			/* fixext: one type byte, then a fixed payload. */
			*ext_len = (uint32_t)l - 1;
			*ext_type = (int8_t)mp_load_u8(data);
			return MP_HEADER_EXT;
		}
		*data += l;
		return MP_HEADER_SCALAR;
	}
	if (l > MP_HINT) {
		/* A fixarray or fixmap: -l values are owed. */
		*slots = (uint64_t)(-(int64_t)l);
		return MP_HEADER_CONTAINER;
	}
	switch (l) {
	case MP_HINT_STR_8:
		if ((size_t)(end - *data) < sizeof(uint8_t))
			return MP_HEADER_INVALID;
		len = mp_load_u8(data);
		break;
	case MP_HINT_STR_16:
		if ((size_t)(end - *data) < sizeof(uint16_t))
			return MP_HEADER_INVALID;
		len = mp_load_u16(data);
		break;
	case MP_HINT_STR_32:
		if ((size_t)(end - *data) < sizeof(uint32_t))
			return MP_HEADER_INVALID;
		len = mp_load_u32(data);
		break;
	case MP_HINT_ARRAY_16:
		if ((size_t)(end - *data) < sizeof(uint16_t))
			return MP_HEADER_INVALID;
		*slots = mp_load_u16(data);
		return MP_HEADER_CONTAINER;
	case MP_HINT_ARRAY_32:
		if ((size_t)(end - *data) < sizeof(uint32_t))
			return MP_HEADER_INVALID;
		*slots = mp_load_u32(data);
		return MP_HEADER_CONTAINER;
	case MP_HINT_MAP_16:
		if ((size_t)(end - *data) < sizeof(uint16_t))
			return MP_HEADER_INVALID;
		*slots = 2 * (uint64_t)mp_load_u16(data);
		return MP_HEADER_CONTAINER;
	case MP_HINT_MAP_32:
		if ((size_t)(end - *data) < sizeof(uint32_t))
			return MP_HEADER_INVALID;
		*slots = 2 * (uint64_t)mp_load_u32(data);
		return MP_HEADER_CONTAINER;
	case MP_HINT_EXT_8:
		if ((size_t)(end - *data) < sizeof(uint8_t) + sizeof(uint8_t))
			return MP_HEADER_INVALID;
		*ext_len = mp_load_u8(data);
		*ext_type = (int8_t)mp_load_u8(data);
		return MP_HEADER_EXT;
	case MP_HINT_EXT_16:
		if ((size_t)(end - *data) < sizeof(uint16_t) + sizeof(uint8_t))
			return MP_HEADER_INVALID;
		*ext_len = mp_load_u16(data);
		*ext_type = (int8_t)mp_load_u8(data);
		return MP_HEADER_EXT;
	case MP_HINT_EXT_32:
		if ((size_t)(end - *data) < sizeof(uint32_t) + sizeof(uint8_t))
			return MP_HEADER_INVALID;
		*ext_len = mp_load_u32(data);
		*ext_type = (int8_t)mp_load_u8(data);
		return MP_HEADER_EXT;
	default:
		/* MP_HINT_INVALID: 0xc1, the never-used lead byte. */
		return MP_HEADER_INVALID;
	}
	if ((size_t)(end - *data) < (size_t)len)
		return MP_HEADER_INVALID;
	*data += len;
	return MP_HEADER_SCALAR;
}

enum json_norm_status
mp_verify_json(const char *data, const char *end, uint32_t *errpos)
{
	enum json_norm_status rc = JSON_NORM_OK;
	const char *p = data;
	const char *pos = data;
	/*
	 * Consume one value per iteration for as long as the stream owes any.
	 * A container adds its element count instead of pushing a frame, so
	 * this needs no stack and imposes no depth bound, exactly as
	 * mp_check() does.
	 */
	for (int64_t owed = 1; owed > 0; owed--) {
		pos = p;
		uint64_t slots = 0;
		int8_t ext_type = 0;
		uint32_t ext_len = 0;
		switch (mp_range_next_header(&p, end, &slots, &ext_type,
					     &ext_len)) {
		case MP_HEADER_SCALAR:
			continue;
		case MP_HEADER_CONTAINER:
			owed += slots;
			continue;
		case MP_HEADER_EXT:
			break;
		default:
			goto invalid;
		}
		if ((size_t)(end - p) < (size_t)ext_len)
			goto invalid;
		if (ext_type == MP_JSON) {
			switch (json_verify(p, ext_len, NULL)) {
			case JSON_NORM_OK:
				break;
			case JSON_NORM_REWRITABLE:
				/*
				 * Record the first and keep walking: INVALID
				 * outranks REWRITABLE.
				 */
				if (rc == JSON_NORM_OK) {
					rc = JSON_NORM_REWRITABLE;
					if (errpos != NULL)
						*errpos = (uint32_t)
							  (pos - data);
				}
				break;
			default:
				goto invalid;
			}
		} else if (mp_check_ext_data(ext_type, p, ext_len) != 0) {
			goto invalid;
		} else if (ext_type == MP_ERROR) {
			/*
			 * An error's fields can hold JSON, and the check above
			 * lets it through unverified. Recursing costs no more
			 * stack than that check, which recurses into nested
			 * errors itself.
			 */
			uint32_t off = 0;
			switch (mp_verify_json(p, p + ext_len, &off)) {
			case JSON_NORM_OK:
				break;
			case JSON_NORM_REWRITABLE:
				if (rc == JSON_NORM_OK) {
					rc = JSON_NORM_REWRITABLE;
					if (errpos != NULL)
						*errpos = (uint32_t)
							  (p - data) + off;
				}
				break;
			default:
				pos = p + off;
				goto invalid;
			}
		}
		p += ext_len;
	}
	if (p != end) {
		pos = p;
		goto invalid;
	}
	return rc;
invalid:
	if (errpos != NULL)
		*errpos = (uint32_t)(pos - data);
	return JSON_NORM_INVALID;
}

/**
 * JSON value classes for PostgreSQL JSONB ordering:
 * null < string < number < bool < array < object.
 */
enum json_class {
	JSON_CLASS_NULL = 0,
	JSON_CLASS_STRING,
	JSON_CLASS_NUMBER,
	JSON_CLASS_BOOLEAN,
	JSON_CLASS_ARRAY,
	JSON_CLASS_OBJECT,
};

/** The JSONB ordering class of a MessagePack kind. */
static enum json_class
json_mp_class(enum mp_type type)
{
	switch (type) {
	case MP_NIL:
		return JSON_CLASS_NULL;
	case MP_STR:
		return JSON_CLASS_STRING;
	case MP_UINT:
	case MP_INT:
	case MP_DOUBLE:
		return JSON_CLASS_NUMBER;
	case MP_BOOL:
		return JSON_CLASS_BOOLEAN;
	case MP_ARRAY:
		return JSON_CLASS_ARRAY;
	case MP_MAP:
		return JSON_CLASS_OBJECT;
	case MP_EXT:
		/* The only ext allowed inside JSON is a decimal number. */
		return JSON_CLASS_NUMBER;
	default:
		unreachable();
	}
}

/**
 * Compare two JSON strings bytewise, then by length once a shared prefix ties,
 * so "aa" < "b". This is jsonb-conformant: PostgreSQL compares string values
 * under the default collation, which is byte order under the C collation, and
 * the comparator carries no collation context by design.
 *
 * The same rule orders object keys in json_cmp_map: jsonb visits keys in their
 * stored length-first order but compares them by value. Both cursors are
 * advanced past the string they decode.
 */
static int
json_cmp_str(const char **a, const char **b)
{
	uint32_t la = mp_decode_strl(a);
	uint32_t lb = mp_decode_strl(b);
	uint32_t min = la < lb ? la : lb;
	int r = memcmp(*a, *b, min);
	*a += la;
	*b += lb;
	if (r != 0)
		return r < 0 ? -1 : 1;
	if (la != lb)
		return la < lb ? -1 : 1;
	return 0;
}

static int
json_cmp_bool(const char **a, const char **b)
{
	bool va = mp_decode_bool(a);
	bool vb = mp_decode_bool(b);
	return (int)va - (int)vb;
}

enum json_num_type {
	JSON_NUM_UINT,
	JSON_NUM_INT,
	JSON_NUM_DOUBLE,
	JSON_NUM_DECIMAL,
};

/** A decoded JSON number, in whichever kind it was spelled. */
struct json_num {
	/** Which member of the union below is live. */
	enum json_num_type type;
	union {
		/** JSON_NUM_UINT. */
		uint64_t u;
		/** JSON_NUM_INT, always negative. */
		int64_t i;
		/** JSON_NUM_DOUBLE. */
		double d;
		/** JSON_NUM_DECIMAL. */
		decimal_t dec;
	};
};

/** Decode the number at @a data, advancing it past the value. */
static void
json_decode_num(const char **data, struct json_num *num)
{
	switch (mp_typeof(**data)) {
	case MP_UINT:
		num->type = JSON_NUM_UINT;
		num->u = mp_decode_uint(data);
		break;
	case MP_INT:
		num->type = JSON_NUM_INT;
		num->i = mp_decode_int(data);
		break;
	case MP_DOUBLE:
		num->type = JSON_NUM_DOUBLE;
		num->d = mp_decode_double(data);
		break;
	case MP_EXT: {
		int8_t ext_type;
		uint32_t len = mp_decode_extl(data, &ext_type);
		assert(ext_type == MP_DECIMAL);
		num->type = JSON_NUM_DECIMAL;
		decimal_unpack(data, len, &num->dec);
		break;
	}
	default:
		unreachable();
	}
}

enum {
	/** Enough for "%.17g" of any double: sign, 17 digits, point, e-308. */
	JSON_DOUBLE_BUFSIZE = 32,
};

/**
 * Print @a d into @a buf as "%e" with the fewest significant digits that
 * read back as the same double, and return how many that is. Any normal
 * double survives 15 digits rounded and cut back to fewer when the rest
 * are zeros, so trying 15, 16 and then 17 (17 always do) gives the fewest.
 * A subnormal one has fewer bits and may need fewer than 15: 5e-324 would
 * take 15 as 4.94065645841247e-324.
 */
static int
json_double_shortest(double d, char buf[JSON_DOUBLE_BUFSIZE])
{
	int precision = fabs(d) < DBL_MIN ? 1 : 15;
	for (;; precision++) {
		snprintf(buf, JSON_DOUBLE_BUFSIZE, "%.*e", precision - 1, d);
		if (precision == 17 || fpconv_strtod(buf, NULL) == d)
			return precision;
	}
}

/** The magnitude of a non-zero number as its significant digits. */
struct json_digits {
	/** Most significant first, no trailing zeros. */
	uint8_t digits[DECIMAL_MAX_DIGITS];
	/** How many digits there are. */
	int len;
	/** The power of ten of the first digit. */
	int exp;
};

/** The digits of a non-zero @a dec, which are exact. */
static void
json_digits_from_decimal(const decimal_t *dec, struct json_digits *out)
{
	assert(!decNumberIsZero(dec));
	decNumberGetBCD(dec, out->digits);
	out->len = dec->digits;
	out->exp = dec->exponent + dec->digits - 1;
	while (out->digits[out->len - 1] == 0)
		out->len--;
}

/** The shortest round-trip digits of a non-zero @a d. */
static void
json_digits_from_double(double d, struct json_digits *out)
{
	assert(d != 0);
	char buf[JSON_DOUBLE_BUFSIZE];
	json_double_shortest(d, buf);
	/* "-d.ddde+XX", or "de+XX" for one digit. */
	out->len = 0;
	const char *p = buf;
	for (; *p != 'e'; p++) {
		if (*p >= '0' && *p <= '9')
			out->digits[out->len++] = *p - '0';
	}
	out->exp = atoi(p + 1);
	while (out->digits[out->len - 1] == 0)
		out->len--;
}

/** Compare two magnitudes by their digits: -1, 0 or 1. */
static int
json_digits_cmp(const struct json_digits *a, const struct json_digits *b)
{
	if (a->exp != b->exp)
		return a->exp < b->exp ? -1 : 1;
	for (int i = 0; i < a->len && i < b->len; i++) {
		if (a->digits[i] != b->digits[i])
			return a->digits[i] < b->digits[i] ? -1 : 1;
	}
	/* Trailing zeros are gone, so the longer one is bigger. */
	return COMPARE_RESULT(a->len, b->len);
}

/** Convert an integer or a decimal json_num to decimal, which is exact. */
static void
json_num_to_decimal(const struct json_num *num, decimal_t *dec)
{
	switch (num->type) {
	case JSON_NUM_UINT:
		decimal_from_uint64(dec, num->u);
		return;
	case JSON_NUM_INT:
		decimal_from_int64(dec, num->i);
		return;
	case JSON_NUM_DECIMAL:
		*dec = num->dec;
		return;
	case JSON_NUM_DOUBLE:
		break;
	}
	unreachable();
}

/**
 * Compare a double with a number of another kind.
 *
 * The double stands for the decimal its shortest round-trip digits spell,
 * the ones json_double_shortest() finds and the renderer prints: 0.1e0 is
 * the decimal 0.1, not 0.1000000000000000055511151231257827. PostgreSQL does
 * the same when it turns a float8 into jsonb, and it is what makes JSON text
 * read back equal to the value it was printed from.
 *
 * Every comparison of numbers of different kinds has to follow that one
 * rule, or the order is not transitive. The old way, a double converted to
 * decimal at 15 digits and compared exactly with an integer, made 2^53 as a
 * double equal to 2^53 as an integer, and that equal to 2^53 as a decimal,
 * while the double still came out below the decimal. Doubles compared with
 * each other need nothing: the shortest digits keep their order.
 */
static int
json_cmp_double(double d, const struct json_num *other)
{
	/*
	 * Round the other number to the nearest double. The shortest digits
	 * of d read back as d, so if the other number reads back as another
	 * double, it lies on the same side of those digits as that double
	 * lies of d. This settles almost every pair. Integer conversion
	 * rounds to nearest in the default rounding mode, as strtod() does.
	 */
	double rounded;
	switch (other->type) {
	case JSON_NUM_UINT:
		rounded = (double)other->u;
		break;
	case JSON_NUM_INT:
		rounded = (double)other->i;
		break;
	case JSON_NUM_DECIMAL: {
		char dec_str[DECIMAL_MAX_STR_LEN];
		decimal_to_string(&other->dec, dec_str);
		rounded = fpconv_strtod(dec_str, NULL);
		break;
	}
	default:
		unreachable();
	}
	if (d != rounded)
		return d < rounded ? -1 : 1;
	/*
	 * Below 2^53 an integer that rounds to d is d. A non-zero number
	 * never rounds to zero, and one that rounds to d has its sign.
	 */
	if (fabs(d) < 9007199254740992.0 && other->type != JSON_NUM_DECIMAL)
		return 0;
	if (d == 0)
		return 0;
	decimal_t dec;
	json_num_to_decimal(other, &dec);
	struct json_digits a, b;
	json_digits_from_double(d, &a);
	json_digits_from_decimal(&dec, &b);
	int sign = d < 0 ? -1 : 1;
	return sign * json_digits_cmp(&a, &b);
}

static int
json_cmp_int_uint(int64_t i, uint64_t u)
{
	if (i < 0)
		return -1;
	return COMPARE_RESULT((uint64_t)i, u);
}

/** Compare two JSON numbers by value, across representations. */
static int
json_cmp_num(const char **a, const char **b)
{
	struct json_num na, nb;
	json_decode_num(a, &na);
	json_decode_num(b, &nb);

	if (na.type == nb.type) {
		switch (na.type) {
		case JSON_NUM_UINT:
			return COMPARE_RESULT(na.u, nb.u);
		case JSON_NUM_INT:
			return COMPARE_RESULT(na.i, nb.i);
		case JSON_NUM_DOUBLE:
			return COMPARE_RESULT(na.d, nb.d);
		case JSON_NUM_DECIMAL:
			return decimal_compare(&na.dec, &nb.dec);
		}
	}

	if (na.type == JSON_NUM_DOUBLE)
		return json_cmp_double(na.d, &nb);
	if (nb.type == JSON_NUM_DOUBLE)
		return -json_cmp_double(nb.d, &na);

	if (na.type == JSON_NUM_DECIMAL || nb.type == JSON_NUM_DECIMAL) {
		decimal_t da, db;
		json_num_to_decimal(&na, &da);
		json_num_to_decimal(&nb, &db);
		return decimal_compare(&da, &db);
	}

	/* Both are integers: one INT, one UINT. */
	if (na.type == JSON_NUM_INT)
		return json_cmp_int_uint(na.i, nb.u);
	return -json_cmp_int_uint(nb.i, na.u);
}

/** Forward declaration: the comparator recurses through containers. */
static int
json_cmp_msgpack(const char **a, const char **b, int depth);

/**
 * Compare two JSON arrays by element count first, then element-by-element.
 * jsonb-conformant: an array of n elements outranks one of n-1, so
 * [2] < [1, 1], mirroring json_cmp_map. A count mismatch decides the order
 * and leaves the cursors untouched.
 */
static int
json_cmp_array(const char **a, const char **b, int depth)
{
	assert(depth < JSON_MAX_NESTING_DEPTH);
	uint32_t la = mp_decode_array(a);
	uint32_t lb = mp_decode_array(b);
	if (la != lb)
		return la < lb ? -1 : 1;
	for (uint32_t i = 0; i < la; i++) {
		int r = json_cmp_msgpack(a, b, depth + 1);
		if (r != 0)
			return r;
	}
	return 0;
}

/**
 * Compare two JSON objects by size first, then pairwise by key then value,
 * jsonb-conformant. Assumes normalized objects: keys stored length-first and
 * unique (json_key_compare in mp_json_norm.c), compared by value through
 * json_cmp_str.
 */
static int
json_cmp_map(const char **a, const char **b, int depth)
{
	assert(depth < JSON_MAX_NESTING_DEPTH);
	uint32_t la = mp_decode_map(a);
	uint32_t lb = mp_decode_map(b);
	if (la != lb)
		return la < lb ? -1 : 1;
	for (uint32_t i = 0; i < la; i++) {
		int r = json_cmp_str(a, b);
		if (r != 0)
			return r;
		r = json_cmp_msgpack(a, b, depth + 1);
		if (r != 0)
			return r;
	}
	return 0;
}

static int
json_cmp_msgpack(const char **a, const char **b, int depth)
{
	enum json_class ca = json_mp_class(mp_typeof(**a));
	enum json_class cb = json_mp_class(mp_typeof(**b));
	if (ca != cb)
		return ca < cb ? -1 : 1;
	switch (ca) {
	case JSON_CLASS_NULL:
		mp_decode_nil(a);
		mp_decode_nil(b);
		return 0;
	case JSON_CLASS_STRING:
		return json_cmp_str(a, b);
	case JSON_CLASS_NUMBER:
		return json_cmp_num(a, b);
	case JSON_CLASS_BOOLEAN:
		return json_cmp_bool(a, b);
	case JSON_CLASS_ARRAY:
		return json_cmp_array(a, b, depth);
	case JSON_CLASS_OBJECT:
		return json_cmp_map(a, b, depth);
	}
	unreachable();
}

int
mp_compare_json(struct json_norm a, struct json_norm b)
{
	const char *pa = a.data;
	const char *pb = b.data;
	return json_cmp_msgpack(&pa, &pb, 0);
}

/**
 * Print a double with the fewest significant digits that read back as the
 * same double. A fixed 14, as fpconv_g_fmt() uses, prints 1.0000000000000002
 * as 1.
 *
 * Text without an exponent reads back as a decimal, so 0.1 comes back as
 * the decimal 0.1, which json_cmp_double() takes as equal to the double.
 * PostgreSQL jsonb does the same: to_jsonb() of a float8 keeps its shortest
 * round-trip digits and stores them as numeric, so 0.1::float8 becomes the
 * numeric 0.1. Text with an exponent reads back as a double here, which is
 * still the same value as in jsonb.
 */
static void
json_double_fmt(char *buf, double d)
{
	char digits[JSON_DOUBLE_BUFSIZE];
	snprintf(buf, JSON_DOUBLE_BUFSIZE, "%.*g",
		 json_double_shortest(d, digits), d);
}

/**
 * Render one JSON value as canonical JSON text, spaced the way PostgreSQL
 * renders jsonb (", " between elements, ": " after a key). Shared by the
 * buffer (snprint) and stream (fprint) variants: PRINTF emits a formatted
 * chunk, SELF recurses on a nested value. Decimals render as bare numbers,
 * doubles in the locale-independent shortest round-trip format.
 *
 * A string goes out in runs of bytes that need no escape, not a byte at a
 * time, which is otherwise the whole cost of rendering one. A run is capped at
 * INT_MAX because %.*s takes an int precision; no run can contain a NUL, which
 * %.*s would stop at, because mp_char2escape escapes all of 0x00 to 0x1f.
 *
 * Keep comments out of the macro body: checkpatch cannot parse a block comment
 * inside a line-continued define and starts reporting the whole macro.
 */
#define JSON_PRINT(SELF, PRINTF)						\
do {									\
	if (*data >= end)						\
		return -1;						\
	switch (mp_typeof(**data)) {					\
	case MP_NIL:							\
		if (mp_check_nil(*data, end) > 0)			\
			return -1;					\
		mp_decode_nil(data);					\
		PRINTF("null");						\
		break;							\
	case MP_BOOL:							\
		if (mp_check_bool(*data, end) > 0)			\
			return -1;					\
		PRINTF("%s", mp_decode_bool(data) ? "true" : "false");	\
		break;							\
	case MP_UINT:							\
		if (mp_check_uint(*data, end) > 0)			\
			return -1;					\
		PRINTF("%llu", (unsigned long long)mp_decode_uint(data));\
		break;							\
	case MP_INT:							\
		if (mp_check_int(*data, end) > 0)			\
			return -1;					\
		PRINTF("%lld", (long long)mp_decode_int(data));		\
		break;							\
	case MP_DOUBLE: {						\
		if (mp_check_double(*data, end) > 0)			\
			return -1;					\
		double dv = mp_decode_double(data);			\
		char tmp[JSON_DOUBLE_BUFSIZE];				\
		json_double_fmt(tmp, dv);				\
		PRINTF("%s", tmp);					\
		break;							\
	}								\
	case MP_STR: {							\
		if (mp_check_strl(*data, end) > 0)			\
			return -1;					\
		uint32_t slen = mp_decode_strl(data);			\
		/* The header's claim, checked against what is there. */	\
		if ((size_t)(end - *data) < (size_t)slen)		\
			return -1;					\
		PRINTF("\"");						\
		const char *sp = *data;					\
		const char *send = *data + slen;			\
		while (sp < send) {					\
			const char *run = sp;				\
			const char *lim = (size_t)(send - sp) > INT_MAX ?\
					  sp + INT_MAX : send;		\
			while (sp < lim) {				\
				unsigned char c = (unsigned char)*sp;	\
				if (c < 128 &&				\
				    mp_char2escape[c] != NULL)		\
					break;				\
				sp++;					\
			}						\
			if (sp != run) {				\
				PRINTF("%.*s", (int)(sp - run), run);	\
			} else {					\
				unsigned char e = (unsigned char)*sp++;	\
				PRINTF("%s", mp_char2escape[e]);	\
			}						\
		}							\
		PRINTF("\"");						\
		*data = send;						\
		break;							\
	}								\
	/*								\
	 * MP_DECIMAL is the only extension a validated JSON value	\
	 * carries. Report anything else rather than render garbage.	\
	 */								\
	case MP_EXT: {							\
		int8_t ext_type;					\
		const char *ep = *data;					\
		if ((uint8_t)**data == 0xc1 ||				\
		    mp_check_extl(ep, end) > 0)				\
			return -1;					\
		uint32_t elen = mp_decode_extl(&ep, &ext_type);		\
		decimal_t dec;						\
		if ((size_t)(end - ep) < (size_t)elen || elen == 0)	\
			return -1;					\
		if (ext_type != MP_DECIMAL ||				\
		    decimal_unpack(&ep, elen, &dec) == NULL)		\
			return -1;					\
		*data = ep;						\
		PRINTF("%s", decimal_str(&dec));			\
		break;							\
	}								\
	case MP_ARRAY: {						\
		if (mp_check_array(*data, end) > 0 ||			\
		    depth >= JSON_MAX_NESTING_DEPTH)			\
			return -1;					\
		uint32_t n = mp_decode_array(data);			\
		PRINTF("[");						\
		for (uint32_t i = 0; i < n; i++) {			\
			if (i != 0)					\
				PRINTF(", ");				\
			SELF(data);					\
		}							\
		PRINTF("]");						\
		break;							\
	}								\
	case MP_MAP: {							\
		if (mp_check_map(*data, end) > 0 ||			\
		    depth >= JSON_MAX_NESTING_DEPTH)			\
			return -1;					\
		uint32_t n = mp_decode_map(data);			\
		PRINTF("{");						\
		for (uint32_t i = 0; i < n; i++) {			\
			if (i != 0)					\
				PRINTF(", ");				\
			SELF(data);					\
			PRINTF(": ");					\
			SELF(data);					\
		}							\
		PRINTF("}");						\
		break;							\
	}								\
	/*								\
	 * Not an allowed kind, so we should never get here;		\
	 * listed anyway rather than left to fall into the		\
	 * default. It reports instead of asserting because this	\
	 * renderer accepts bytes from anywhere, and			\
	 * unreachable() is undefined behaviour under NDEBUG.		\
	 */								\
	case MP_BIN:							\
	case MP_FLOAT:							\
	default:							\
		return -1;						\
	}								\
} while (0)

/** Render one JSON inner value into a buffer, with snprintf() semantics. */
static int
json_snprint_value(char *buf, int size, const char **data, const char *end,
		   int depth)
{
	int total = 0;
#define PRINTF(...) SNPRINT(total, snprintf, buf, size, __VA_ARGS__)
#define SELF(d) SNPRINT(total, json_snprint_value, buf, size, d, end,	\
			depth + 1)
	JSON_PRINT(SELF, PRINTF);
#undef PRINTF
#undef SELF
	return total;
}

/** Render one JSON inner value to a FILE. Returns -1 on a write error. */
static int
json_fprint_value(FILE *file, const char **data, const char *end, int depth)
{
	int total = 0;
	bool failed = false;
#define PRINTF(...) do {						\
	if (!failed) {							\
		int written = fprintf(file, __VA_ARGS__);		\
		if (written < 0)					\
			failed = true;					\
		else							\
			total += written;				\
	}								\
} while (0)
#define SELF(d) do {							\
	if (!failed) {							\
		int written = json_fprint_value(file, d, end,		\
						depth + 1);			\
		if (written < 0)					\
			failed = true;					\
		else							\
			total += written;				\
	}								\
} while (0)
	JSON_PRINT(SELF, PRINTF);
#undef PRINTF
#undef SELF
	return failed ? -1 : total;
}

#undef JSON_PRINT

int
mp_snprint_json(char *buf, int size, const char **data, uint32_t len)
{
	const char *start = *data;
	int total = json_snprint_value(buf, size, data, start + len, 0);
	if (total < 0 || (uint32_t)(*data - start) != len)
		return -1;
	return total;
}

int
mp_fprint_json(FILE *file, const char **data, uint32_t len)
{
	const char *start = *data;
	int total = json_fprint_value(file, data, start + len, 0);
	if (total < 0 || (uint32_t)(*data - start) != len)
		return -1;
	return total;
}
