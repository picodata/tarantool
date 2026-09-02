#include "mp_json.h"
#include "mp_json_norm.h"
#include "mp_extension_types.h"
#include "msgpuck.h"
#include "decimal.h"
#include "mp_decimal.h"

#include "trivia/util.h"

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

/**
 * Encode the MP_EXT/MP_JSON envelope around @a payload, then verify the
 * envelope codec is a lossless, well-formed round-trip.
 */
static void
check_roundtrip(const char *payload, uint32_t len, const char *what)
{
	char buf[1024];
	/* Proof: this file builds every payload from mp_encode_*() calls. */
	struct json_norm norm = json_norm_from_trusted(payload, len);
	uint32_t envsize = mp_sizeof_json(norm);
	char *end = mp_encode_json(buf, norm);
	is(end - buf, (ptrdiff_t)envsize, "%s: encode length == mp_sizeof_json",
	   what);

	const char *p = buf;
	mp_next(&p);
	is(p, end, "%s: mp_next spans the whole MP_JSON value", what);

	p = buf;
	int8_t type;
	uint32_t l = mp_decode_extl(&p, &type);
	is(type, MP_JSON, "%s: ext subtype is MP_JSON", what);
	is(l, len, "%s: ext length is the inner length", what);

	p = buf;
	uint32_t got = 0;
	const char *inner = mp_decode_json(&p, &got);
	isnt(inner, NULL, "%s: mp_decode_json is non-NULL", what);
	is(got, len, "%s: mp_decode_json reports the inner length", what);
	is(p, end, "%s: mp_decode_json consumes the whole value", what);
	ok(inner != NULL && memcmp(inner, payload, len) == 0,
	   "%s: decoded inner bytes are byte-identical", what);
}

static int
test_codec(void)
{
	plan(8 * 12 + 3);
	header();

	char s[256];
	char *e;

	e = mp_encode_nil(s);
	check_roundtrip(s, e - s, "null");
	e = mp_encode_bool(s, true);
	check_roundtrip(s, e - s, "true");
	e = mp_encode_bool(s, false);
	check_roundtrip(s, e - s, "false");
	e = mp_encode_uint(s, 42);
	check_roundtrip(s, e - s, "uint 42");
	e = mp_encode_int(s, -7);
	check_roundtrip(s, e - s, "int -7");
	e = mp_encode_double(s, 1.5);
	check_roundtrip(s, e - s, "double 1.5");
	e = mp_encode_str0(s, "hi");
	check_roundtrip(s, e - s, "string");
	e = mp_encode_array(s, 0);
	check_roundtrip(s, e - s, "empty array");
	e = mp_encode_array(s, 3);
	e = mp_encode_uint(e, 1);
	e = mp_encode_uint(e, 2);
	e = mp_encode_uint(e, 3);
	check_roundtrip(s, e - s, "array [1,2,3]");
	e = mp_encode_map(s, 0);
	check_roundtrip(s, e - s, "empty map");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	check_roundtrip(s, e - s, "map {a:1}");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_array(e, 2);
	e = mp_encode_uint(e, 1);
	e = mp_encode_map(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	check_roundtrip(s, e - s, "nested {a:[1,{b:2}]}");

	const char *p = s;
	uint32_t got = 0;
	mp_encode_uint(s, 5);
	is(mp_decode_json(&p, &got), NULL,
	   "mp_decode_json rejects a plain uint");
	is(p, s, "mp_decode_json leaves the cursor put on failure");

	char x[16];
	char *xe = mp_encode_extl(x, MP_DECIMAL, 1);
	*xe = 0x00;
	p = x;
	is(mp_decode_json(&p, &got), NULL,
	   "mp_decode_json rejects a non-JSON ext");

	footer();
	return check_plan();
}

/** Encode @a levels nested 1-element arrays around a final nil scalar. */
static uint32_t
build_nested_array(char *buf, int levels)
{
	char *p = buf;
	for (int i = 0; i < levels; i++)
		p = mp_encode_array(p, 1);
	p = mp_encode_nil(p);
	return p - buf;
}

/**
 * Normalize @a in and assert the result is byte-identical to @a expect and no
 * larger than the input.
 *
 * The second assertion is that the output never grows, which is what makes
 * an input-sized buffer enough at every call site in the tree. That the output
 * verifies as normalized is pinned by test_equivalence() below.
 */
static void
check_normalize_eq(const char *in, const char *in_end,
		   const char *expect, const char *expect_end, const char *what)
{
	char out[1024];
	uint32_t in_len = (uint32_t)(in_end - in);
	char *end = tnt_json_normalize(in, in_len, out, out + sizeof(out),
				       NULL);
	ptrdiff_t got = end == NULL ? -1 : end - out;
	ptrdiff_t want = expect_end - expect;
	ok(end != NULL && got == want && memcmp(out, expect, want) == 0,
	   "%s: normalized bytes match expected", what);
	ok(end != NULL && got <= (ptrdiff_t)in_len,
	   "%s: output is no larger than input", what);
}

static void
check_normalize_err(const char *in, const char *in_end, const char *what)
{
	uint32_t in_len = (uint32_t)(in_end - in);
	char out[1024];
	is(tnt_json_normalize(in, in_len, out, out + sizeof(out), NULL), NULL,
	   "%s: normalize rejects", what);
}

static int
test_normalize(void)
{
	plan(51);
	header();

	char s[256];
	char x[256];
	char *e;
	char *xe;
	decimal_t dec;

	/* Scalars pass through unchanged. */
	e = mp_encode_nil(s);
	check_normalize_eq(s, e, s, e, "nil");
	e = mp_encode_bool(s, true);
	check_normalize_eq(s, e, s, e, "bool");
	e = mp_encode_uint(s, 7);
	check_normalize_eq(s, e, s, e, "uint 7");
	e = mp_encode_int(s, -7);
	check_normalize_eq(s, e, s, e, "int -7");
	e = mp_encode_str0(s, "hi");
	check_normalize_eq(s, e, s, e, "string");
	e = mp_encode_double(s, 1.5);
	check_normalize_eq(s, e, s, e, "fractional double 1.5 preserved");
	decimal_from_string(&dec, "1.50");
	e = mp_encode_decimal(s, &dec);
	check_normalize_eq(s, e, s, e, "fractional decimal 1.50 preserved");

	/*
	 * Numbers are preserved as written: normalization does not fold an
	 * integral double or decimal to an integer. Equal values in different
	 * encodings are reconciled by the by-value comparator, not by rewriting
	 * bytes, so nothing here grows.
	 */
	e = mp_encode_double(s, 1.0);
	check_normalize_eq(s, e, s, e, "integral double 1.0 preserved");
	e = mp_encode_double(s, -2.0);
	check_normalize_eq(s, e, s, e, "integral double -2.0 preserved");
	decimal_from_string(&dec, "5");
	e = mp_encode_decimal(s, &dec);
	check_normalize_eq(s, e, s, e, "integral decimal 5 preserved");
	decimal_from_string(&dec, "-3");
	e = mp_encode_decimal(s, &dec);
	check_normalize_eq(s, e, s, e, "integral decimal -3 preserved");

	/*
	 * A non-negative integer carried in an MP_INT marker is legal (if
	 * non-canonical) MessagePack that a non-Tarantool client may emit
	 * into a MAP/ARRAY value. It is canonicalized to the MP_UINT form:
	 * re-encoding it as MP_INT would trip mp_encode_int()'s
	 * assert(num < 0) (a server abort) or, with asserts off, emit a
	 * corrupt marker byte. These inputs are hand-built because
	 * mp_encode_int() itself rejects non-negative values.
	 */
	s[0] = (char)0xd0;	/* MP_INT int8 ... */
	s[1] = (char)0x05;	/* ... value 5 */
	xe = mp_encode_uint(x, 5);
	check_normalize_eq(s, s + 2, x, xe, "non-negative int8 5 -> uint 5");
	s[0] = (char)0xd1;	/* MP_INT int16 ... */
	s[1] = (char)0x00;
	s[2] = (char)0xc8;	/* ... value 200 */
	xe = mp_encode_uint(x, 200);
	check_normalize_eq(s, s + 3, x, xe,
			   "non-negative int16 200 -> uint 200");
	e = mp_encode_double(s, 1e19);
	check_normalize_eq(s, e, s, e, "integral double 1e19 preserved");
	e = mp_encode_double(s, 9223372036854775808.0);
	check_normalize_eq(s, e, s, e, "integral double 2^63 preserved");
	e = mp_encode_double(s, -9223372036854775808.0);
	check_normalize_eq(s, e, s, e, "integral double -2^63 preserved");
	e = mp_encode_double(s, 1e300);
	check_normalize_eq(s, e, s, e, "double 1e300 preserved (> uint64)");

	/*
	 * MP_FLOAT is not a JSON number. This used to assert that
	 * normalization succeeded, copying the float verbatim, and that a
	 * separate pass then rejected what normalization had just produced:
	 * two notions of valid, disagreeing. There is one now.
	 */
	e = mp_encode_array(s, 1);
	e = mp_encode_float(e, 4294967296.0f);
	check_normalize_err(s, e, "array holding an integral float");

	/* Object key sorting, dedup, recursion. */
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	xe = mp_encode_map(x, 2);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_uint(xe, 1);
	xe = mp_encode_str0(xe, "b");
	xe = mp_encode_uint(xe, 2);
	check_normalize_eq(s, e, x, xe, "{b:2,a:1} -> {a:1,b:2}");
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "aa");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	xe = mp_encode_map(x, 2);
	xe = mp_encode_str0(xe, "b");
	xe = mp_encode_uint(xe, 2);
	xe = mp_encode_str0(xe, "aa");
	xe = mp_encode_uint(xe, 1);
	check_normalize_eq(s, e, x, xe,
			   "{aa:1,b:2} -> {b:2,aa:1} (length-first)");
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 2);
	xe = mp_encode_map(x, 1);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_uint(xe, 2);
	check_normalize_eq(s, e, x, xe, "{a:1,a:2} -> {a:2} (dup last wins)");
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_double(e, 1.0);
	xe = mp_encode_map(x, 1);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_double(xe, 1.0);
	check_normalize_eq(s, e, x, xe,
			   "{a:1,a:1.0} -> {a:1.0} (dup last wins)");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_map(e, 2);
	e = mp_encode_str0(e, "d");
	e = mp_encode_uint(e, 4);
	e = mp_encode_str0(e, "c");
	e = mp_encode_uint(e, 3);
	xe = mp_encode_map(x, 1);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_map(xe, 2);
	xe = mp_encode_str0(xe, "c");
	xe = mp_encode_uint(xe, 3);
	xe = mp_encode_str0(xe, "d");
	xe = mp_encode_uint(xe, 4);
	check_normalize_eq(s, e, x, xe,
			   "nested {a:{d:4,c:3}} sorted recursively");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_double(e, 2.0);
	check_normalize_eq(s, e, s, e, "map value {a:2.0} preserved");
	e = mp_encode_array(s, 2);
	e = mp_encode_double(e, 1.0);
	e = mp_encode_double(e, 2.5);
	check_normalize_eq(s, e, s, e, "array [1.0,2.5] preserved");

	/* Errors. */
	e = mp_encode_map(s, 1);
	e = mp_encode_uint(e, 1);
	e = mp_encode_uint(e, 2);
	check_normalize_err(s, e, "non-string key");
	uint32_t deep_len = build_nested_array(s, JSON_MAX_NESTING_DEPTH);
	check_normalize_err(s, s + deep_len, "100-deep nested array");

	footer();
	return check_plan();
}

