#include "box/sql/json_parse.h"
#include "box/errcode.h"

#include "decimal.h"
#include "diag.h"
#include "fiber.h"
#include "memory.h"
#include "mp_decimal.h"
#include "mp_extension_types.h"
#include "msgpuck.h"
#include "trivia/util.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

/*
 * tnt_json_parse() returns the normalized inner MessagePack value (no
 * MP_EXT/MP_JSON envelope) on the fiber region, or NULL with a diag set. Every
 * helper below re-parses from source text and inspects that plain MessagePack.
 */

static bool
parse_uint(const char *text, uint64_t val)
{
	uint32_t len;
	const char *mp = tnt_json_parse(text, strlen(text), &len);
	if (mp == NULL || mp_typeof(*mp) != MP_UINT)
		return false;
	return mp_decode_uint(&mp) == val;
}

static bool
parse_int(const char *text, int64_t val)
{
	uint32_t len;
	const char *mp = tnt_json_parse(text, strlen(text), &len);
	if (mp == NULL || mp_typeof(*mp) != MP_INT)
		return false;
	return mp_decode_int(&mp) == val;
}

static bool
parse_double(const char *text, double val)
{
	uint32_t len;
	const char *mp = tnt_json_parse(text, strlen(text), &len);
	if (mp == NULL || mp_typeof(*mp) != MP_DOUBLE)
		return false;
	return mp_decode_double(&mp) == val;
}

static bool
decimal_at(const char *mp, const char *dec_str)
{
	if (mp == NULL || mp_typeof(*mp) != MP_EXT)
		return false;
	const char *p = mp;
	int8_t type;
	mp_decode_extl(&p, &type);
	if (type != MP_DECIMAL)
		return false;
	decimal_t got;
	p = mp;
	if (mp_decode_decimal(&p, &got) == NULL)
		return false;
	decimal_t exp;
	if (decimal_from_string(&exp, dec_str) == NULL)
		return false;
	return decimal_compare(&got, &exp) == 0;
}

static bool
parse_decimal(const char *text, const char *dec_str)
{
	uint32_t len;
	return decimal_at(tnt_json_parse(text, strlen(text), &len), dec_str);
}

/*
 * The first element of an array. A nested literal is followed by a delimiter
 * instead of by the terminator, so the decimal is built from the token span
 * alone.
 */
static bool
parse_array_decimal(const char *text, const char *dec_str)
{
	uint32_t len;
	const char *mp = tnt_json_parse(text, strlen(text), &len);
	if (mp == NULL || mp_typeof(*mp) != MP_ARRAY)
		return false;
	mp_decode_array(&mp);
	return decimal_at(mp, dec_str);
}

static bool
parse_len_fails(const char *text, uint32_t text_len, int code)
{
	uint32_t len;
	const char *mp = tnt_json_parse(text, text_len, &len);
	if (mp != NULL)
		return false;
	struct error *e = diag_last_error(diag_get());
	return e != NULL && e->code == code;
}

static bool
parse_fails(const char *text, int code)
{
	return parse_len_fails(text, strlen(text), code);
}

