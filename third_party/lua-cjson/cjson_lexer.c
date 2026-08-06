#include "cjson_lexer.h"

#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <stdlib.h>

#include "trivia/util.h" /* fpconv_strtod */
#include "strbuf.h"

const char *json_token_type_name[] = {
    "'{'",
    "'}'",
    "'['",
    "']'",
    "string",
    "unsigned int",
    "int",
    "number",
    "number",
    "boolean",
    "null",
    "colon",
    "comma",
    "end",
    "whitespace",
    "line feed",
    "error",
    "unknown symbol",
    NULL
};

static json_token_type_t ch2token[256];
static char escape2char[256];  /* Decoding */

static void json_next_string_token(json_parse_t *json, json_token_t *token);
static void json_next_number_token(json_parse_t *json, json_token_t *token);
static int json_is_invalid_number(json_parse_t *json);

__attribute__((constructor))
static void json_create_tokens()
{
    int i;

    /* Decoding init */

    /* Tag all characters as an error */
    for (i = 0; i < 256; i++)
    ch2token[i] = JSON_T_ERROR;

    /* Set tokens that require no further processing */
    ch2token['{'] = JSON_T_OBJ_BEGIN;
    ch2token['}'] = JSON_T_OBJ_END;
    ch2token['['] = JSON_T_ARR_BEGIN;
    ch2token[']'] = JSON_T_ARR_END;
    ch2token[','] = JSON_T_COMMA;
    ch2token[':'] = JSON_T_COLON;
    ch2token['\0'] = JSON_T_END;
    ch2token[' '] = JSON_T_WHITESPACE;
    ch2token['\t'] = JSON_T_WHITESPACE;
    ch2token['\n'] = JSON_T_LINEFEED;
    ch2token['\r'] = JSON_T_WHITESPACE;

    /* Update characters that require further processing */
    ch2token['f'] = JSON_T_UNKNOWN;     /* false? */
    ch2token['i'] = JSON_T_UNKNOWN;     /* inf, ininity? */
    ch2token['I'] = JSON_T_UNKNOWN;
    ch2token['n'] = JSON_T_UNKNOWN;     /* null, nan? */
    ch2token['N'] = JSON_T_UNKNOWN;
    ch2token['t'] = JSON_T_UNKNOWN;     /* true? */
    ch2token['"'] = JSON_T_UNKNOWN;     /* string? */
    ch2token['+'] = JSON_T_UNKNOWN;     /* number? */
    ch2token['-'] = JSON_T_UNKNOWN;
    for (i = 0; i < 10; i++)
    ch2token['0' + i] = JSON_T_UNKNOWN;

    /* Lookup table for parsing escape characters */
    for (i = 0; i < 256; i++)
    escape2char[i] = 0;          /* String error */
    escape2char['"'] = '"';
    escape2char['\\'] = '\\';
    escape2char['/'] = '/';
    escape2char['b'] = '\b';
    escape2char['t'] = '\t';
    escape2char['n'] = '\n';
    escape2char['f'] = '\f';
    escape2char['r'] = '\r';
    escape2char['u'] = 'u';          /* Unicode parsing required */
}

/* Bytes remaining from json->ptr, inclusive of the byte it points at. */
static inline ptrdiff_t json_avail(const json_parse_t *json)
{
    return json->end - json->ptr;
}

/* Byte at json->ptr + offset, or '\0' once that reaches json->end.
 *
 * The lexer used to rely on a NUL sentinel at the end of the buffer; reporting
 * '\0' for an out-of-range offset keeps every caller's existing logic intact,
 * including the ch2token['\0'] == JSON_T_END dispatch. An embedded NUL
 * therefore still ends the scan, exactly as before. */
static inline char json_peek_at(const json_parse_t *json, ptrdiff_t offset)
{
    return offset < json_avail(json) ? json->ptr[offset] : '\0';
}

/* Consume word when it is the next thing in the buffer, and report whether it
 * was. A truncated tail at the end of the buffer is a mismatch rather than an
 * overread, and json->ptr is left alone unless the whole word matched. */
static inline bool json_accept(json_parse_t *json, const char *word)
{
    ptrdiff_t len = strlen(word);
    if (json_avail(json) < len || memcmp(json->ptr, word, len) != 0)
        return false;
    json->ptr += len;
    return true;
}