/* Tiny inner-value builders, each returning the end pointer. */
static char *
enull(char *b)
{
	return mp_encode_nil(b);
}

static char *
estr(char *b, const char *s)
{
	return mp_encode_str0(b, s);
}

static char *
euint(char *b, uint64_t u)
{
	return mp_encode_uint(b, u);
}

static char *
eint(char *b, int64_t i)
{
	return mp_encode_int(b, i);
}

static char *
edbl(char *b, double d)
{
	return mp_encode_double(b, d);
}

static char *
ebool(char *b, bool v)
{
	return mp_encode_bool(b, v);
}

static char *
edec(char *b, const char *s)
{
	decimal_t d;
	decimal_from_string(&d, s);
	return mp_encode_decimal(b, &d);
}

/**
 * Compare two inner values and assert the comparison sign and its
 * anti-symmetry. The comparator takes inner values rather than whole
 * MP_EXT/MP_JSON ones, so there is no envelope to build here.
 */
static void
check_cmp(const char *ia, const char *ia_end, const char *ib,
	  const char *ib_end, int expect, const char *what)
{
	/*
	 * Proof: both operands are built by this file from mp_encode_*() calls
	 * that emit the shortest form, with object keys written in ascending
	 * order, which is exactly the normal form.
	 */
	struct json_norm ca = json_norm_from_trusted(ia, ia_end - ia);
	struct json_norm cb = json_norm_from_trusted(ib, ib_end - ib);
	int r = mp_compare_json(ca, cb);
	int sign = r < 0 ? -1 : (r > 0 ? 1 : 0);
	is(sign, expect, "cmp(%s)", what);
	int r2 = mp_compare_json(cb, ca);
	int sign2 = r2 < 0 ? -1 : (r2 > 0 ? 1 : 0);
	is(sign2, -expect, "cmp(%s) anti-symmetric", what);
}

static int
test_compare(void)
{
	plan(66);
	header();

	char p[256];
	char q[256];

	/* Cross-class rank: null < string < number < bool < array < object. */
	check_cmp(p, enull(p), q, estr(q, "x"), -1, "null < string");
	check_cmp(p, estr(p, "x"), q, euint(q, 5), -1, "string < number");
	check_cmp(p, euint(p, 5), q, ebool(q, true), -1, "number < bool");
	{
		char *pe = mp_encode_array(p, 0);
		check_cmp(p, pe, q, ebool(q, true), 1, "array > bool");
	}
	{
		char *pe = mp_encode_array(p, 0);
		char *qe = mp_encode_map(q, 0);
		check_cmp(p, pe, q, qe, -1, "array < object");
	}
	{
		char *qe = mp_encode_map(q, 0);
		check_cmp(p, enull(p), q, qe, -1, "null < object");
	}

	/* Same-class comparisons. */
	check_cmp(p, enull(p), q, enull(q), 0, "null == null");
	check_cmp(p, estr(p, "b"), q, estr(q, "aa"), 1,
		  "string bytewise, not length");
	check_cmp(p, estr(p, "a"), q, estr(q, "b"), -1, "string bytewise");
	check_cmp(p, estr(p, "x"), q, estr(q, "x"), 0, "string equal");
	check_cmp(p, euint(p, 1), q, edbl(q, 1.0), 0, "uint 1 == double 1.0");
	check_cmp(p, edbl(p, 1.0), q, edec(q, "1.00"), 0,
		  "double 1.0 == decimal 1.00");
	check_cmp(p, edbl(p, 1.5), q, edec(q, "1.50"), 0,
		  "double 1.5 == decimal 1.50");
	check_cmp(p, euint(p, 1), q, euint(q, 2), -1, "uint 1 < uint 2");
	check_cmp(p, eint(p, -1), q, euint(q, 0), -1, "int -1 < uint 0");
	check_cmp(p, edbl(p, -1.5), q, euint(q, 0), -1, "double -1.5 < uint 0");
	check_cmp(p, ebool(p, false), q, ebool(q, true), -1, "false < true");
	check_cmp(p, ebool(p, true), q, ebool(q, true), 0, "true == true");
	{
		char *pe = mp_encode_array(p, 2);
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_uint(pe, 2);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 3);
		check_cmp(p, pe, q, qe, -1, "[1,2] < [1,3]");
	}
	{
		char *pe = mp_encode_array(p, 1);
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 2);
		check_cmp(p, pe, q, qe, -1, "[1] < [1,2] (size)");
	}
	{
		/* Count-first: fewer elements sorts below, even if larger. */
		char *pe = mp_encode_array(p, 1);
		pe = mp_encode_uint(pe, 2);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 1);
		check_cmp(p, pe, q, qe, -1, "[2] < [1,1] (count-first)");
	}
	{
		char *pe = mp_encode_array(p, 2);
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_uint(pe, 2);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 2);
		check_cmp(p, pe, q, qe, 0, "[1,2] == [1,2]");
	}
	{
		char *pe = mp_encode_map(p, 0);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 1);
		check_cmp(p, pe, q, qe, -1, "{} < {a:1} (size)");
	}
	{
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "b");
		qe = mp_encode_uint(qe, 1);
		check_cmp(p, pe, q, qe, -1, "{a:1} < {b:1} (key)");
	}
	{
		/*
		 * Object keys compare bytewise, not length-first: "aa" < "b",
		 * so the longer key sorts below. jsonb visits keys in stored
		 * (length-first) order but compares them by value.
		 */
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "aa");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "b");
		qe = mp_encode_uint(qe, 1);
		check_cmp(p, pe, q, qe, -1, "{aa:1} < {b:1} (key bytewise)");
	}
	{
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 2);
		check_cmp(p, pe, q, qe, -1, "{a:1} < {a:2} (value)");
	}
	{
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 1);
		check_cmp(p, pe, q, qe, 0, "{a:1} == {a:1}");
	}
	{
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 2);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_str0(qe, "b");
		qe = mp_encode_uint(qe, 2);
		check_cmp(p, pe, q, qe, -1, "{a:1} < {a:1,b:2} (size)");
	}

	/*
	 * Nested containers with an equal leading element followed by a
	 * differing one: the comparator must advance its cursor past the
	 * nested value before reaching the element that decides the order.
	 */
	{
		char *pe = mp_encode_array(p, 2);
		pe = mp_encode_array(pe, 2);
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_uint(pe, 2);
		pe = mp_encode_uint(pe, 3);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_array(qe, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 2);
		qe = mp_encode_uint(qe, 4);
		check_cmp(p, pe, q, qe, -1, "nested array prefix");
	}
	{
		char *pe = mp_encode_array(p, 2);
		pe = mp_encode_map(pe, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_uint(pe, 2);
		char *qe = mp_encode_array(q, 2);
		qe = mp_encode_map(qe, 1);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 3);
		check_cmp(p, pe, q, qe, -1, "nested map prefix");
	}
	{
		char *pe = mp_encode_map(p, 2);
		pe = mp_encode_str0(pe, "k");
		pe = mp_encode_array(pe, 2);
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_uint(pe, 2);
		pe = mp_encode_str0(pe, "z");
		pe = mp_encode_uint(pe, 3);
		char *qe = mp_encode_map(q, 2);
		qe = mp_encode_str0(qe, "k");
		qe = mp_encode_array(qe, 2);
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_uint(qe, 2);
		qe = mp_encode_str0(qe, "z");
		qe = mp_encode_uint(qe, 4);
		check_cmp(p, pe, q, qe, -1, "value after nested array");
	}
	{
		char *pe = mp_encode_map(p, 2);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_uint(pe, 1);
		pe = mp_encode_str0(pe, "b");
		pe = mp_encode_uint(pe, 2);
		char *qe = mp_encode_map(q, 2);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_uint(qe, 1);
		qe = mp_encode_str0(qe, "c");
		qe = mp_encode_uint(qe, 9);
		check_cmp(p, pe, q, qe, -1, "key after equal pair");
	}
	{
		char *pe = mp_encode_map(p, 1);
		pe = mp_encode_str0(pe, "a");
		pe = mp_encode_map(pe, 1);
		pe = mp_encode_str0(pe, "b");
		pe = mp_encode_uint(pe, 1);
		char *qe = mp_encode_map(q, 1);
		qe = mp_encode_str0(qe, "a");
		qe = mp_encode_map(qe, 1);
		qe = mp_encode_str0(qe, "b");
		qe = mp_encode_uint(qe, 2);
		check_cmp(p, pe, q, qe, -1, "deep map value");
	}

	footer();
	return check_plan();
}