static int
test_scalars(void)
{
	plan(6);
	header();

	uint32_t len;
	const char *mp;

	mp = tnt_json_parse("null", 4, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_NIL, "null -> MP_NIL");

	mp = tnt_json_parse("true", 4, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_BOOL && mp_decode_bool(&mp),
	   "true -> MP_BOOL true");

	mp = tnt_json_parse("false", 5, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_BOOL && !mp_decode_bool(&mp),
	   "false -> MP_BOOL false");

	bool str_ok = false;
	mp = tnt_json_parse("\"hi\"", 4, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_STR) {
		uint32_t slen;
		const char *s = mp_decode_str(&mp, &slen);
		str_ok = slen == 2 && memcmp(s, "hi", 2) == 0;
	}
	ok(str_ok, "\"hi\" -> MP_STR hi");

	bool empty_ok = false;
	mp = tnt_json_parse("\"\"", 2, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_STR) {
		uint32_t slen;
		mp_decode_str(&mp, &slen);
		empty_ok = slen == 0;
	}
	ok(empty_ok, "\"\" -> empty MP_STR");

	/*
	 * A backslash routes the token through the strbuf unescape path
	 * (json_parse.h's lex.tmp), unlike every other test_scalars() string
	 * above, which is escape-free and so borrowed straight from the
	 * input. Mixes a two-character escape with a \\uXXXX one.
	 */
	bool escape_ok = false;
	mp = tnt_json_parse("\"a\\nb\\u0041\"", 12, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_STR) {
		uint32_t slen;
		const char *s = mp_decode_str(&mp, &slen);
		escape_ok = slen == 4 && memcmp(s, "a\nbA", 4) == 0;
	}
	ok(escape_ok, "escaped string with \\n and \\u0041 decodes");

	footer();
	return check_plan();
}

static int
test_numbers(void)
{
	plan(19);
	header();

	/* A dotless integer maps by sign: >= 0 to MP_UINT, < 0 to MP_INT. */
	ok(parse_uint("0", 0), "0 -> MP_UINT 0");
	ok(parse_uint("42", 42), "42 -> MP_UINT 42");
	ok(parse_int("-42", -42), "-42 -> MP_INT -42");
	ok(parse_uint("9223372036854775807", 9223372036854775807ULL),
	   "int64_max -> MP_UINT");
	ok(parse_uint("9223372036854775808", 9223372036854775808ULL),
	   "int64_max + 1 -> MP_UINT");
	ok(parse_uint("18446744073709551615", 18446744073709551615ULL),
	   "uint64_max -> MP_UINT");

	/*
	 * A fraction with no exponent is a decimal; an exponent forces
	 * double.
	 */
	ok(parse_decimal("12.5", "12.5"), "12.5 -> MP_DECIMAL");
	ok(parse_decimal("0.0", "0.0"), "0.0 -> MP_DECIMAL");
	ok(parse_double("1.5e3", 1500.0), "1.5e3 -> MP_DOUBLE");
	ok(parse_double("1e3", 1000.0), "1e3 -> MP_DOUBLE");

	/* Each delimiter that can end a decimal literal in place. */
	ok(parse_array_decimal("[12.5]", "12.5"),
	   "12.5 before ']' -> MP_DECIMAL");
	ok(parse_array_decimal("[12.5,1]", "12.5"),
	   "12.5 before ',' -> MP_DECIMAL");
	ok(parse_array_decimal("[12.5 ,1]", "12.5"),
	   "12.5 before a space -> MP_DECIMAL");

	char digits38[41];
	digits38[0] = '0';
	digits38[1] = '.';
	for (int i = 0; i < 38; i++)
		digits38[2 + i] = '9';
	digits38[40] = '\0';
	ok(parse_decimal(digits38, digits38), "38 significant digits accepted");

	/*
	 * The text constructor does not shrink. Any number literal with an
	 * exponent becomes an MP_DOUBLE, so three bytes of text produce a
	 * nine-byte inner value. This is why json_parse and tnt_json_normalize
	 * are separate names with separate contracts.
	 */
	uint32_t len;
	const char *mp = tnt_json_parse("1e1", 3, &len);
	isnt(mp, NULL, "1e1 parses");
	is(len, 9, "1e1 is a nine-byte MP_DOUBLE from three bytes of text");
	is(mp_typeof(*mp), MP_DOUBLE, "1e1 is a double, not an integer");
	/* No exponent, so the same value arrives as MP_DECIMAL instead. */
	mp = tnt_json_parse("0.1", 3, &len);
	isnt(mp, NULL, "0.1 parses");
	is(mp_typeof(*mp), MP_EXT, "0.1 is a decimal");

	footer();
	return check_plan();
}

