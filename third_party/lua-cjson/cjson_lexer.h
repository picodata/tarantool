#ifndef TARANTOOL_LUA_CJSON_LEXER_H_INCLUDED
#define TARANTOOL_LUA_CJSON_LEXER_H_INCLUDED
/*
 * Lua-free JSON lexer extracted from lua_cjson.c. Tokenizes a JSON text
 * buffer with no Lua state; the value tree is built by the caller.
 */
#include <stdbool.h>
#include "strbuf.h"

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum {
    JSON_T_OBJ_BEGIN,
    JSON_T_OBJ_END,
    JSON_T_ARR_BEGIN,
    JSON_T_ARR_END,
    JSON_T_STRING,
    JSON_T_UINT,
    JSON_T_INT,
    JSON_T_DECIMAL,
    JSON_T_DOUBLE,
    JSON_T_BOOLEAN,
    JSON_T_NULL,
    JSON_T_COLON,
    JSON_T_COMMA,
    JSON_T_END,
    JSON_T_WHITESPACE,
    JSON_T_LINEFEED,
    JSON_T_ERROR,
    JSON_T_UNKNOWN
} json_token_type_t;

extern const char *json_token_type_name[];

typedef struct {
    const char *ptr;
    const char *end;  /* One past the last byte of the input */
    /* Where a string carrying escapes is decoded to, and what its token then
     * points into. The lexer appends here without checking capacity, so the
     * caller must size the buffer to hold the whole input text plus a NUL
     * terminator; a decoded string is never longer than its source text. */
    strbuf_t *tmp;
    bool decode_invalid_numbers; /* Accept the literal nan/inf words */
    int line_count;
    const char *cur_line_ptr;
} json_parse_t;

typedef struct {
    json_token_type_t type;
    /* Byte length of a numeric literal, set for every token typed JSON_T_UINT,
     * JSON_T_INT, JSON_T_DECIMAL or JSON_T_DOUBLE. */
    int num_len;
    /* First character of the token, or the offending one for JSON_T_ERROR. */
    const char *start;
    union {
        const char *string;
        double number;
        int boolean;
    long long ival;
    } value;
    int string_len;
    /* Integer literal outside [int64_min, uint64_max]; false for every token
     * that is not one, including the inf/nan words. */
    bool num_overflow;
    /* The numeric run this token starts reaches the end of the input, so no
     * byte terminates a scan that reads the literal in place. A consumer
     * re-reading it with a strto*()-style parser must copy and terminate it
     * first; note the run can extend past the token, so this can be set even
     * when the token itself ends earlier. False for every token that is not a
     * number, including the inf/nan words. */
    bool num_at_end;
} json_token_t;

enum err_context_length {
    ERR_CONTEXT_ARROW_LENGTH = 4,
    ERR_CONTEXT_MAX_LENGTH_BEFORE = 8,
    ERR_CONTEXT_MAX_LENGTH_AFTER = 8,
    ERR_CONTEXT_MAX_LENGTH = ERR_CONTEXT_MAX_LENGTH_BEFORE +
    ERR_CONTEXT_MAX_LENGTH_AFTER + ERR_CONTEXT_ARROW_LENGTH,
};

/* Fill in the next token; JSON_T_STRING points into the input when the string
 * carries no escape and into json->tmp when it had to be decoded, so
 * string_len is the only length to go by: a borrowed string runs on into the
 * rest of the input, and the NUL that happens to follow a decoded one belongs
 * to the buffer, not to the string. Which of the two it is decides how long it
 * lives: a string pointing into the input lasts as long as the input does, one
 * pointing into json->tmp only until the next string that has to be decoded.
 * Copy the value out to hold it across calls.
 * JSON_T_ERROR leaves json->ptr at the error and puts the message in
 * token->value.string.
 * The token spans [token->start, json->ptr) until the next call; a numeric
 * token spans [token->start, token->start + token->num_len). */
void json_next_token(json_parse_t *json, json_token_t *token);

/* Lay out a " >> " arrow around the character at column_index into the
 * caller-provided buffer of at least ERR_CONTEXT_MAX_LENGTH + 1 bytes. */
void json_fill_err_context(char *err_context, json_parse_t *json,
                           int column_index);

#if defined(__cplusplus)
}
#endif

#endif /* TARANTOOL_LUA_CJSON_LEXER_H_INCLUDED */