/** One JSON number for check_cmp_number(), in one of the four kinds. */
struct num_case {
	enum { NUM_UINT, NUM_INT, NUM_DOUBLE, NUM_DECIMAL } kind;
	uint64_t u;
	int64_t i;
	double d;
	const char *dec;
};

static char *
enum_case(char *b, const struct num_case *c)
{
	switch (c->kind) {
	case NUM_UINT:
		return euint(b, c->u);
	case NUM_INT:
		return eint(b, c->i);
	case NUM_DOUBLE:
		return edbl(b, c->d);
	case NUM_DECIMAL:
		return edec(b, c->dec);
	}
	abort();
}

static int
cmp_cases(const struct num_case *a, const struct num_case *b)
{
	char pa[64], pb[64];
	char *ea = enum_case(pa, a);
	char *eb = enum_case(pb, b);
	int r = mp_compare_json(json_norm_from_trusted(pa, ea - pa),
				json_norm_from_trusted(pb, eb - pb));
	return r < 0 ? -1 : (r > 0 ? 1 : 0);
}

/**
 * Numbers of different kinds. A double counts as the decimal its shortest
 * round-trip digits spell, as in PostgreSQL jsonb, and every pair of kinds
 * has to agree on that, or sorting and DISTINCT break.
 */
static int
test_compare_numbers(void)
{
	plan(23);
	header();

	char p[64];
	char q[64];
	const double two53 = 9007199254740992.0;
	const double two60 = 1152921504606846976.0;

	/* The case from the review: 2^53 in three kinds. */
	check_cmp(p, edbl(p, two53), q, euint(q, 9007199254740992ULL), 0,
		  "double 2^53 == uint 2^53");
	check_cmp(p, euint(p, 9007199254740992ULL), q,
		  edec(q, "9007199254740992"), 0, "uint 2^53 == decimal 2^53");
	check_cmp(p, edbl(p, two53), q, edec(q, "9007199254740992"), 0,
		  "double 2^53 == decimal 2^53");

	check_cmp(p, edbl(p, 0.1), q, edec(q, "0.1"), 0,
		  "double 0.1 == decimal 0.1");
	check_cmp(p, edbl(p, 0.1), q,
		  edec(q, "0.1000000000000000055511151231257827"), -1,
		  "double 0.1 is 0.1, not its binary value");
	/* Past 2^53 a double is its shortest digits, not its exact value. */
	check_cmp(p, edbl(p, two60), q, euint(q, 1152921504606846976ULL), 1,
		  "double 2^60 is 1152921504606847000 > uint 2^60");
	check_cmp(p, edbl(p, two60), q, edec(q, "1152921504606847000"), 0,
		  "double 2^60 == decimal 1152921504606847000");
	/* Out of the decimal range: 1e-38 to 1e38. */
	check_cmp(p, edbl(p, 1e-300), q, edec(q, "0"), 1,
		  "double 1e-300 > decimal 0");
	check_cmp(p, edbl(p, 1e300), q,
		  edec(q, "99999999999999999999999999999999999999"), 1,
		  "double 1e300 > the largest decimal");
	check_cmp(p, edbl(p, -1e300), q, edec(q, "-1"), -1,
		  "double -1e300 < decimal -1");
	check_cmp(p, edbl(p, -0.0), q, edec(q, "0"), 0,
		  "double -0 == decimal 0");

#define U(x) {.kind = NUM_UINT, .u = (x)}
#define I(x) {.kind = NUM_INT, .i = (x)}
#define D(x) {.kind = NUM_DOUBLE, .d = (x)}
#define M(x) {.kind = NUM_DECIMAL, .dec = (x)}
	/*
	 * Every triple of awkward values: the order has to be transitive and
	 * equality has to be an equivalence, or a sort has no right answer.
	 */
	const struct num_case cases[] = {
		U(0), U(1),
		U(9007199254740991ULL), U(9007199254740992ULL),
		U(9007199254740993ULL),
		U(1152921504606846976ULL),
		U(1152921504606847000ULL), U(UINT64_MAX),
		I(-1), I(-9007199254740992LL),
		I(-1152921504606846976LL), I(INT64_MIN),
		D(0.0), D(-0.0),
		D(0.1), D(-0.1),
		D(0.3), D(0.1 + 0.2),
		D(1.0), D(two53),
		D(two53 + 2), D(-two53),
		D(two60), D(-two60),
		D(1e19), D(18446744073709551616.0),
		D(1 / 1e300), D(DBL_TRUE_MIN),
		D(1e300), D(-1e300),
		D(1e38), D(1 / 1e38),
		M("0"), M("0.1"),
		M("-0.1"), M("0.3"),
		M("0.30000000000000004"),
		M("0.1000000000000000055511151231257827"),
		M("9007199254740992"),
		M("9007199254740993"),
		M("1152921504606846976"),
		M("1152921504606847000"),
		M("18446744073709551616"),
		M("99999999999999999999999999999999999999"),
		M("1E+37"),
		M("0.00000000000000000000000000000000000001"),
	};
#undef U
#undef I
#undef D
#undef M
	const int n = lengthof(cases);
	int bad = 0;
	for (int a = 0; a < n; a++) {
		for (int b = 0; b < n; b++) {
			int ab = cmp_cases(&cases[a], &cases[b]);
			if (ab != -cmp_cases(&cases[b], &cases[a]))
				bad++;
			for (int c = 0; c < n; c++) {
				int bc = cmp_cases(&cases[b], &cases[c]);
				int ac = cmp_cases(&cases[a], &cases[c]);
				if (ab <= 0 && bc <= 0 && ac > 0)
					bad++;
				if (ab == 0 && bc == 0 && ac != 0)
					bad++;
			}
		}
	}
	is(bad, 0, "number order is transitive and antisymmetric");

	footer();
	return check_plan();
}

static void
check_render(const char *inner, const char *inner_end, const char *expect,
	     const char *what)
{
	uint32_t len = inner_end - inner;
	char out[1024];
	const char *p = inner;
	int n = mp_snprint_json(out, sizeof(out), &p, len);
	is(n, (int)strlen(expect), "%s: snprint length", what);
	is(strcmp(out, expect), 0, "%s: snprint text", what);
	is(p, inner_end, "%s: snprint consumed all input", what);
	p = inner;
	is(mp_snprint_json(NULL, 0, &p, len), (int)strlen(expect),
	   "%s: snprint size query", what);
}