static int
test_containers(void)
{
	plan(8);
	header();

	uint32_t len;
	const char *mp;
	const char *p;

	mp = tnt_json_parse("[]", 2, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_ARRAY &&
	   (p = mp, mp_decode_array(&p) == 0), "[] -> empty MP_ARRAY");

	bool arr_ok = false;
	mp = tnt_json_parse("[1,2,3]", 7, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_ARRAY) {
		p = mp;
		if (mp_decode_array(&p) == 3)
			arr_ok = mp_decode_uint(&p) == 1 &&
				 mp_decode_uint(&p) == 2 &&
				 mp_decode_uint(&p) == 3;
	}
	ok(arr_ok, "[1,2,3] -> MP_ARRAY of 1,2,3");

	mp = tnt_json_parse("{}", 2, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_MAP && (p = mp, mp_decode_map(&p) == 0),
	   "{} -> empty MP_MAP");

	mp = tnt_json_parse("{\"a\":1,\"b\":2}", 13, &len);
	ok(mp != NULL && mp_typeof(*mp) == MP_MAP && (p = mp, mp_decode_map(&p) == 2),
	   "{a,b} -> MP_MAP of 2");

	bool sorted_ok = false;
	mp = tnt_json_parse("{\"b\":2,\"a\":1}", 13, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_MAP) {
		p = mp;
		if (mp_decode_map(&p) == 2) {
			uint32_t klen;
			const char *k = mp_decode_str(&p, &klen);
			sorted_ok = klen == 1 && k[0] == 'a' &&
				    mp_decode_uint(&p) == 1;
		}
	}
	ok(sorted_ok, "{b,a} keys sorted, first pair a:1");

	bool dedup_size_ok = false;
	bool dedup_val_ok = false;
	mp = tnt_json_parse("{\"a\":1,\"a\":2}", 13, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_MAP) {
		p = mp;
		if (mp_decode_map(&p) == 1) {
			dedup_size_ok = true;
			uint32_t klen;
			mp_decode_str(&p, &klen);
			dedup_val_ok = mp_decode_uint(&p) == 2;
		}
	}
	ok(dedup_size_ok, "{a:1,a:2} deduplicates to one pair");
	ok(dedup_val_ok, "{a:1,a:2} keeps the last value (2)");

	bool nested_ok = false;
	mp = tnt_json_parse("[{\"a\":[1]}]", 11, &len);
	if (mp != NULL && mp_typeof(*mp) == MP_ARRAY) {
		p = mp;
		nested_ok = mp_decode_array(&p) == 1 && mp_typeof(*p) == MP_MAP;
	}
	ok(nested_ok, "[{a:[1]}] -> nested array/map");

	footer();
	return check_plan();
}

static int
test_nesting(void)
{
	plan(4);
	header();

	/*
	 * The depth bound matches tnt_json_normalize(): a value at depth
	 * JSON_MAX_NESTING_DEPTH (100) is rejected. n opening brackets nest the
	 * innermost value at depth n - 1, so 100 brackets are accepted and 101
	 * are rejected.
	 */
	char deep[256];
	uint32_t len;
	const char *mp;

	for (int i = 0; i < 100; i++) {
		deep[i] = '[';
		deep[100 + i] = ']';
	}
	mp = tnt_json_parse(deep, 200, &len);
	ok(mp != NULL, "100 levels: accepted");
	ok(mp != NULL && mp_typeof(*mp) == MP_ARRAY, "100 levels: MP_ARRAY");

	for (int i = 0; i < 101; i++) {
		deep[i] = '[';
		deep[101 + i] = ']';
	}
	/*
	 * deep is not NUL-terminated: only bytes [0, 202) are written, so
	 * parse_fails()'s strlen() would walk uninitialized stack past that.
	 * Pass the length explicitly, as the 100-level case above does.
	 */
	ok(parse_len_fails(deep, 202, ER_JSON_PARSE),
	   "101 levels: ER_JSON_PARSE");
	struct error *e = diag_last_error(diag_get());
	ok(e != NULL && strstr(e->errmsg, "nested") != NULL,
	   "101 levels: message mentions nesting");

	footer();
	return check_plan();
}