static int hexdigit2int(char hex)
{
    if ('0' <= hex  && hex <= '9')
        return hex - '0';

    /* Force lowercase */
    hex |= 0x20;
    if ('a' <= hex && hex <= 'f')
        return 10 + hex - 'a';

    return -1;
}

static int decode_hex4(const json_parse_t *json, ptrdiff_t offset)
{
    int digit[4];
    int i;

    /* Convert ASCII hex digit to numeric digit
     * Note: this returns an error for invalid hex digits, including
     *       NULL. Bytes past the end of the buffer read as '\0', so a
     *       truncated escape fails here exactly like an invalid one. */
    for (i = 0; i < 4; i++) {
        digit[i] = hexdigit2int(json_peek_at(json, offset + i));
        if (digit[i] < 0) {
            return -1;
        }
    }

    return (digit[0] << 12) +
           (digit[1] << 8) +
           (digit[2] << 4) +
            digit[3];
}

/* Converts a Unicode codepoint to UTF-8.
 * Returns UTF-8 string length, and up to 4 bytes in *utf8 */
static int codepoint_to_utf8(char *utf8, int codepoint)
{
    /* 0xxxxxxx */
    if (codepoint <= 0x7F) {
        utf8[0] = codepoint;
        return 1;
    }

    /* 110xxxxx 10xxxxxx */
    if (codepoint <= 0x7FF) {
        utf8[0] = (codepoint >> 6) | 0xC0;
        utf8[1] = (codepoint & 0x3F) | 0x80;
        return 2;
    }

    /* 1110xxxx 10xxxxxx 10xxxxxx */
    if (codepoint <= 0xFFFF) {
        utf8[0] = (codepoint >> 12) | 0xE0;
        utf8[1] = ((codepoint >> 6) & 0x3F) | 0x80;
        utf8[2] = (codepoint & 0x3F) | 0x80;
        return 3;
    }

    /* 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx */
    if (codepoint <= 0x1FFFFF) {
        utf8[0] = (codepoint >> 18) | 0xF0;
        utf8[1] = ((codepoint >> 12) & 0x3F) | 0x80;
        utf8[2] = ((codepoint >> 6) & 0x3F) | 0x80;
        utf8[3] = (codepoint & 0x3F) | 0x80;
        return 4;
    }

    return 0;
}


/* Called when index pointing to beginning of UTF-16 code escape: \uXXXX
 * \u is guaranteed to exist, but the remaining hex characters may be
 * missing.
 * Translate to UTF-8 and append to temporary token string.
 * Must advance index to the next character to be processed.
 * Returns: 0   success
 *          -1  error
 */
static int json_append_unicode_escape(json_parse_t *json)
{
    char utf8[4];       /* Surrogate pairs require 4 UTF-8 bytes */
    int codepoint;
    int surrogate_low;
    int len;
    int escape_len = 6;

    /* Fetch UTF-16 code unit */
    codepoint = decode_hex4(json, 2);
    if (codepoint < 0)
        return -1;

    /* UTF-16 surrogate pairs take the following 2 byte form:
     *      11011 x yyyyyyyyyy
     * When x = 0: y is the high 10 bits of the codepoint
     *      x = 1: y is the low 10 bits of the codepoint
     *
     * Check for a surrogate pair (high or low) */
    if ((codepoint & 0xF800) == 0xD800) {
        /* Error if the 1st surrogate is not high */
        if (codepoint & 0x400)
            return -1;

        /* Ensure the next code is a unicode escape */
        if (json_peek_at(json, escape_len) != '\\' ||
            json_peek_at(json, escape_len + 1) != 'u') {
            return -1;
        }

        /* Fetch the next codepoint */
        surrogate_low = decode_hex4(json, 2 + escape_len);
        if (surrogate_low < 0)
            return -1;

        /* Error if the 2nd code is not a low surrogate */
        if ((surrogate_low & 0xFC00) != 0xDC00)
            return -1;

        /* Calculate Unicode codepoint */
        codepoint = (codepoint & 0x3FF) << 10;
        surrogate_low &= 0x3FF;
        codepoint = (codepoint | surrogate_low) + 0x10000;
        escape_len = 12;
    }

    /* Convert codepoint to UTF-8 */
    len = codepoint_to_utf8(utf8, codepoint);
    if (!len)
        return -1;

    /* Append bytes and advance parse index */
    strbuf_append_mem_unsafe(json->tmp, utf8, len);
    json->ptr += escape_len;

    return 0;
}