static void
check_fprint(const char *inner, const char *inner_end, const char *expect,
	     const char *what)
{
	uint32_t len = inner_end - inner;
	FILE *f = tmpfile();
	const char *p = inner;
	int n = mp_fprint_json(f, &p, len);
	is(n, (int)strlen(expect), "%s: fprint length", what);
	rewind(f);
	char buf[1024];
	size_t got = fread(buf, 1, sizeof(buf) - 1, f);
	buf[got] = 0;
	is(strcmp(buf, expect), 0, "%s: fprint text", what);
	fclose(f);
}

/**
 * A payload the renderer must refuse: both variants report the failure and
 * neither aborts, whether or not NDEBUG is set.
 */
static void
check_render_fails(const char *inner, const char *inner_end, const char *what)
{
	uint32_t len = inner_end - inner;
	char out[1024];
	const char *p = inner;
	is(mp_snprint_json(out, sizeof(out), &p, len), -1,
	   "%s: snprint", what);
	FILE *f = tmpfile();
	p = inner;
	is(mp_fprint_json(f, &p, len), -1, "%s: fprint", what);
	fclose(f);
}

static int
test_render(void)
{
	plan(90);
	header();

	char s[256];
	char *e;
	decimal_t dec;

	e = mp_encode_nil(s);
	check_render(s, e, "null", "null");
	e = mp_encode_bool(s, true);
	check_render(s, e, "true", "true");
	e = mp_encode_bool(s, false);
	check_render(s, e, "false", "false");
	e = mp_encode_uint(s, 42);
	check_render(s, e, "42", "uint");
	e = mp_encode_int(s, -7);
	check_render(s, e, "-7", "int");
	e = mp_encode_double(s, 1.5);
	check_render(s, e, "1.5", "double");
	/* Doubles print with the fewest digits that read back as them. */
	e = mp_encode_double(s, 1.0000000000000002);
	check_render(s, e, "1.0000000000000002", "double needing 17 digits");
	e = mp_encode_double(s, 9007199254740992.0);
	check_render(s, e, "9007199254740992", "double 2^53");
	e = mp_encode_double(s, 0.1);
	check_render(s, e, "0.1", "double 0.1");
	e = mp_encode_double(s, 5e-324);
	check_render(s, e, "5e-324", "subnormal double");
	e = mp_encode_str0(s, "hi");
	check_render(s, e, "\"hi\"", "string");
	e = mp_encode_str0(s, "he\"llo");
	check_render(s, e, "\"he\\\"llo\"", "string with escaped quote");
	decimal_from_string(&dec, "3.14");
	e = mp_encode_decimal(s, &dec);
	check_render(s, e, "3.14", "decimal");
	e = mp_encode_array(s, 0);
	check_render(s, e, "[]", "empty array");
	e = mp_encode_array(s, 3);
	e = mp_encode_uint(e, 1);
	e = mp_encode_uint(e, 2);
	e = mp_encode_uint(e, 3);
	check_render(s, e, "[1, 2, 3]", "array");
	e = mp_encode_map(s, 0);
	check_render(s, e, "{}", "empty map");
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	check_render(s, e, "{\"a\": 1, \"b\": 2}", "map");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_array(e, 2);
	e = mp_encode_uint(e, 1);
	e = mp_encode_map(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	check_render(s, e, "{\"a\": [1, {\"b\": 2}]}", "nested");

	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_array(e, 2);
	e = mp_encode_uint(e, 1);
	e = mp_encode_map(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 2);
	check_fprint(s, e, "{\"a\": [1, {\"b\": 2}]}", "nested fprint");

	/*
	 * Validation is the caller's contract, but breaking it must be
	 * reported rather than asserted on: unreachable() is undefined
	 * behaviour under NDEBUG, and these payloads are exactly what a JSON
	 * cdata forged via FFI can carry.
	 */
	e = mp_encode_bin(s, "", 0);
	check_render_fails(s, e, "MP_BIN is not a JSON kind");
	e = mp_encode_float(s, 1.5);
	check_render_fails(s, e, "MP_FLOAT is not a JSON number kind");
	e = mp_encode_extl(s, MP_UUID, 16);
	memset(e, 0, 16);
	e += 16;
	check_render_fails(s, e, "MP_DECIMAL is the only JSON extension");
	e = mp_encode_array(s, 1);
	e = mp_encode_bin(e, "", 0);
	check_render_fails(s, e, "a nested non-JSON kind fails too");

	/*
	 * The printer must not read past its input and must not recurse
	 * without bound. Both inputs below are what a malformed subtype-20
	 * payload looks like once the check hook stops refusing it at
	 * decode: the error path that logs a refused request prints the
	 * exact bytes that were turned away.
	 */
	{
		/* A fixstr header claiming 31 bytes, with 1 byte present. */
		char *trunc = xmalloc(2);
		trunc[0] = (char)0xbf;
		trunc[1] = 'a';
		char buf[64];
		const char *p = trunc;
		is(mp_snprint_json(buf, sizeof(buf), &p, 2), -1,
		   "printer rejects a truncated string rather than "
		   "overreading");
		free(trunc);
	}
	/*
	 * Number kinds are never folded, so one document has several normalized
	 * spellings. Each is a fixpoint of tnt_json_normalize, and
	 * mp_compare_json calls every pair equal.
	 *
	 * So memcmp() == 0 implies equality and is a sound fast path, while
	 * memcmp() != 0 implies nothing. This test fails if someone folds them.
	 */
	{
		char u[16], d[16], c[16];
		decimal_t one;
		char *ue = mp_encode_uint(u, 1);
		char *de = mp_encode_double(d, 1.0);
		decimal_from_string(&one, "1");
		char *ce = mp_encode_decimal(c, &one);
		struct {
			const char *data;
			uint32_t len;
			const char *what;
		} kinds[] = {
			{u, (uint32_t)(ue - u), "uint 1"},
			{d, (uint32_t)(de - d), "double 1e0"},
			{c, (uint32_t)(ce - c), "decimal 1"},
		};
		/* Each spelling is already normal form: none folds away. */
		for (int i = 0; i < 3; i++) {
			char out[64];
			char *end = tnt_json_normalize(kinds[i].data,
						       kinds[i].len, out,
						       out + sizeof(out),
						       NULL);
			ok(end != NULL &&
			   (uint32_t)(end - out) == kinds[i].len &&
			   memcmp(out, kinds[i].data, kinds[i].len) == 0,
			   "%s is a fixpoint", kinds[i].what);
		}
		/* And the comparator calls all three equal. */
		for (int i = 0; i < 3; i++) {
			for (int j = i + 1; j < 3; j++) {
				struct json_norm a = json_norm_from_trusted(
					kinds[i].data, kinds[i].len);
				struct json_norm b = json_norm_from_trusted(
					kinds[j].data, kinds[j].len);
				is(mp_compare_json(a, b), 0,
				   "%s == %s despite different bytes",
				   kinds[i].what, kinds[j].what);
			}
		}
	}
	{
		/* Deeper than any bound the hook could pass down. */
		char deep[512];
		char *dp = deep;
		for (int i = 0; i < 500; i++)
			dp = mp_encode_array(dp, 1);
		char buf[64];
		const char *p = deep;
		is(mp_snprint_json(buf, sizeof(buf), &p,
				   (uint32_t)(dp - deep)), -1,
		   "printer rejects unbounded nesting");
	}

	footer();
	return check_plan();
}

static void
check_norm(const char *data, uint32_t len, const char *what)
{
	is(json_verify(data, len, NULL), JSON_NORM_OK, "normalized: %s", what);
	ok(json_is_normalized(data, len), "predicate agrees: %s", what);
}

static void
check_rewritable(const char *data, uint32_t len, const char *what)
{
	is(json_verify(data, len, NULL), JSON_NORM_REWRITABLE,
	   "rewritable: %s", what);
	ok(!json_is_normalized(data, len), "predicate agrees: %s", what);
}

static void
check_invalid(const char *data, uint32_t len, const char *what)
{
	is(json_verify(data, len, NULL), JSON_NORM_INVALID,
	   "invalid: %s", what);
}

static int
test_verify_scalars(void)
{
	plan(37);
	header();

	char s[256];
	char *e;

	/* Minimal integer encodings are normalized. */
	e = mp_encode_uint(s, 1);
	check_norm(s, e - s, "fixint 1");
	e = mp_encode_uint(s, 0x80);
	check_norm(s, e - s, "uint8 0x80");
	e = mp_encode_uint(s, 0x10000);
	check_norm(s, e - s, "uint32 0x10000");
	e = mp_encode_int(s, -1);
	check_norm(s, e - s, "negative fixint -1");
	e = mp_encode_int(s, -1000);
	check_norm(s, e - s, "int16 -1000");

	/* A too-wide integer header is rewritable, not invalid. */
	e = mp_store_u8(s, 0xcc);
	e = mp_store_u8(e, 1);
	check_rewritable(s, e - s, "uint8-encoded 1");
	e = mp_store_u8(s, 0xd0);
	e = mp_store_u8(e, (uint8_t)(int8_t)-1);
	check_rewritable(s, e - s, "int8-encoded -1");
	/* A non-negative value under an MP_INT marker: normal form is uint. */
	e = mp_store_u8(s, 0xd0);
	e = mp_store_u8(e, 7);
	check_rewritable(s, e - s, "int8-encoded 7 (non-negative MP_INT)");

	/* Strings: fixstr up to 31 bytes, then str8. This is a new rule. */
	e = mp_encode_str0(s, "a");
	check_norm(s, e - s, "fixstr \"a\"");
	e = mp_store_u8(s, 0xd9);
	e = mp_store_u8(e, 1);
	e = mp_memcpy(e, "a", 1);
	check_rewritable(s, e - s, "str8-encoded \"a\"");
	char body[32];
	memset(body, 'x', sizeof(body));
	e = mp_encode_str(s, body, sizeof(body));
	check_norm(s, e - s, "str8 of 32 bytes is minimal");

	/* nil, bool and double have one encoding each. */
	e = mp_encode_nil(s);
	check_norm(s, e - s, "nil");
	e = mp_encode_bool(s, true);
	check_norm(s, e - s, "true");
	e = mp_encode_double(s, 2.5);
	check_norm(s, e - s, "double 2.5");

	/* Rejected kinds. */
	e = mp_encode_float(s, 2.5f);
	check_invalid(s, e - s, "MP_FLOAT is not a JSON number kind");
	e = mp_encode_double(s, NAN);
	check_invalid(s, e - s, "NaN");
	e = mp_encode_double(s, INFINITY);
	check_invalid(s, e - s, "+Inf");
	e = mp_encode_bin(s, "\x01", 1);
	check_invalid(s, e - s, "MP_BIN");
	e = mp_encode_extl(s, MP_UUID, 16);
	memset(e, 0, 16);
	e += 16;
	check_invalid(s, e - s, "ext UUID");
	e = mp_store_u8(s, 0xc1);
	check_invalid(s, e - s, "0xc1 never-used lead byte");
	/*
	 * A zero-length ext payload is encodable and arrives from the wire.
	 * decimal_unpack() asserts len > 0, so this must be rejected before
	 * the decimal validator is reached.
	 */
	e = mp_store_u8(s, 0xc7);
	e = mp_store_u8(e, 0);
	e = mp_store_u8(e, (uint8_t)MP_DECIMAL);
	check_invalid(s, e - s, "zero-length decimal ext");
	e = mp_encode_uint(s, 7);
	check_invalid(s, (uint32_t)(e - s) - 1, "truncated value");
	e = mp_encode_uint(s, 7);
	e = mp_encode_uint(e, 8);
	check_invalid(s, e - s, "two values (trailing data)");

	footer();
	return check_plan();
}

/**
 * Encode @a levels nested arrays whose innermost one is empty, so no value
 * ever sits at the deepest level.
 */
static uint32_t
build_nested_empty_array(char *buf, int levels)
{
	char *p = buf;
	for (int i = 0; i < levels - 1; i++)
		p = mp_encode_array(p, 1);
	p = mp_encode_array(p, 0);
	return p - buf;
}

static int
test_verify_containers(void)
{
	plan(28);
	header();

	char s[512];
	char *e;

	e = mp_encode_array(s, 0);
	check_norm(s, e - s, "empty array");
	e = mp_encode_map(s, 0);
	check_norm(s, e - s, "empty map");

	e = mp_encode_array(s, 3);
	e = mp_encode_uint(e, 1);
	e = mp_encode_uint(e, 2);
	e = mp_encode_uint(e, 3);
	check_norm(s, e - s, "[1,2,3]");

	/* Keys ascend by (length, bytes). */
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "bb");
	e = mp_encode_uint(e, 2);
	check_norm(s, e - s, "{a:1, bb:2} sorted length-first");

	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "bb");
	e = mp_encode_uint(e, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	check_rewritable(s, e - s, "{bb:2, a:1} unsorted");

	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 2);
	check_rewritable(s, e - s, "{a:1, a:2} duplicate key");

	e = mp_store_u8(s, 0xdc);
	e = mp_store_u16(e, 1);
	e = mp_encode_uint(e, 1);
	check_rewritable(s, e - s, "array16 header for one element");
	e = mp_store_u8(s, 0xde);
	e = mp_store_u16(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	check_rewritable(s, e - s, "map16 header for one pair");

	e = mp_encode_array(s, 1);
	e = mp_store_u8(e, 0xcc);
	e = mp_store_u8(e, 1);
	check_rewritable(s, e - s, "[uint8-encoded 1]");

	/* Fatal findings win over non-normalization found earlier. */
	e = mp_store_u8(s, 0xdc);
	e = mp_store_u16(e, 2);
	e = mp_encode_uint(e, 1);
	e = mp_encode_bin(e, "\x01", 1);
	check_invalid(s, e - s, "array16 header then MP_BIN element");

	e = mp_encode_map(s, 1);
	e = mp_encode_uint(e, 1);
	e = mp_encode_uint(e, 2);
	check_invalid(s, e - s, "non-string object key");

	/* An oversized element count fails on the element that is not there. */
	e = mp_encode_array(s, 4);
	e = mp_encode_uint(e, 1);
	check_invalid(s, e - s, "array claims 4 elements, holds 1");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	check_invalid(s, e - s, "map claims a pair, holds only the key");

	/* The depth bound is unchanged: the innermost value is at depth 99. */
	uint32_t deep = build_nested_array(s, JSON_MAX_NESTING_DEPTH - 1);
	check_norm(s, deep, "99-deep nested array");
	uint32_t too_deep = build_nested_array(s, JSON_MAX_NESTING_DEPTH);
	check_invalid(s, too_deep, "100-deep nested array");
	/*
	 * The bound is on values, not containers: 100 nested empty arrays put
	 * no value at depth 100, so they are accepted, and a 101st array is the
	 * first value that is too deep. tnt_json_parse()'s nesting test depends
	 * on this boundary.
	 */
	uint32_t empty_deep = build_nested_empty_array(s,
						       JSON_MAX_NESTING_DEPTH);
	check_norm(s, empty_deep, "100 nested arrays, innermost empty");
	uint32_t empty_too_deep =
		build_nested_empty_array(s, JSON_MAX_NESTING_DEPTH + 1);
	check_invalid(s, empty_too_deep, "101 nested arrays, innermost empty");

	footer();
	return check_plan();
}