/*
 * Parse from a buffer sized exactly to the text, so there is no readable byte
 * at [len] and an overread is a real fault under ASAN. The result must match
 * the same text parsed from a NUL-terminated literal byte for byte, which
 * catches an endptr mapped back wrongly from a terminated copy.
 */
static bool
parse_matches_unterminated(const char *text)
{
	size_t n = strlen(text);

	uint32_t want_len;
	const char *want = tnt_json_parse(text, n, &want_len);
	char *want_copy = NULL;
	if (want != NULL) {
		want_copy = xmalloc(want_len);
		memcpy(want_copy, want, want_len);
	} else {
		diag_clear(diag_get());
	}

	char *buf = xmalloc(n != 0 ? n : 1);
	memcpy(buf, text, n);
	uint32_t got_len;
	const char *got = tnt_json_parse(buf, n, &got_len);
	if (got == NULL)
		diag_clear(diag_get());

	bool rc;
	if (want_copy == NULL) {
		rc = got == NULL;
	} else {
		rc = got != NULL && got_len == want_len &&
		     memcmp(got, want_copy, want_len) == 0;
	}
	free(buf);
	free(want_copy);
	return rc;
}

/*
 * The lexer reads the caller's bytes in place, so nothing may be read at or
 * past [len]. Every case below is the whole input, chosen so that the token
 * needing a terminator is the one sitting at the end of the buffer.
 */
static int
test_unterminated(void)
{
	static const char *const cases[] = {
		/* A complete value whose last token ends at the final byte. */
		"123", "0", "-1", "1.5", "12.5", "1e3", "1.5e3", "true",
		"false", "null", "\"abc\"", "[1,2,3]", "{\"a\":1}", "[1.5]",
		/* Literals that overflow, at the end of the buffer. */
		"18446744073709551616", "-9223372036854775809", "1e400",
		/*
		 * A numeric run that outlives its own token: the lexer stops
		 * at "1", but a re-read with strtodec() keeps going through
		 * the exponent bytes and off the end unless it is terminated.
		 */
		"1e", "1e+", "1e-", "1.5e", "1.5e+",
		/* A truncated token: the scan stops at the end, not past it. */
		"", "tru", "nul", "fals", "-", "1.", "[1,2", "{\"a\":1",
		"{\"a\":", "\"abc", "\"\\", "\"\\u00", "\"\\ud834",
		"\"\\ud834\\u",
	};

	/* A literal too long for any fixed buffer, ending at the final byte. */
	char long_num[256];
	long_num[0] = '1';
	long_num[1] = '.';
	memset(long_num + 2, '0', 200);
	long_num[202] = '1';
	long_num[203] = '\0';

	plan(lengthof(cases) + 1);
	header();

	for (unsigned i = 0; i < lengthof(cases); i++) {
		ok(parse_matches_unterminated(cases[i]),
		   "unterminated '%s' matches terminated", cases[i]);
	}
	ok(parse_matches_unterminated(long_num),
	   "unterminated 203-char literal matches terminated");

	footer();
	return check_plan();
}

/**
 * Text that is not UTF-8 is refused in keys and values alike. An escape
 * always decodes to valid UTF-8, so only raw bytes can be wrong.
 */
