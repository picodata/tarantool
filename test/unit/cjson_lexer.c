#define UNIT_TAP_COMPATIBLE 1

#include "lua-cjson/cjson_lexer.h"
#include "memory.h"
#include "fiber.h"
#include "cord_buf.h"
#include "trivia/util.h"
#include "unit.h"

#include <stdlib.h>
#include <string.h>

/*
 * A string token that had to be decoded points into the lexer's temporary
 * buffer, so the buffer has to outlive every assertion made about the token.
 * Keep one for the whole run rather than one per call: 256 bytes is more than
 * the longest text here, which is what the lexer asks of it (cjson_lexer.h).
 */
static struct ibuf *lexer_ibuf;
static strbuf_t lexer_tmp;

static void
lexer_env_create(void)
{
	lexer_ibuf = cord_ibuf_take();
	strbuf_create(&lexer_tmp, 256, lexer_ibuf);
}

static void
lexer_env_destroy(void)
{
	strbuf_destroy(&lexer_tmp);
	cord_ibuf_put(lexer_ibuf);
}

/* One-shot helper: tokenize the first token of a length-bounded buffer. */
static void
first_token_n(const char *str, size_t len, bool allow_invalid,
	      json_token_t *out)
{
	json_parse_t json;
	json.ptr = str;
	json.end = str + len;
	json.tmp = &lexer_tmp;
	json.decode_invalid_numbers = allow_invalid;
	json.reject_control_chars = false;
	json.line_count = 1;
	json.cur_line_ptr = str;

	/*
	 * Callers reuse one token across calls, so poison it first: a field the
	 * lexer forgets to fill must not read back as the previous token's.
	 */
	memset(out, 0xa5, sizeof(*out));
	json_next_token(&json, out);
}

/* The same, under the strict grammar (reject_control_chars set). */
static void
first_token_strict(const char *str, size_t len, json_token_t *out)
{
	json_parse_t json;
	json.ptr = str;
	json.end = str + len;
	json.tmp = &lexer_tmp;
	json.decode_invalid_numbers = false;
	json.reject_control_chars = true;
	json.line_count = 1;
	json.cur_line_ptr = str;

	memset(out, 0xa5, sizeof(*out));
	json_next_token(&json, out);
}

static void
first_token(const char *str, bool allow_invalid, json_token_t *out)
{
	first_token_n(str, strlen(str), allow_invalid, out);
}

static void
test_scalars(void)
{
	plan(6);
	header();

	json_token_t t;
	first_token("null", false, &t);
	is(t.type, JSON_T_NULL, "null");
	first_token("true", false, &t);
	is(t.type, JSON_T_BOOLEAN, "true type");
	is(t.value.boolean, 1, "true value");
	first_token("false", false, &t);
	is(t.value.boolean, 0, "false value");
	first_token("{", false, &t);
	is(t.type, JSON_T_OBJ_BEGIN, "object begin");
	first_token("[", false, &t);
	is(t.type, JSON_T_ARR_BEGIN, "array begin");

	check_plan();
	footer();
}

static void
test_numbers(void)
{
	plan(15);
	header();

	json_token_t t;

	first_token("0", false, &t);
	is(t.type, JSON_T_INT, "0 is int");
	is(t.value.ival, 0, "0 value");

	first_token("-1", false, &t);
	is(t.type, JSON_T_INT, "-1 is int");
	is(t.value.ival, -1, "-1 value");

	/*
	 * int64_max is reported as uint: the value fits int64, but the lexer
	 * has always probed for overflow against LLONG_MAX and json.decode
	 * hands that one literal out as a uint64 cdata.
	 */
	first_token("9223372036854775807", false, &t);
	is(t.type, JSON_T_UINT, "int64_max is uint");

	/* int64_max + 1 fits uint64. */
	first_token("9223372036854775808", false, &t);
	is(t.type, JSON_T_UINT, "int64_max+1 is uint");
	ok(!t.num_overflow, "int64_max+1 no overflow");

	/* uint64_max fits. */
	first_token("18446744073709551615", false, &t);
	is(t.type, JSON_T_UINT, "uint64_max is uint");

	/* uint64_max + 1 overflows. */
	first_token("18446744073709551616", false, &t);
	ok(t.num_overflow, "uint64_max+1 overflows");

	/* below int64_min overflows. */
	first_token("-9223372036854775809", false, &t);
	ok(t.num_overflow, "below int64_min overflows");

	first_token("12.5", false, &t);
	is(t.type, JSON_T_DECIMAL, "12.5 is decimal");
	is(t.num_len, 4, "12.5 length");

	first_token("1e3", false, &t);
	is(t.type, JSON_T_DOUBLE, "1e3 is double");
	is(t.num_len, 3, "1e3 length");

	/* Exponent wins over the fraction. */
	first_token("1.5e3", false, &t);
	is(t.type, JSON_T_DOUBLE, "1.5e3 is double");

	check_plan();
	footer();
}