/**
 * Feed json_verify() every prefix of a valid value. Each one is either
 * truncated mid-header or missing bytes the header promises, so all of them
 * must be rejected without reading past the buffer.
 */
static void
check_truncations(const char *data, uint32_t len, const char *what)
{
	for (uint32_t n = 0; n < len; n++) {
		/*
		 * Copy the prefix so that a read past the end lands outside a
		 * live allocation, where ASAN sees it.
		 */
		char *buf = xmalloc(n + 1);
		memcpy(buf, data, n);
		enum json_norm_status rc = json_verify(buf, n, NULL);
		free(buf);
		if (rc != JSON_NORM_INVALID) {
			is(rc, JSON_NORM_INVALID, "truncated to %u bytes: %s",
			   n, what);
			return;
		}
	}
	ok(true, "every prefix rejected: %s", what);
}

/**
 * json_verify() takes bytes straight off the wire, so it must reject malformed
 * input rather than walk off the end of it. Sweeps rather than hand-picked
 * cases: only as strong as the sanitizer they run under, but they cover every
 * decode path the verifier has.
 */
static int
test_verify_malformed(void)
{
	plan(7);
	header();

	char s[256];
	char *e;
	decimal_t dec;

	/* Truncation sweep: every prefix of a valid value. */
	e = mp_encode_str0(s, "a longer string, encoded with an str8 header");
	check_truncations(s, e - s, "string");
	e = mp_encode_double(s, 2.5);
	check_truncations(s, e - s, "double");
	decimal_from_string(&dec, "1.5");
	e = mp_encode_decimal(s, &dec);
	check_truncations(s, e - s, "decimal ext");
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_array(e, 2);
	e = mp_encode_uint(e, 1);
	e = mp_encode_map(e, 1);
	e = mp_encode_str0(e, "b");
	e = mp_encode_double(e, 2.5);
	check_truncations(s, e - s, "nested {a:[1,{b:2.5}]}");
	uint32_t deep_len = build_nested_array(s, JSON_MAX_NESTING_DEPTH - 1);
	check_truncations(s, deep_len, "99-deep nested array");

	/*
	 * Lead-byte sweep: every possible first byte, at every buffer length
	 * that can leave a header incomplete, with 0xff filler so length fields
	 * decode to the largest values they can hold. A verdict on all of them
	 * without an out-of-bounds read. This catches a lead byte mp_typeof()
	 * classifies but mp_check_*() does not accept: 0xc1 is "never used",
	 * yet mp_type_hint reports it MP_EXT.
	 */
	bool sane = true;
	for (unsigned c = 0; c <= UINT8_MAX; c++) {
		for (uint32_t len = 1; len <= 10; len++) {
			char *buf = xmalloc(len);
			memset(buf, 0xff, len);
			buf[0] = (char)c;
			enum json_norm_status rc = json_verify(buf, len, NULL);
			free(buf);
			if (rc != JSON_NORM_OK && rc != JSON_NORM_REWRITABLE &&
			    rc != JSON_NORM_INVALID)
				sane = false;
		}
	}
	ok(sane, "lead-byte sweep: no crash, no out-of-range verdict");
	/* 0xc1 specifically: MP_EXT by mp_typeof(), undecodable in fact. */
	s[0] = (char)0xc1;
	check_invalid(s, 1, "0xc1 (never used) lead byte");

	footer();
	return check_plan();
}

