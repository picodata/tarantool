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
    JSON_T_NUMBER,
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
    /* First character of the token, or the offending one for JSON_T_ERROR. */
    const char *start;
    union {
        const char *string;
        double number;
        int boolean;
    long long ival;
    } value;
    int string_len;
} json_token_t;

enum err_context_length {
    ERR_CONTEXT_ARROW_LENGTH = 4,
    ERR_CONTEXT_MAX_LENGTH_BEFORE = 8,
    ERR_CONTEXT_MAX_LENGTH_AFTER = 8,
    ERR_CONTEXT_MAX_LENGTH = ERR_CONTEXT_MAX_LENGTH_BEFORE +
    ERR_CONTEXT_MAX_LENGTH_AFTER + ERR_CONTEXT_ARROW_LENGTH,
};

/* Fill in the next token; JSON_T_STRING points into json->tmp, JSON_T_ERROR leaves
 * json->ptr at the error and puts the message in token->value.string. */
void json_next_token(json_parse_t *json, json_token_t *token);

/* Lay out a " >> " arrow around the character at column_index into the
 * caller-provided buffer of at least ERR_CONTEXT_MAX_LENGTH + 1 bytes. */
void json_fill_err_context(char *err_context, json_parse_t *json,
                           int column_index);

#if defined(__cplusplus)
}
#endif

#endif /* TARANTOOL_LUA_CJSON_LEXER_H_INCLUDED */