static void json_set_token_error(json_token_t *token, json_parse_t *json,
                                 const char *errtype)
{
    token->type = JSON_T_ERROR;
    token->start = json->ptr;
    token->value.string = errtype;
}

static void json_next_string_token(json_parse_t *json, json_token_t *token)
{
    char ch;

    /* Caller must ensure a string is next */
    assert(*json->ptr == '"');

    /* Skip " */
    json->ptr++;

    /* json->tmp is the temporary strbuf used to accumulate the
     * decoded string value.
     * json->tmp is sized to handle JSON containing only a string value.
     */
    strbuf_reset(json->tmp);
    /* The decoded string cannot outgrow the text it is decoded from, so the
     * buffer the caller sized for the whole input has room for it; that is
     * what lets the appends below skip their capacity checks. */
    assert(strbuf_empty_length(json->tmp) >= (int)(json->end - json->ptr));

    while ((ch = json_peek_at(json, 0)) != '"') {
        if (!ch) {
            /* Premature end of the string */
            json_set_token_error(token, json, "unexpected end of string");
            return;
        }

        /* Handle escapes */
        if (ch == '\\') {
            /* Fetch escape character */
            ch = json_peek_at(json, 1);

            /* Translate escape code and append to tmp string */
            ch = escape2char[(unsigned char)ch];
            if (ch == 'u') {
                if (json_append_unicode_escape(json) == 0)
                    continue;

                json_set_token_error(token, json,
                                     "invalid unicode escape code");
                return;
            }
            if (!ch) {
                json_set_token_error(token, json, "invalid escape code");
                return;
            }

            /* Skip '\' */
            json->ptr++;
        }
        /* Append normal character or translated single character
         * Unicode escapes are handled above */
        strbuf_append_char_unsafe(json->tmp, ch);
        json->ptr++;
    }
    json->ptr++;    /* Eat final quote (") */

    strbuf_ensure_null(json->tmp);

    token->type = JSON_T_STRING;
    token->value.string = strbuf_string(json->tmp, &token->string_len);
}

/* JSON numbers should take the following form:
 *      -?(0|[1-9]|[1-9][0-9]+)(.[0-9]+)?([eE][-+]?[0-9]+)?
 *
 * json_next_number_token() uses strtod() which allows other forms:
 * - numbers starting with '+'
 * - NaN, -NaN, infinity, -infinity
 * - hexadecimal numbers
 * - numbers with leading zeros
 *
 * json_is_invalid_number() detects "numbers" which may pass strtod()'s
 * error checking, but should not be allowed with strict JSON.
 *
 * json_is_invalid_number() may pass numbers which cause strtod()
 * to generate an error.
 */
static int json_is_invalid_number(json_parse_t *json)
{
    ptrdiff_t offset = 0;
    char ch = json_peek_at(json, offset);

    /* Reject numbers starting with + */
    if (ch == '+')
        return 1;

    /* Skip minus sign if it exists */
    if (ch == '-')
        ch = json_peek_at(json, ++offset);

    /* Reject numbers starting with 0x, or leading zeros */
    if (ch == '0') {
        int ch2 = json_peek_at(json, offset + 1);

        if ((ch2 | 0x20) == 'x' ||          /* Hex */
            ('0' <= ch2 && ch2 <= '9'))     /* Leading zero */
            return 1;

        return 0;
    } else if (ch < '0' || ch > '9') {
        return 1;
    }

    return 0;
}

/* A byte strtoll(), strtoull() or fpconv_strtod() could consume. A superset
 * of the JSON number grammar is deliberate: this only decides whether a
 * literal reaches the end of the buffer, so over-accepting costs nothing. */