/**
 * Rewrite @a in and assert the result is byte-identical to @a expect and is
 * itself normalized, which is the fixpoint property in both directions.
 */
static void
check_rewrite_eq(const char *in, uint32_t in_len, const char *expect,
		 uint32_t expect_len, const char *what)
{
	char out[1024];
	char *end = json_normalize_rewrite(in, in_len, out, out + sizeof(out));
	ptrdiff_t got = end == NULL ? -1 : end - out;
	ok(end != NULL && got == (ptrdiff_t)expect_len &&
	   memcmp(out, expect, expect_len) == 0,
	   "%s: rewritten bytes match expected", what);
	ok(end != NULL && json_is_normalized(out, (uint32_t)got),
	   "%s: rewritten output is normalized", what);
	ok(end != NULL && got <= (ptrdiff_t)in_len,
	   "%s: output is no larger than input", what);
}

static int
test_rewrite(void)
{
	plan(39);
	header();

	char s[512];
	char x[512];
	char *e;
	char *xe;

	/* The four shapes accepted and stored non-normalized today. */
	e = mp_store_u8(s, 0xcc);
	e = mp_store_u8(e, 1);
	xe = mp_encode_uint(x, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "uint8-encoded 1");

	e = mp_store_u8(s, 0xdc);
	e = mp_store_u16(e, 1);
	e = mp_encode_uint(e, 1);
	xe = mp_encode_array(x, 1);
	xe = mp_encode_uint(xe, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "array16 header, 1 element");

	e = mp_store_u8(s, 0xde);
	e = mp_store_u16(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 1);
	xe = mp_encode_map(x, 1);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_uint(xe, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "map16 header, 1 pair");

	e = mp_encode_map(s, 1);
	e = mp_store_u8(e, 0xd9);
	e = mp_store_u8(e, 1);
	e = mp_memcpy(e, "a", 1);
	e = mp_encode_uint(e, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "str8 key shrinks to fixstr");

	/* New rule: a string VALUE is re-emitted minimally too. */
	e = mp_encode_array(s, 1);
	e = mp_store_u8(e, 0xd9);
	e = mp_store_u8(e, 1);
	e = mp_memcpy(e, "a", 1);
	xe = mp_encode_array(x, 1);
	xe = mp_encode_str0(xe, "a");
	check_rewrite_eq(s, e - s, x, xe - x, "str8 value shrinks to fixstr");

	/*
	 * New rule: an ext header is re-emitted minimally. A 4-byte decimal
	 * payload belongs under fixext4 (0xd6), not ext8 (0xc7).
	 */
	char dec_body[4] = { 0x02, 0x01, 0x23, 0x4c };
	e = mp_store_u8(s, 0xc7);
	e = mp_store_u8(e, sizeof(dec_body));
	e = mp_store_u8(e, (uint8_t)MP_DECIMAL);
	e = mp_memcpy(e, dec_body, sizeof(dec_body));
	xe = mp_encode_ext(x, MP_DECIMAL, dec_body, sizeof(dec_body));
	check_rewrite_eq(s, e - s, x, xe - x, "ext8 decimal header shrinks");

	e = mp_store_u8(s, 0xd0);
	e = mp_store_u8(e, 7);
	xe = mp_encode_uint(x, 7);
	check_rewrite_eq(s, e - s, x, xe - x,
			 "non-negative MP_INT becomes uint");

	/* Keys sort length-first, duplicates collapse last-wins. */
	e = mp_encode_map(s, 3);
	e = mp_encode_str0(e, "bb");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_uint(e, 3);
	xe = mp_encode_map(x, 2);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_uint(xe, 3);
	xe = mp_encode_str0(xe, "bb");
	xe = mp_encode_uint(xe, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "unsorted with a duplicate");

	/* Nested rewriting. */
	e = mp_encode_map(s, 1);
	e = mp_encode_str0(e, "a");
	e = mp_encode_array(e, 1);
	e = mp_store_u8(e, 0xcc);
	e = mp_store_u8(e, 1);
	xe = mp_encode_map(x, 1);
	xe = mp_encode_str0(xe, "a");
	xe = mp_encode_array(xe, 1);
	xe = mp_encode_uint(xe, 1);
	check_rewrite_eq(s, e - s, x, xe - x, "{a:[uint8 1]}");

	/*
	 * The one instrument that is not compiled out: an undersized output
	 * buffer returns NULL rather than writing past out_end.
	 */
	e = mp_encode_array(s, 2);
	e = mp_store_u8(e, 0xcc);
	e = mp_store_u8(e, 1);
	e = mp_encode_uint(e, 2);
	char tiny[2];
	is(json_normalize_rewrite(s, e - s, tiny, tiny + sizeof(tiny)), NULL,
	   "undersized output buffer returns NULL");
	is(json_normalize_rewrite(s, e - s, tiny, tiny), NULL,
	   "zero-capacity output buffer returns NULL");

	/*
	 * Both sort paths must produce identical bytes. 40 keys crosses
	 * JSON_KV_SORT_MAX and 8 does not; reverse order maximises inversions
	 * and every key is duplicated once, so last-wins is exercised too.
	 */
	for (int count = 8; count <= 40; count += 32) {
		char big[8192];
		char want[8192];
		char *bp = mp_encode_map(big, count * 2);
		for (int i = count - 1; i >= 0; i--) {
			char key[16];
			snprintf(key, sizeof(key), "k%02d", i);
			bp = mp_encode_str0(bp, key);
			bp = mp_encode_uint(bp, 1000 + i);
			bp = mp_encode_str0(bp, key);
			bp = mp_encode_uint(bp, i);
		}
		char *wp = mp_encode_map(want, count);
		for (int i = 0; i < count; i++) {
			char key[16];
			snprintf(key, sizeof(key), "k%02d", i);
			wp = mp_encode_str0(wp, key);
			wp = mp_encode_uint(wp, i);
		}
		char out[8192];
		char *end = json_normalize_rewrite(big, bp - big, out,
						   out + sizeof(out));
		ok(end != NULL && end - out == wp - want &&
		   memcmp(out, want, wp - want) == 0,
		   "%d-key reverse-sorted object with duplicates", count);
		ok(end != NULL &&
		   json_is_normalized(out, (uint32_t)(end - out)),
		   "%d-key result is normalized", count);
		ok(end != NULL && end - out <= bp - big,
		   "%d-key output is no larger than input", count);
	}
	/*
	 * Determinism above the switch point. The sort must be stable, so the
	 * surviving duplicate is the last one in input order regardless of how
	 * the keys were permuted on the way in. An unstable sort passes the
	 * loop above, which feeds one fixed permutation, and fails here.
	 */
	{
		char in_a[4096], in_b[4096], out_a[4096], out_b[4096];
		char *pa = mp_encode_map(in_a, 128);
		char *pb = mp_encode_map(in_b, 128);
		for (int i = 0; i < 64; i++) {
			char key[16];
			snprintf(key, sizeof(key), "k%02d", i);
			/* Interleaved: the duplicate is adjacent. */
			pa = mp_encode_str0(pa, key);
			pa = mp_encode_uint(pa, 1000 + i);
			pa = mp_encode_str0(pa, key);
			pa = mp_encode_uint(pa, i);
		}
		for (int i = 0; i < 64; i++) {
			char key[16];
			snprintf(key, sizeof(key), "k%02d", i);
			/* Blocked: every first, then every second. */
			pb = mp_encode_str0(pb, key);
			pb = mp_encode_uint(pb, 1000 + i);
		}
		for (int i = 0; i < 64; i++) {
			char key[16];
			snprintf(key, sizeof(key), "k%02d", i);
			pb = mp_encode_str0(pb, key);
			pb = mp_encode_uint(pb, i);
		}
		char *ea = json_normalize_rewrite(in_a, pa - in_a, out_a,
						  out_a + sizeof(out_a));
		char *eb = json_normalize_rewrite(in_b, pb - in_b, out_b,
						  out_b + sizeof(out_b));
		ok(ea != NULL && eb != NULL && ea - out_a == eb - out_b &&
		   memcmp(out_a, out_b, ea - out_a) == 0,
		   "64 keys, two permutations, last-wins gives one answer");
		/* And the winner is the second occurrence, not the first. */
		const char *p = out_a;
		uint32_t n = mp_decode_map(&p);
		ok(n == 64, "64 keys survive deduplication");
		uint32_t klen;
		const char *k = mp_decode_str(&p, &klen);
		ok(klen == 3 && memcmp(k, "k00", 3) == 0, "first key is k00");
		ok(mp_decode_uint(&p) == 0, "last occurrence won");
	}

	footer();
	return check_plan();
}