/*
 * A JSON_T_STRING is only as long as string_len says: an escape-free one
 * points straight into the input, with no terminator of its own.
 */
static bool
token_str_eq(const json_token_t *t, const char *want)
{
	return t->type == JSON_T_STRING &&
	       (size_t)t->string_len == strlen(want) &&
	       memcmp(t->value.string, want, t->string_len) == 0;
}

static void
test_strings(void)
{
	plan(7);
	header();

	json_token_t t;
	const char *plain = "\"abc\"";
	first_token(plain, false, &t);
	is(t.type, JSON_T_STRING, "plain string type");
	ok(token_str_eq(&t, "abc"), "plain string value");
	/* No escape to decode, so the token borrows the input. */
	ok(t.value.string == plain + 1, "plain string points into the input");

	first_token("\"a\\nb\"", false, &t);
	ok(token_str_eq(&t, "a\nb"), "escape decoded");

	/* Surrogate pair for U+1F600 (four UTF-8 bytes). */
	first_token("\"\\uD83D\\uDE00\"", false, &t);
	ok(token_str_eq(&t, "\xF0\x9F\x98\x80"), "surrogate pair decoded");

	/* The run before the first escape is carried over into the decoding. */
	first_token("\"abc\\ndef\"", false, &t);
	ok(token_str_eq(&t, "abc\ndef"), "escape after a plain run");

	first_token("\"\"", false, &t);
	ok(token_str_eq(&t, ""), "empty string");

	check_plan();
	footer();
}

/*
 * RFC 8259 lets a string carry only %x20 and above unescaped, but this lexer
 * has always taken a raw control character as an ordinary byte, so a consumer
 * promising the strict grammar sets reject_control_chars. Both readings are
 * pinned here: the flag must change nothing outside a raw control character.
 */
static void
test_control_chars_in_strings(void)
{
	plan(11);
	header();

	json_token_t t;
	/* "a<LF>b": accepted by default, refused under the strict grammar. */
	const char *raw_lf = "\"a\nb\"";
	first_token(raw_lf, false, &t);
	ok(token_str_eq(&t, "a\nb"), "raw LF accepted by default");
	first_token_strict(raw_lf, strlen(raw_lf), &t);
	is(t.type, JSON_T_ERROR, "raw LF rejected under strict");
	is(strcmp(t.value.string, "control character in string"), 0,
	   "raw LF message");
	is(t.start, raw_lf + 2, "raw LF reported at the offending byte");

	/* Every byte below 0x20 goes, up to the boundary. */
	const char *raw_tab = "\"a\tb\"";
	first_token_strict(raw_tab, strlen(raw_tab), &t);
	is(t.type, JSON_T_ERROR, "raw TAB rejected under strict");
	const char *raw_us = "\"\x1f\"";
	first_token_strict(raw_us, strlen(raw_us), &t);
	is(t.type, JSON_T_ERROR, "raw U+001F rejected under strict");
	/*
	 * 0x20 is the first legal one, and 0x7f (DEL) is not a control
	 * character as far as JSON is concerned.
	 */
	first_token_strict("\" \"", 3, &t);
	ok(token_str_eq(&t, " "), "space accepted under strict");
	first_token_strict("\"\x7f\"", 3, &t);
	ok(token_str_eq(&t, "\x7f"), "DEL accepted under strict");

	/* An escape may still produce one; strict only bans the raw byte. */
	first_token_strict("\"a\\nb\"", 6, &t);
	ok(token_str_eq(&t, "a\nb"), "escaped LF accepted under strict");
	/*
	 * The decoding loop is a separate scan from the escape-free one, so a
	 * raw control character has to be caught there too. This text reaches
	 * it by carrying an escape first.
	 */
	const char *after_escape = "\"\\n\nb\"";
	first_token_strict(after_escape, strlen(after_escape), &t);
	is(t.type, JSON_T_ERROR, "raw LF after an escape rejected");

	/* NUL keeps its own message: it ends the scan whatever the flag. */
	first_token_strict("\"a\0b\"", 5, &t);
	is(strcmp(t.value.string, "unexpected end of string"), 0,
	   "embedded NUL still ends the string");

	check_plan();
	footer();
}