static int
test_utf8(void)
{
	plan(9);
	header();

	uint32_t len;
	const char *mp = tnt_json_parse("\"\xc3\xa9\"", 4, &len);
	ok(mp != NULL && len == 3 && memcmp(mp, "\xa2\xc3\xa9", 3) == 0,
	   "raw U+00E9 parses");
	mp = tnt_json_parse("\"\\u00e9\"", 8, &len);
	ok(mp != NULL && len == 3 && memcmp(mp, "\xa2\xc3\xa9", 3) == 0,
	   "escaped U+00E9 parses to the same bytes");
	static const char key4[] = "{\"\xf0\x9d\x84\x9e\":1}";
	mp = tnt_json_parse(key4, sizeof(key4) - 1, &len);
	ok(mp != NULL, "4-byte key parses");

	ok(parse_fails("\"\xff\"", ER_JSON_PARSE), "0xff -> ER_JSON_PARSE");
	ok(parse_fails("{\"\xff\":1}", ER_JSON_PARSE),
	   "0xff in a key -> ER_JSON_PARSE");
	ok(parse_fails("[\"a\", \"\xc3\"]", ER_JSON_PARSE),
	   "cut short in a nested string -> ER_JSON_PARSE");
	ok(parse_fails("\"\xc0\x80\"", ER_JSON_PARSE),
	   "overlong -> ER_JSON_PARSE");
	ok(parse_fails("\"\xed\xa0\x80\"", ER_JSON_PARSE),
	   "raw surrogate -> ER_JSON_PARSE");
	ok(parse_fails("\"a\\n\xf4\x90\x80\x80\"", ER_JSON_PARSE),
	   "above U+10FFFF next to an escape -> ER_JSON_PARSE");

	footer();
	return check_plan();
}

static int
test_errors(void)
{
	plan(13);
	header();

	ok(parse_fails("hello", ER_JSON_PARSE), "bare word -> ER_JSON_PARSE");
	ok(parse_fails("", ER_JSON_PARSE), "empty input -> ER_JSON_PARSE");
	ok(parse_fails("1 2", ER_JSON_PARSE),
	   "trailing content -> ER_JSON_PARSE");
	ok(parse_fails("[1,2,", ER_JSON_PARSE),
	   "unterminated array -> ER_JSON_PARSE");
	ok(parse_fails("{\"a\":}", ER_JSON_PARSE),
	   "missing object value -> ER_JSON_PARSE");

	ok(parse_fails("18446744073709551616", ER_INT_LITERAL_MAX),
	   "above uint64_max -> ER_INT_LITERAL_MAX");
	ok(parse_fails("-9223372036854775809", ER_INT_LITERAL_MAX),
	   "below int64_min -> ER_INT_LITERAL_MAX");

	ok(parse_fails("100000000000000000000000000000000000000000000000000.0",
		       ER_INVALID_DEC),
	   "over-range decimal -> ER_INVALID_DEC");

	char digits39[42];
	digits39[0] = '0';
	digits39[1] = '.';
	for (int i = 0; i < 39; i++)
		digits39[2 + i] = '9';
	digits39[41] = '\0';
	ok(parse_fails(digits39, ER_INVALID_DEC),
	   "39 significant digits -> ER_INVALID_DEC");

	ok(parse_fails("1e400", ER_JSON_PARSE), "1e400 (Inf) -> ER_JSON_PARSE");

	/*
	 * A zero byte reads as the end of the text inside the lexer, so a
	 * document that stops at one is truncated rather than complete. The
	 * caller passes a length, and SQL strings may carry a NUL.
	 */
	static const char nul_tail[] = "1\0garbage";
	ok(parse_len_fails(nul_tail, sizeof(nul_tail) - 1, ER_JSON_PARSE),
	   "garbage after a zero byte -> ER_JSON_PARSE");
	static const char nul_brace[] = "{\"a\":1}\0 {";
	ok(parse_len_fails(nul_brace, sizeof(nul_brace) - 1, ER_JSON_PARSE),
	   "object then a zero byte -> ER_JSON_PARSE");
	static const char nul_only[] = "1\0";
	ok(parse_len_fails(nul_only, sizeof(nul_only) - 1, ER_JSON_PARSE),
	   "value then a bare zero byte -> ER_JSON_PARSE");

	footer();
	return check_plan();
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);

	plan(7);
	header();
	test_scalars();
	test_numbers();
	test_containers();
	test_nesting();
	test_errors();
	test_unterminated();
	test_utf8();
	int rc = check_plan();
	footer();

	fiber_free();
	memory_free();
	return rc;
}