/**
 * The corpus every property below runs over: one entry per normalization
 * rule, normalized and non-normalized alike.
 */
struct json_corpus_entry {
	char data[256];
	uint32_t len;
	/** What it exercises, for the assertion message. */
	const char *what;
};

static int
build_corpus(struct json_corpus_entry *corpus)
{
	int n = 0;
#define ENTRY(desc)							\
	corpus[n].what = (desc);					\
	char *e = corpus[n].data;					\
	(void)e
#define END() corpus[n].len = (uint32_t)(e - corpus[n].data); n++

	{ ENTRY("fixint"); e = mp_encode_uint(e, 1); END(); }
	{ ENTRY("uint8-encoded 1"); e = mp_store_u8(e, 0xcc);
	  e = mp_store_u8(e, 1); END(); }
	{ ENTRY("negative int"); e = mp_encode_int(e, -1000); END(); }
	{ ENTRY("int8-encoded 7"); e = mp_store_u8(e, 0xd0);
	  e = mp_store_u8(e, 7); END(); }
	{ ENTRY("nil"); e = mp_encode_nil(e); END(); }
	{ ENTRY("bool"); e = mp_encode_bool(e, false); END(); }
	{ ENTRY("double"); e = mp_encode_double(e, 2.5); END(); }
	{ ENTRY("fixstr"); e = mp_encode_str0(e, "abc"); END(); }
	{ ENTRY("str8-encoded short string"); e = mp_store_u8(e, 0xd9);
	  e = mp_store_u8(e, 3); e = mp_memcpy(e, "abc", 3); END(); }
	{ ENTRY("empty array"); e = mp_encode_array(e, 0); END(); }
	{ ENTRY("empty map"); e = mp_encode_map(e, 0); END(); }
	{ ENTRY("array16 header"); e = mp_store_u8(e, 0xdc);
	  e = mp_store_u16(e, 1); e = mp_encode_uint(e, 1); END(); }
	{ ENTRY("map16 header"); e = mp_store_u8(e, 0xde);
	  e = mp_store_u16(e, 1); e = mp_encode_str0(e, "a");
	  e = mp_encode_uint(e, 1); END(); }
	{ ENTRY("sorted map"); e = mp_encode_map(e, 2);
	  e = mp_encode_str0(e, "a"); e = mp_encode_uint(e, 1);
	  e = mp_encode_str0(e, "bb"); e = mp_encode_uint(e, 2); END(); }
	{ ENTRY("unsorted map"); e = mp_encode_map(e, 2);
	  e = mp_encode_str0(e, "bb"); e = mp_encode_uint(e, 2);
	  e = mp_encode_str0(e, "a"); e = mp_encode_uint(e, 1); END(); }
	{ ENTRY("duplicate keys"); e = mp_encode_map(e, 2);
	  e = mp_encode_str0(e, "a"); e = mp_encode_uint(e, 1);
	  e = mp_encode_str0(e, "a"); e = mp_encode_uint(e, 2); END(); }
	{ ENTRY("nested"); e = mp_encode_map(e, 1);
	  e = mp_encode_str0(e, "a"); e = mp_encode_array(e, 2);
	  e = mp_encode_uint(e, 1); e = mp_encode_map(e, 1);
	  e = mp_encode_str0(e, "b"); e = mp_encode_double(e, 2.5); END(); }
	{ ENTRY("decimal under ext8"); char body[2] = { 0x01, 0x1c };
	  e = mp_store_u8(e, 0xc7); e = mp_store_u8(e, sizeof(body));
	  e = mp_store_u8(e, (uint8_t)MP_DECIMAL);
	  e = mp_memcpy(e, body, sizeof(body)); END(); }
	{ ENTRY("decimal under fixext2"); char body[2] = { 0x01, 0x1c };
	  e = mp_encode_ext(e, MP_DECIMAL, body, sizeof(body)); END(); }
#undef ENTRY
#undef END
	return n;
}

static int
test_equivalence(void)
{
	struct json_corpus_entry corpus[32];
	int n = build_corpus(corpus);
	plan(n * 5);
	header();

	for (int i = 0; i < n; i++) {
		const char *in = corpus[i].data;
		uint32_t len = corpus[i].len;
		const char *what = corpus[i].what;
		char once[512];
		char twice[512];

		char *once_end = tnt_json_normalize(in, len, once,
						    once + sizeof(once), NULL);
		ok(once_end != NULL, "%s: normalizes", what);
		if (once_end == NULL)
			continue;
		uint32_t once_len = (uint32_t)(once_end - once);

		/*
		 * Idempotence, a prerequisite rather than a nice property:
		 * recovery and replication read back exactly what was written,
		 * so a non-idempotent normalizer breaks the inductive step.
		 */
		char *twice_end = tnt_json_normalize(once, once_len, twice,
						     twice + sizeof(twice),
						     NULL);
		ok(twice_end != NULL &&
		   twice_end - twice == (ptrdiff_t)once_len &&
		   memcmp(twice, once, once_len) == 0,
		   "%s: idempotent", what);

		/*
		 * The verifier and the rewriter are two views of one
		 * definition. A stricter verifier costs only performance, a
		 * looser one ships non-normalized bytes wearing the normalized
		 * label. Hence both directions.
		 */
		ok(json_is_normalized(once, once_len),
		   "%s: output verifies as normalized", what);

		/* Fast path and slow path produce identical bytes. */
		char slow[512];
		char *slow_end = json_normalize_rewrite(in, len, slow,
							slow + sizeof(slow));
		ok(slow_end != NULL &&
		   slow_end - slow == (ptrdiff_t)once_len &&
		   memcmp(slow, once, once_len) == 0,
		   "%s: fast path matches the rewriter", what);
		ok(once_len <= len, "%s: output is no larger than input", what);
	}

	footer();
	return check_plan();
}

/**
 * mp_verify_json() over a byte range: a tuple body, an operand array,
 * anything. The range walk only ever reports; nothing rewrites a range, so a
 * non-normalized value nested in one is a verdict and an offset, not a fix.
 */