static inline bool json_is_number_char(char ch)
{
    return (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' ||
           ch == 'e' || ch == 'E';
}

/* End of the longest run of bytes a conversion could consume. */
static const char *json_scan_number_run(const char *p, const char *end)
{
    while (p < end && json_is_number_char(*p))
        p++;

    return p;
}

enum {
    /*
     * Covers any numeric literal whose exact text can affect the converted
     * value. The widest of those is a decimal: DECIMAL_MAX_DIGITS is 38, and
     * decimal.h budgets 14 more bytes for the sign, point and exponent. A
     * uint64 takes 20 digits and a double is pinned by 17 significant ones
     * plus a short exponent, so both fit well inside that. Longer literals
     * are still valid JSON; they fall back to the heap rather than being
     * truncated.
     */
    JSON_NUM_BUF_SIZE = 64,
};

static void json_next_number_token(json_parse_t *json, json_token_t *token)
{
    const char *start = json->ptr;
    char *endptr;

    /*
     * The strto*() family scans until a byte outside its grammar, so it needs
     * a terminator and cannot be bounded. Every byte inside the buffer stops
     * it, since a JSON number is always followed by ',', '}', ']' or
     * whitespace; only a literal running to the very last byte of the input
     * has nothing to stop it. Give that one, at most one per parse, a
     * terminated copy to convert from. Nothing outside this function reads the
     * copy, so it dies with the frame.
     */
    char buf[JSON_NUM_BUF_SIZE];
    char *heap = NULL;
    const char *conv = start;
    /* A run can only reach the end when the buffer's last byte belongs to
     * one, which is false for every document ending in ',', '}', ']' or
     * whitespace; that test keeps the scan off the common path. */
    token->num_at_end = json_is_number_char(json->end[-1]) &&
                        json_scan_number_run(start, json->end) == json->end;
    if (token->num_at_end) {
        size_t len = (size_t)(json->end - start);
        char *dst = len < sizeof(buf) ? buf : (heap = xmalloc(len + 1));

        memcpy(dst, start, len);
        dst[len] = '\0';
        conv = dst;
    }

    token->num_overflow = false;
    errno = 0;
    token->type = JSON_T_INT;
    token->value.ival = strtoll(conv, &endptr, 10);
    /* int64_max itself is reported as JSON_T_UINT: the literal fits int64,
     * but the lexer has always probed for overflow by comparing against
     * LLONG_MAX, so Lua's json.decode hands that one value out as a uint64
     * cdata. Keep it that way; errno covers everything past it. */
    if (errno == ERANGE || token->value.ival == LLONG_MAX) {
        if (conv[0] == '-') {
            /* Below int64_min. */
            token->num_overflow = true;
        } else {
            /* At int64_max or above; may still fit uint64. */
            errno = 0;
            token->type = JSON_T_UINT;
            token->value.ival = (long long)strtoull(conv, &endptr, 10);
            if (errno == ERANGE)
                token->num_overflow = true;
        }
    }
    if (*endptr == '.' || *endptr == 'e' || *endptr == 'E') {
        /* A fraction and/or exponent: reparse as floating and classify.
         * endptr is the first non-integer char, so scanning from it
         * covers only the fraction/exponent tail. An exponent wins over
         * a fraction (matches src/box/sql/tokenize.c). */
        const char *tail = endptr;
        json_token_type_t int_type = token->type;
        long long int_value = token->value.ival;
        bool int_overflow = token->num_overflow;

        token->num_overflow = false;
        token->value.number = fpconv_strtod(conv, &endptr);
        assert(endptr >= tail);
        if (endptr == tail) {
            /* The tail turned out to be neither: "1e" has no exponent
             * digits, so the floating conversion stopped where the integer
             * one did. Keep the integer reading rather than retyping the
             * same span; the leftover byte fails as a token of its own. */
            token->type = int_type;
            token->value.ival = int_value;
            token->num_overflow = int_overflow;
        } else {
            bool has_exp = false;
            for (const char *p = tail; p < endptr; p++) {
                if (*p == 'e' || *p == 'E') {
                    has_exp = true;
                    break;
                }
            }
            token->type = has_exp ? JSON_T_DOUBLE : JSON_T_DECIMAL;
        }
    }
    /* endptr indexes conv, which is the copy when the literal was copied; map
     * it back onto the source buffer before it becomes a position. */
    ptrdiff_t consumed = endptr - conv;
    free(heap);
    if (consumed == 0) {
        json_set_token_error(token, json, "invalid number");
        return;
    }
    token->num_len = (int)consumed;
    json->ptr = start + consumed;
}

/* Fills in the token struct.
 * JSON_T_STRING will return a pointer to the json_parse_t temporary string
 * JSON_T_ERROR will leave the json->ptr pointer at the error.
 */
void json_next_token(json_parse_t *json, json_token_t *token)
{
    int ch;

    /* Only a number fills these in, so clear them for every other token; a
     * consumer reusing one token struct must not read the previous token's
     * values here. */
    token->num_overflow = false;
    token->num_at_end = false;

    /* Eat whitespace. */
    while (1) {
        ch = (unsigned char)json_peek_at(json, 0);
        token->type = ch2token[ch];
        if (token->type == JSON_T_LINEFEED) {
            json->line_count++;
            json->cur_line_ptr = json->ptr + 1;
        } else if (token->type != JSON_T_WHITESPACE) {
            break;
        }
        json->ptr++;
    }

    /* Store location of new token. Required when throwing errors
     * for unexpected tokens (syntax errors). */
    token->start = json->ptr;

    /* Don't advance the pointer for an error or the end */
    if (token->type == JSON_T_ERROR) {
        json_set_token_error(token, json, "invalid token");
        return;
    }

    if (token->type == JSON_T_END) {
        return;
    }

    /* Found a known single character token, advance index and return */
    if (token->type != JSON_T_UNKNOWN) {
        json->ptr++;
        return;
    }

    /* Process characters which triggered JSON_T_UNKNOWN
     *
     * Must use strncmp() to match the front of the JSON string.
     * JSON identifier must be lowercase.
     * When strict_numbers if disabled, either case is allowed for
     * Infinity/NaN (since we are no longer following the spec..) */
    if (ch == '"') {
        json_next_string_token(json, token);
        return;
    } else if (!json_is_invalid_number(json)) {
        json_next_number_token(json, token);
        return;
    } else if (json_accept(json, "true")) {
        token->type = JSON_T_BOOLEAN;
        token->value.boolean = 1;
        return;
    } else if (json_accept(json, "false")) {
        token->type = JSON_T_BOOLEAN;
        token->value.boolean = 0;
        return;
    } else if (json_accept(json, "null")) {
        token->type = JSON_T_NULL;
        return;
    } else if (json->decode_invalid_numbers) {
        /*
         * RFC4627: Numeric values that cannot be represented as sequences of
         * digits (such as Infinity and NaN) are not permitted.
         *
         * These words are the one JSON_T_DOUBLE the number lexer never sees, so
         * they set num_len themselves; json_accept() has already advanced
         * json->ptr over the word.
         */
        if (json_accept(json, "inf")) {
            token->type = JSON_T_DOUBLE;
            token->value.number = INFINITY;
            token->num_len = (int)(json->ptr - token->start);
            return;
        } else if (json_accept(json, "-inf")) {
            token->type = JSON_T_DOUBLE;
            token->value.number = -INFINITY;
            token->num_len = (int)(json->ptr - token->start);
            return;
        } else if (json_accept(json, "nan") ||
                   json_accept(json, "-nan")) {
            token->type = JSON_T_DOUBLE;
            token->value.number = NAN;
            token->num_len = (int)(json->ptr - token->start);
            return;
        }
    }

    /* Token starts with t/f/n but isn't recognised above. */
    json_set_token_error(token, json, "invalid token");
}

/**
 * Copy characters near wrong token with the position @a
 * column_index to a static string buffer @a err_context and lay
 * out arrow " >> " before this token.
 *
 * @param context      String static buffer to fill.
 * @param json         Structure with pointers to parsing string.
 * @param column_index Position of wrong token in the current
 *                     line.
 */
void json_fill_err_context(char *err_context, json_parse_t *json,
                           int column_index)
{
    /* The arrow lands inside the input: the context before it is read back
     * from cur_line_ptr + column_index, which nothing else bounds. A token at
     * the very end of the buffer, JSON_T_END among them, is a position the
     * caller may ask about, so the end itself is allowed. */
    assert(column_index >= 0);
    assert(column_index <= json->end - json->cur_line_ptr);
    int length_before = column_index < ERR_CONTEXT_MAX_LENGTH_BEFORE ?
                        column_index : ERR_CONTEXT_MAX_LENGTH_BEFORE;
    const char *src = json->cur_line_ptr + column_index - length_before;
    /* Fill error context before the arrow. */
    memcpy(err_context, src, length_before);
    err_context += length_before;
    src += length_before;

    /* Make the arrow. */
    *(err_context++) = ' ';
    memset(err_context, '>', ERR_CONTEXT_ARROW_LENGTH - 2);
    err_context += ERR_CONTEXT_ARROW_LENGTH - 2;
    *(err_context++) = ' ';

    /* Fill error context after the arrow. */
    const char *ctx_end = err_context + ERR_CONTEXT_MAX_LENGTH_AFTER;
    for (; err_context < ctx_end && src < json->end && *src != '\0' &&
         *src != '\n'; ++src, ++err_context)
        *err_context = *src;
    *err_context = '\0';
}