static void
test_invalid_numbers(void)
{
	plan(13);
	header();

	json_token_t t;
	first_token("01", false, &t);
	is(t.type, JSON_T_ERROR, "leading zero rejected");
	first_token("+1", false, &t);
	is(t.type, JSON_T_ERROR, "leading plus rejected");
	first_token(".5", false, &t);
	is(t.type, JSON_T_ERROR, "leading dot rejected");

	/*
	 * strtod() accepts a trailing decimal point, JSON does not. These are
	 * the forms json_is_invalid_number()'s prefix screen lets through.
	 * decode_invalid_numbers admits the inf/nan words rather than a laxer
	 * grammar, so it makes no difference here.
	 */
	first_token("1.", false, &t);
	is(t.type, JSON_T_ERROR, "trailing dot rejected");
	/*
	 * The number lexer flags a run reaching the end of the input before it
	 * knows the literal is one it accepts, and these run to the end. A
	 * token rejected afterwards is not a number, so it must not keep it.
	 */
	ok(!t.num_at_end, "trailing dot clears num_at_end");
	first_token("1.", true, &t);
	is(t.type, JSON_T_ERROR, "trailing dot rejected with invalid numbers");
	first_token("1.e5", false, &t);
	is(t.type, JSON_T_ERROR, "trailing dot before exponent rejected");
	ok(!t.num_at_end, "trailing dot before exponent clears num_at_end");
	first_token("1.E5", false, &t);
	is(t.type, JSON_T_ERROR, "trailing dot before capital E rejected");

	/*
	 * A bare exponent has no digits, so the conversion backs off to the
	 * integer part, which is a strict number. The token stays an int and
	 * the leftover 'e' fails as a token of its own.
	 */
	first_token("1e", false, &t);
	is(t.type, JSON_T_INT, "bare exponent stops at the integer part");
	is(t.value.ival, 1, "bare exponent keeps the integer value");
	first_token("1e+", false, &t);
	is(t.type, JSON_T_INT, "signed bare exponent stops there too");

	/* Without decode_invalid_numbers, inf is not a number. */
	first_token("inf", false, &t);
	is(t.type, JSON_T_ERROR, "inf rejected by default");

	check_plan();
	footer();
}

static void
test_invalid_numbers_allowed(void)
{
	plan(11);
	header();

	json_token_t t;
	first_token("inf", true, &t);
	is(t.type, JSON_T_DOUBLE, "inf allowed as double");
	is(t.num_len, 3, "inf length");
	/* Not an integer literal, so the overflow flag stays clear. */
	ok(!t.num_overflow, "inf does not report an overflow");
	first_token("-inf", true, &t);
	is(t.type, JSON_T_DOUBLE, "-inf allowed as double");
	is(t.num_len, 4, "-inf length");
	first_token("nan", true, &t);
	is(t.type, JSON_T_DOUBLE, "nan allowed as double");
	is(t.num_len, 3, "nan length");
	first_token("-nan", true, &t);
	is(t.type, JSON_T_DOUBLE, "-nan allowed as double");
	is(t.num_len, 4, "-nan length");

	/*
	 * A word matched on its full length: a truncated tail is an error
	 * rather than a NaN whose token would run past the end of the buffer.
	 */
	first_token("-na", true, &t);
	is(t.type, JSON_T_ERROR, "-na rejected as truncated");
	first_token("na", true, &t);
	is(t.type, JSON_T_ERROR, "na rejected as truncated");

	check_plan();
	footer();
}