static int
test_range(void)
{
	plan(10);
	header();

	char buf[4096];
	/* Sized for the 300-deep case below, which needs 301 bytes. */
	char inner[1024];

	/* An all-scalar array: no JSON, one branch per element, OK. */
	char *p = mp_encode_array(buf, 3);
	p = mp_encode_uint(p, 1);
	p = mp_encode_str0(p, "abc");
	p = mp_encode_bool(p, true);
	is(mp_verify_json(buf, p, NULL), JSON_NORM_OK, "no JSON is OK");

	/* A normalized MP_JSON at a nested, undescribed position. */
	char *ip = mp_encode_map(inner, 1);
	ip = mp_encode_str0(ip, "a");
	ip = mp_encode_uint(ip, 1);
	p = mp_encode_array(buf, 2);
	p = mp_encode_uint(p, 1);
	p = mp_encode_map(p, 1);
	p = mp_encode_str0(p, "k");
	/* Proof: built above from mp_encode_*() in ascending key order. */
	p = mp_encode_json(p, json_norm_from_trusted(inner,
						     (uint32_t)(ip - inner)));
	is(mp_verify_json(buf, p, NULL), JSON_NORM_OK,
	   "normalized JSON nested in a plain MAP is OK");

	/* The same with unsorted keys: REWRITABLE, and errpos points at it. */
	uint32_t errpos = 0;
	char bad[16];
	char *bp = mp_encode_map(bad, 2);
	bp = mp_encode_str0(bp, "b");
	bp = mp_encode_uint(bp, 1);
	bp = mp_encode_str0(bp, "a");
	bp = mp_encode_uint(bp, 2);
	char *jstart;
	p = mp_encode_array(buf, 2);
	p = mp_encode_uint(p, 1);
	p = mp_encode_map(p, 1);
	p = mp_encode_str0(p, "k");
	jstart = p;
	/*
	 * Badly spelled on purpose: the range walk has to find a bad payload
	 * nested inside a plain map. This wrap asserts nothing, it only builds
	 * the envelope the walk looks inside.
	 */
	p = mp_encode_json(p, json_norm_from_trusted(bad,
						     (uint32_t)(bp - bad)));
	is(mp_verify_json(buf, p, &errpos), JSON_NORM_REWRITABLE,
	   "unsorted keys nested in a plain MAP are REWRITABLE");
	is(errpos, (uint32_t)(jstart - buf),
	   "errpos points at the nested value, not at the tuple start");

	/*
	 * The two depth scopes. A plain array nested far past
	 * JSON_MAX_NESTING_DEPTH holds no JSON and must be accepted, because
	 * mp_check() accepts it today and this walk replaces mp_check().
	 * The same depth reached inside an MP_JSON payload must be rejected.
	 */
	p = buf;
	for (int i = 0; i < 300; i++)
		p = mp_encode_array(p, 1);
	p = mp_encode_uint(p, 1);
	is(mp_verify_json(buf, p, NULL), JSON_NORM_OK,
	   "300-deep plain array with no JSON is accepted");

	char *dp = inner;
	for (int i = 0; i < 300; i++)
		dp = mp_encode_array(dp, 1);
	dp = mp_encode_uint(dp, 1);
	/* Deliberately over-deep: the walk must reject it, not trust it. */
	p = mp_encode_json(buf, json_norm_from_trusted(inner,
						       (uint32_t)(dp - inner)));
	is(mp_verify_json(buf, p, NULL), JSON_NORM_INVALID,
	   "300-deep array inside an MP_JSON payload is rejected");

	/*
	 * An error's fields are walked too. The unsorted value from above goes
	 * into an MP_ERROR payload, which the default ext check takes as is.
	 */
	ip = mp_encode_map(inner, 1);
	ip = mp_encode_str0(ip, "k");
	jstart = ip;
	ip = mp_encode_json(ip, json_norm_from_trusted(bad,
						       (uint32_t)(bp - bad)));
	p = mp_encode_array(buf, 1);
	p = mp_encode_extl(p, MP_ERROR, (uint32_t)(ip - inner));
	uint32_t payload_off = (uint32_t)(p - buf);
	p = mp_memcpy(p, inner, (uint32_t)(ip - inner));
	errpos = 0;
	is(mp_verify_json(buf, p, &errpos), JSON_NORM_REWRITABLE,
	   "unsorted keys inside an MP_ERROR are REWRITABLE");
	is(errpos, payload_off + (uint32_t)(jstart - inner),
	   "errpos points at the value inside the error");

	/* A lone 0xc1, the never-used byte, as the JSON value's payload. */
	ip = mp_encode_map(inner, 1);
	ip = mp_encode_str0(ip, "k");
	jstart = ip;
	ip = mp_encode_extl(ip, MP_JSON, 1);
	*ip++ = (char)0xc1;
	p = mp_encode_array(buf, 1);
	p = mp_encode_extl(p, MP_ERROR, (uint32_t)(ip - inner));
	payload_off = (uint32_t)(p - buf);
	p = mp_memcpy(p, inner, (uint32_t)(ip - inner));
	errpos = 0;
	is(mp_verify_json(buf, p, &errpos), JSON_NORM_INVALID,
	   "malformed JSON inside an MP_ERROR is INVALID");
	is(errpos, payload_off + (uint32_t)(jstart - inner),
	   "errpos points at the value inside the error");

	footer();
	return check_plan();
}

/** One json_utf8_is_valid() case. */
struct utf8_case {
	const char *str;
	uint32_t len;
	bool valid;
	const char *what;
};

#define UTF8_CASE(s, valid, what) { s, sizeof(s) - 1, valid, what }

static const struct utf8_case utf8_cases[] = {
	UTF8_CASE("", true, "empty"),
	UTF8_CASE("abc", true, "short ASCII"),
	UTF8_CASE("abcdefghijklmnopq", true, "ASCII past a word"),
	UTF8_CASE("\0", true, "U+0000"),
	UTF8_CASE("\xc3\xa9", true, "2 bytes, U+00E9"),
	UTF8_CASE("\xe2\x82\xac", true, "3 bytes, U+20AC"),
	UTF8_CASE("\xf0\x9d\x84\x9e", true, "4 bytes, U+1D11E"),
	UTF8_CASE("\xed\x9f\xbf", true, "U+D7FF, just below surrogates"),
	UTF8_CASE("\xee\x80\x80", true, "U+E000, just above surrogates"),
	UTF8_CASE("\xf4\x8f\xbf\xbf", true, "U+10FFFF, the last code point"),
	UTF8_CASE("abcdefghi\xc3\xa9z", true, "multibyte after a word"),
	UTF8_CASE("\xff", false, "0xff"),
	UTF8_CASE("\x80", false, "lone continuation byte"),
	UTF8_CASE("\xc0\x80", false, "overlong 2 bytes (0xc0)"),
	UTF8_CASE("\xc1\xbf", false, "overlong 2 bytes (0xc1)"),
	UTF8_CASE("\xe0\x80\x80", false, "overlong 3 bytes"),
	UTF8_CASE("\xf0\x80\x80\x80", false, "overlong 4 bytes"),
	UTF8_CASE("\xed\xa0\x80", false, "surrogate U+D800"),
	UTF8_CASE("\xed\xbf\xbf", false, "surrogate U+DFFF"),
	UTF8_CASE("\xf4\x90\x80\x80", false, "U+110000"),
	UTF8_CASE("\xf5\x80\x80\x80", false, "lead byte 0xf5"),
	UTF8_CASE("\xc3", false, "2 bytes cut short"),
	UTF8_CASE("\xe2\x82", false, "3 bytes cut short"),
	UTF8_CASE("\xf0\x9d\x84", false, "4 bytes cut short"),
	UTF8_CASE("\xc3\x41", false, "ASCII in place of a continuation"),
	UTF8_CASE("\xe2\x82\x41", false, "bad last continuation"),
	UTF8_CASE("abcdefgh\xff", false, "0xff after a word"),
	UTF8_CASE("abcdefg\xc3", false, "cut short at the very end"),
};

/**
 * Strings and keys must be valid UTF-8, since RFC 8259 requires JSON text
 * to be. Refused as invalid, not rewritable: there is nothing to rewrite.
 */
static int
test_verify_utf8(void)
{
	plan(lengthof(utf8_cases) + 6);
	header();

	for (unsigned i = 0; i < lengthof(utf8_cases); i++) {
		const struct utf8_case *c = &utf8_cases[i];
		is(json_utf8_is_valid(c->str, c->len), c->valid, "%s: %s",
		   c->valid ? "valid" : "invalid", c->what);
	}

	char s[64];
	char *e;
	e = mp_encode_str(s, "\xc3\xa9", 2);
	check_norm(s, e - s, "valid UTF-8 string");
	e = mp_encode_str(s, "\xff", 1);
	check_invalid(s, e - s, "0xff in a string");

	e = mp_encode_map(s, 1);
	e = mp_encode_str(e, "\xff", 1);
	e = mp_encode_uint(e, 1);
	check_invalid(s, e - s, "0xff in a key");

	e = mp_encode_array(s, 2);
	e = mp_encode_str0(e, "a");
	e = mp_encode_str(e, "\xed\xa0\x80", 3);
	check_invalid(s, e - s, "surrogate in a nested string");

	/* Unsorted keys would be rewritable, but a bad key outranks that. */
	e = mp_encode_map(s, 2);
	e = mp_encode_str0(e, "b");
	e = mp_encode_uint(e, 1);
	e = mp_encode_str(e, "\xc3", 1);
	e = mp_encode_uint(e, 2);
	check_invalid(s, e - s, "cut short key in an unsorted map");

	footer();
	return check_plan();
}

int
main(void)
{
	plan(12);
	test_codec();
	test_normalize();
	test_compare();
	test_compare_numbers();
	test_render();
	test_verify_scalars();
	test_verify_containers();
	test_verify_malformed();
	test_rewrite();
	test_equivalence();
	test_range();
	test_verify_utf8();
	return check_plan();
}
