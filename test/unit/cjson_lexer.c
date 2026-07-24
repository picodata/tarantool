#define UNIT_TAP_COMPATIBLE 1

#include "lua-cjson/cjson_lexer.h"
#include "memory.h"
#include "fiber.h"
#include "cord_buf.h"
#include "unit.h"

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

/* One-shot helper: tokenize the first token of a NUL-terminated string. */
static void
first_token(const char *str, bool allow_invalid, json_token_t *out)
{
	json_parse_t json;
	json.ptr = str;
	json.tmp = &lexer_tmp;
	json.decode_invalid_numbers = allow_invalid;
	json.line_count = 1;
	json.cur_line_ptr = str;

	json_next_token(&json, out);
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
	plan(13);
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

	first_token("1e3", false, &t);
	is(t.type, JSON_T_DOUBLE, "1e3 is double");

	/* Exponent wins over the fraction. */
	first_token("1.5e3", false, &t);
	is(t.type, JSON_T_DOUBLE, "1.5e3 is double");

	check_plan();
	footer();
}

static void
test_strings(void)
{
	plan(4);
	header();

	json_token_t t;
	first_token("\"abc\"", false, &t);
	is(t.type, JSON_T_STRING, "plain string type");
	is_str(t.value.string, "abc", "plain string value");

	first_token("\"a\\nb\"", false, &t);
	is_str(t.value.string, "a\nb", "escape decoded");

	/* Surrogate pair for U+1F600 (four UTF-8 bytes). */
	first_token("\"\\uD83D\\uDE00\"", false, &t);
	is_str(t.value.string, "\xF0\x9F\x98\x80", "surrogate pair decoded");

	check_plan();
	footer();
}

static void
test_invalid_numbers(void)
{
	plan(4);
	header();

	json_token_t t;
	first_token("01", false, &t);
	is(t.type, JSON_T_ERROR, "leading zero rejected");
	first_token("+1", false, &t);
	is(t.type, JSON_T_ERROR, "leading plus rejected");
	first_token(".5", false, &t);
	is(t.type, JSON_T_ERROR, "leading dot rejected");

	/* Without decode_invalid_numbers, inf is not a number. */
	first_token("inf", false, &t);
	is(t.type, JSON_T_ERROR, "inf rejected by default");

	check_plan();
	footer();
}

static void
test_invalid_numbers_allowed(void)
{
	plan(3);
	header();

	json_token_t t;
	first_token("inf", true, &t);
	is(t.type, JSON_T_DOUBLE, "inf allowed as double");
	/* Not an integer literal, so the overflow flag stays clear. */
	ok(!t.num_overflow, "inf does not report an overflow");
	first_token("nan", true, &t);
	is(t.type, JSON_T_DOUBLE, "nan allowed as double");

	check_plan();
	footer();
}

static void
test_error_position(void)
{
	plan(2);
	header();

	/*
	 * first_token reads only one token, so drive the lexer across the
	 * stream until the invalid '@' at column index 3 (0-based).
	 */
	const char *str = "[1,@]";
	json_parse_t json;
	json.ptr = str;
	json.tmp = &lexer_tmp;
	json.decode_invalid_numbers = false;
	json.line_count = 1;
	json.cur_line_ptr = str;

	json_token_t t;
	do {
		json_next_token(&json, &t);
	} while (t.type != JSON_T_ERROR && t.type != JSON_T_END);

	is(t.type, JSON_T_ERROR, "invalid token found");
	is((int)(t.start - json.cur_line_ptr), 3, "error column index");

	check_plan();
	footer();
}

int
main(void)
{
	memory_init();
	fiber_init(fiber_c_invoke);
	lexer_env_create();

	plan(6);
	test_scalars();
	test_numbers();
	test_strings();
	test_invalid_numbers();
	test_invalid_numbers_allowed();
	test_error_position();
	int rc = check_plan();

	lexer_env_destroy();
	fiber_free();
	memory_free();
	return rc;
}