/*
 * Every case above hands the lexer a C literal, whose NUL sentinel is there
 * whether or not the lexer stops at json.end. Copy the text into a buffer
 * sized exactly to it, so a read past the end is an out-of-bounds one rather
 * than a byte that merely happened to be a NUL.
 */
static void
test_no_sentinel(void)
{
	plan(9);
	header();

	json_token_t t;
	char *buf;
	size_t len;

	/* A keyword is compared on its full length, never past the end. */
	len = 3;
	buf = memcpy(xmalloc(len), "tru", len);
	first_token_n(buf, len, false, &t);
	is(t.type, JSON_T_ERROR, "truncated keyword rejected");
	free(buf);

	/* A string looks for its closing quote inside the buffer only. */
	len = 4;
	buf = memcpy(xmalloc(len), "\"abc", len);
	first_token_n(buf, len, false, &t);
	is(t.type, JSON_T_ERROR, "unterminated string rejected");
	free(buf);

	/* Same for the four hex digits of an escape. */
	len = 7;
	buf = memcpy(xmalloc(len), "\"ab\\u12", len);
	first_token_n(buf, len, false, &t);
	is(t.type, JSON_T_ERROR, "truncated unicode escape rejected");
	free(buf);

	/*
	 * A literal running to the last byte has nothing to stop the
	 * conversion, so the lexer converts it from a terminated copy.
	 */
	len = 5;
	buf = memcpy(xmalloc(len), "12345", len);
	first_token_n(buf, len, false, &t);
	is(t.type, JSON_T_INT, "number at the end is int");
	is(t.value.ival, 12345, "number at the end value");
	is(t.num_len, 5, "number at the end length");
	ok(t.num_at_end, "number at the end is flagged");
	free(buf);

	/*
	 * An escape-free string is never copied out, so its token points into
	 * the very buffer it was lexed from, NUL or no NUL.
	 */
	len = 5;
	buf = memcpy(xmalloc(len), "\"abc\"", len);
	first_token_n(buf, len, false, &t);
	ok(token_str_eq(&t, "abc"), "borrowed string value");
	ok(t.value.string == buf + 1, "borrowed string points into the buffer");
	free(buf);

	check_plan();
	footer();
}

/*
 * first_token reads only one token, so drive the lexer across the stream
 * until it fails, and report the column the error token starts at.
 */
static int
error_column(const char *str)
{
	json_parse_t json;
	json.ptr = str;
	json.end = str + strlen(str);
	json.tmp = &lexer_tmp;
	json.decode_invalid_numbers = false;
	json.reject_control_chars = false;
	json.line_count = 1;
	json.cur_line_ptr = str;

	json_token_t t;
	do {
		json_next_token(&json, &t);
	} while (t.type != JSON_T_ERROR && t.type != JSON_T_END);

	if (t.type != JSON_T_ERROR)
		return -1;

	return (int)(t.start - json.cur_line_ptr);
}

static void
test_error_position(void)
{
	plan(2);
	header();

	/* The invalid '@' is at column index 3 (0-based). */
	is(error_column("[1,@]"), 3, "error column index");
	/*
	 * A number is rejected as a whole, so the error points at the first
	 * byte of the literal rather than at the '.' that broke the grammar.
	 */
	is(error_column("[0,1.]"), 3, "rejected number reports its start");

	check_plan();
	footer();
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);
	lexer_env_create();

	plan(8);
	test_scalars();
	test_numbers();
	test_strings();
	test_control_chars_in_strings();
	test_invalid_numbers();
	test_invalid_numbers_allowed();
	test_no_sentinel();
	test_error_position();
	int rc = check_plan();

	lexer_env_destroy();
	fiber_free();
	memory_free();
	return rc;
}
