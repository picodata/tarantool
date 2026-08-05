/* Lua CJSON - JSON support for Lua
 *
 * Copyright (c) 2010-2012  Mark Pulford <mark@kyne.com.au>
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/* Caveats:
 * - JSON "null" values are represented as lightuserdata since Lua
 *   tables cannot contain "nil". Compare with cjson.null.
 * - Invalid UTF-8 characters are not detected and will be passed
 *   untouched. If required, UTF-8 error checking should be done
 *   outside this library.
 * - Javascript comments are not part of the JSON spec, and are not
 *   currently supported.
 *
 * Note: Decoding is slower than encoding. Lua spends significant
 *       time (30%) managing tables when parsing JSON since it is
 *       difficult to know object/array sizes ahead of time.
 */

#include "trivia/util.h"

#include <assert.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <lua.h>
#include <lauxlib.h>

#include "strbuf.h"

#include "lua/utils.h"
#include "lua/serializer.h"
#include "mp_extension_types.h" /* MP_DECIMAL, MP_UUID */
#include "diag.h"
#include "tt_static.h"
#include "core/datetime.h"
#include "cord_buf.h"
#include "tt_uuid.h" /* tt_uuid_to_string(), UUID_STR_LEN */

#include "cjson_lexer.h"

#if 0
static int json_destroy_config(lua_State *l)
{
    struct luaL_serializer *cfg;

    cfg = lua_touserdata(l, 1);
    if (cfg)
    strbuf_free(&encode_buf);
    cfg = NULL;

    return 0;
}
#endif

/* ===== ENCODING ===== */

/* json_append_string args:
 * - lua_State
 * - JSON strbuf
 * - String (Lua stack index)
 *
 * Returns nothing. Doesn't remove string from Lua stack */
static void json_append_string(struct luaL_serializer *cfg, strbuf_t *json,
                   const char *str, size_t len)
{
    (void) cfg;
    const char *escstr;
    size_t i;

    /* Worst case is len * 6 (all unicode escapes).
     * This buffer is reused constantly for small strings
     * If there are any excess pages, they won't be hit anyway.
     * This gains ~5% speedup. */
    strbuf_ensure_empty_length(json, len * 6 + 2);

    strbuf_append_char_unsafe(json, '\"');
    for (i = 0; i < len; i++) {
        escstr = json_escape_char(str[i]);
        if (escstr)
            strbuf_append_string(json, escstr);
        else
            strbuf_append_char_unsafe(json, str[i]);
    }
    strbuf_append_char_unsafe(json, '\"');
}

/* json_append_unescaped_string args:
 * - lua_State
 * - JSON strbuf
 * - String (Lua stack index)
 *
 * Returns nothing. Doesn't remove string from Lua stack */
static void json_append_decimal(struct luaL_serializer *cfg, strbuf_t *json,
                   decimal_t * decNumber)
{
    const char *str = decimal_str(decNumber);
    const size_t len = strlen(str);

    if (! cfg->encode_decimal_as_number) {
        return json_append_string(cfg, json, str, len);
    }

    (void) cfg;

    // append decimal as unescaped string to represent JSON number
    strbuf_ensure_empty_length(json, len);
    size_t i;
    for (i = 0; i < len; i++) {
        strbuf_append_char_unsafe(json, str[i]);
    }
}

static void json_append_data(lua_State *l, struct luaL_serializer *cfg,
                             int current_depth, strbuf_t *json);

/* json_append_array args:
 * - lua_State
 * - JSON strbuf
 * - Size of passwd Lua array (top of stack) */
static void json_append_array(lua_State *l, struct luaL_serializer *cfg,
                  int current_depth, strbuf_t *json,
                  int array_length)
{
    int comma, i;

    strbuf_append_char(json, '[');

    comma = 0;
    for (i = 1; i <= array_length; i++) {
        if (comma)
            strbuf_append_char(json, ',');
        else
            comma = 1;

        lua_rawgeti(l, -1, i);
        json_append_data(l, cfg, current_depth, json);
        lua_pop(l, 1);
    }

    strbuf_append_char(json, ']');
}

static void json_append_uint(struct luaL_serializer *cfg, strbuf_t *json,
                 uint64_t num)
{
    (void) cfg;
    enum { INT_BUFSIZE = 22 };
    strbuf_ensure_empty_length(json, INT_BUFSIZE);
    int len = snprintf(strbuf_empty_ptr(json), INT_BUFSIZE, "%llu",
               (unsigned long long) num);
    strbuf_extend_length(json, len);
}

static void json_append_int(struct luaL_serializer *cfg, strbuf_t *json,
               int64_t num)
{
    (void) cfg;
    enum {INT_BUFSIZE = 22 };
    strbuf_ensure_empty_length(json, INT_BUFSIZE);
    int len = snprintf(strbuf_empty_ptr(json), INT_BUFSIZE, "%lld",
               (long long) num);
    strbuf_extend_length(json, len);
}

static void json_append_nil(struct luaL_serializer *cfg, strbuf_t *json)
{
    (void) cfg;
    strbuf_append_mem(json, "null", 4);
}

static void json_append_number(struct luaL_serializer *cfg, strbuf_t *json,
                   lua_Number num)
{
    if (isnan(num)) {
    strbuf_append_mem(json, "nan", 3);
    return;
    }

    int len;
    strbuf_ensure_empty_length(json, FPCONV_G_FMT_BUFSIZE);
    len = fpconv_g_fmt(strbuf_empty_ptr(json), num, cfg->encode_number_precision);
    strbuf_extend_length(json, len);
}

static void json_append_object(lua_State *l, struct luaL_serializer *cfg,
                               int current_depth, strbuf_t *json)
{
    int comma;

    /* Object */
    strbuf_append_char(json, '{');

    lua_pushnil(l);
    /* table, startkey */
    comma = 0;
    while (lua_next(l, -2) != 0) {
        if (comma)
            strbuf_append_char(json, ',');
        else
            comma = 1;

    struct luaL_field field;
    luaL_checkfield(l, cfg, -2, &field);
    if (field.type == MP_UINT) {
        strbuf_append_char(json, '"');
        json_append_uint(cfg, json, field.ival);
        strbuf_append_mem(json, "\":", 2);
    } else if (field.type == MP_INT) {
        strbuf_append_char(json, '"');
        json_append_int(cfg, json, field.ival);
        strbuf_append_mem(json, "\":", 2);
    } else if (field.type == MP_STR) {
        json_append_string(cfg, json, field.sval.data, field.sval.len);
        strbuf_append_char(json, ':');
    } else {
        luaL_error(l, "table key must be a number or string");
    }

        /* table, key, value */
        json_append_data(l, cfg, current_depth, json);
        lua_pop(l, 1);
        /* table, key */
    }

    strbuf_append_char(json, '}');
}

/* Serialise Lua data into JSON string. */
static void json_append_data(lua_State *l, struct luaL_serializer *cfg,
                             int current_depth, strbuf_t *json)
{
    struct luaL_field field;
    luaL_checkfield(l, cfg, -1, &field);
    switch (field.type) {
    case MP_UINT:
        return json_append_uint(cfg, json, field.ival);
    case MP_STR:
    case MP_BIN:
        return json_append_string(cfg, json, field.sval.data, field.sval.len);
    case MP_INT:
        return json_append_int(cfg, json, field.ival);
    case MP_FLOAT:
        return json_append_number(cfg, json, field.fval);
    case MP_DOUBLE:
        return json_append_number(cfg, json, field.dval);
    case MP_BOOL:
    if (field.bval)
        strbuf_append_mem(json, "true", 4);
    else
        strbuf_append_mem(json, "false", 5);
    break;
    case MP_NIL:
    json_append_nil(cfg, json);
    break;
    case MP_MAP:
    if (current_depth >= cfg->encode_max_depth) {
        if (! cfg->encode_deep_as_nil)
            luaL_error(l, "Too high nest level");
        return json_append_nil(cfg, json); /* Limit nested maps */
    }
    json_append_object(l, cfg, current_depth + 1, json);
    return;
    case MP_ARRAY:
    /* Array */
    if (current_depth >= cfg->encode_max_depth) {
        if (! cfg->encode_deep_as_nil)
            luaL_error(l, "Too high nest level");
        return json_append_nil(cfg, json); /* Limit nested arrays */
    }
    json_append_array(l, cfg, current_depth + 1, json, field.size);
    return;
    case MP_EXT:
        switch (field.ext_type) {
        case MP_DECIMAL:
        {
            return json_append_decimal(cfg, json, field.decval);
        }
        case MP_UUID:
            return json_append_string(cfg, json, tt_uuid_str(field.uuidval),
                                      UUID_STR_LEN);
        case MP_ERROR:
        {
            const char *str = field.errorval->errmsg;
            return json_append_string(cfg, json, str, strlen(str));
        }
        case MP_DATETIME:
        {
            char buf[DT_TO_STRING_BUFSIZE];
            size_t sz = datetime_to_string(field.dateval, buf, sizeof(buf));
            return json_append_string(cfg, json, buf, sz);
        }
        case MP_INTERVAL:
        {
            char buf[DT_IVAL_TO_STRING_BUFSIZE];
            size_t sz = interval_to_string(field.interval, buf, sizeof(buf));
            return json_append_string(cfg, json, buf, sz);
        }
        default:
            assert(false);
        }
    }
}

static int json_encode(lua_State *l) {
    luaL_argcheck(l, lua_gettop(l) == 2 || lua_gettop(l) == 1, 1,
                  "expected 1 or 2 arguments");

    /* Reuse existing buffer. */
    strbuf_t encode_buf;
    struct ibuf *ibuf = cord_ibuf_take();
    strbuf_create(&encode_buf, STRBUF_DEFAULT_SIZE, ibuf);
    struct luaL_serializer *cfg = luaL_checkserializer(l);

    if (lua_gettop(l) == 2) {
        struct luaL_serializer user_cfg = *cfg;
        luaL_serializer_parse_options(l, &user_cfg);
        lua_pop(l, 1);
        json_append_data(l, &user_cfg, 0, &encode_buf);
    } else {
        json_append_data(l, cfg, 0, &encode_buf);
    }

    char *json = strbuf_string(&encode_buf, NULL);
    lua_pushlstring(l, json, strbuf_length(&encode_buf));
    /*
     * Even if an exception is raised above, it is fine to skip the buffer
     * destruction. The strbuf object destructor does not free anything, and
     * the cord_ibuf object is freed automatically on a next yield.
     */
    strbuf_destroy(&encode_buf);
    cord_ibuf_put(ibuf);
    return 1;
}

/* ===== DECODING ===== */

/*
 * Decode context: the Lua-free lexer state plus the Lua serializer
 * config it needs. lua_State is threaded separately, as before.
 */
struct json_decode_ctx {
    json_parse_t lex;
    struct luaL_serializer *cfg;
    int current_depth;
};

static void json_process_value(lua_State *l, struct json_decode_ctx *ctx,
                               json_token_t *token);

/* This function does not return.
 * DO NOT CALL WITH DYNAMIC MEMORY ALLOCATED.
 * The only supported exception is the temporary parser string
 * json->tmp struct.
 * json and token should exist on the stack somewhere.
 * luaL_error() will long_jmp and release the stack */
static void json_throw_parse_error(lua_State *l, json_parse_t *json,
                                   const char *exp, json_token_t *token)
{
    const char *found;
    struct ibuf *ibuf = json->tmp->ibuf;
    strbuf_destroy(json->tmp);
    cord_ibuf_put(ibuf);

    if (token->type == JSON_T_ERROR)
        found = token->value.string;
    else
        found = json_token_type_name[token->type];

    int column_index = token->start - json->cur_line_ptr;
    char err_context[ERR_CONTEXT_MAX_LENGTH + 1];
    json_fill_err_context(err_context, json, column_index);

    /* Note: column_index is 0 based, display starting from 1 */
    luaL_error(l, "Expected %s but found %s on line %d at character %d here "
               "'%s'", exp, found, json->line_count, column_index + 1,
               err_context);
}

static inline void json_decode_ascend(struct json_decode_ctx *ctx)
{
    ctx->current_depth--;
}

static void json_decode_descend(lua_State *l, struct json_decode_ctx *ctx,
                                int slots)
{
    ctx->current_depth++;

    if (ctx->current_depth <= ctx->cfg->decode_max_depth &&
        lua_checkstack(l, slots)) {
        return;
    }

    char err_context[ERR_CONTEXT_MAX_LENGTH + 1];
    json_fill_err_context(err_context, &ctx->lex,
                          ctx->lex.ptr - ctx->lex.cur_line_ptr - 1);

    struct ibuf *ibuf = ctx->lex.tmp->ibuf;
    strbuf_destroy(ctx->lex.tmp);
    cord_ibuf_put(ibuf);
    luaL_error(l, "Found too many nested data structures (%d) on line %d at cha"
               "racter %d here '%s'", ctx->current_depth, ctx->lex.line_count,
               ctx->lex.ptr - ctx->lex.cur_line_ptr, err_context);
}

static void json_parse_object_context(lua_State *l, struct json_decode_ctx *ctx)
{
    json_token_t token;

    /* 3 slots required:
     * .., table, key, value */
    json_decode_descend(l, ctx, 3);

    lua_newtable(l);
    if (ctx->cfg->decode_save_metatables)
        luaL_setmaphint(l, -1);

    json_next_token(&ctx->lex, &token);

    /* Handle empty objects */
    if (token.type == JSON_T_OBJ_END) {
        json_decode_ascend(ctx);
        return;
    }

    while (1) {
        if (token.type != JSON_T_STRING)
            json_throw_parse_error(l, &ctx->lex, "object key string", &token);

        /* Push key */
        lua_pushlstring(l, token.value.string, token.string_len);

        json_next_token(&ctx->lex, &token);
        if (token.type != JSON_T_COLON)
            json_throw_parse_error(l, &ctx->lex, "colon", &token);

        /* Fetch value */
        json_next_token(&ctx->lex, &token);
        json_process_value(l, ctx, &token);

        /* Set key = value */
        lua_rawset(l, -3);

        json_next_token(&ctx->lex, &token);

        if (token.type == JSON_T_OBJ_END) {
            json_decode_ascend(ctx);
            return;
        }

        if (token.type != JSON_T_COMMA)
            json_throw_parse_error(l, &ctx->lex, "comma or '}'", &token);

        json_next_token(&ctx->lex, &token);
    }
}

/* Handle the array context */
static void json_parse_array_context(lua_State *l, struct json_decode_ctx *ctx)
{
    json_token_t token;
    int i;

    /* 2 slots required:
     * .., table, value */
    json_decode_descend(l, ctx, 2);

    lua_newtable(l);
    if (ctx->cfg->decode_save_metatables)
        luaL_setarrayhint(l, -1);

    json_next_token(&ctx->lex, &token);

    /* Handle empty arrays */
    if (token.type == JSON_T_ARR_END) {
        json_decode_ascend(ctx);
        return;
    }

    for (i = 1; ; i++) {
        json_process_value(l, ctx, &token);
        lua_rawseti(l, -2, i);            /* arr[i] = value */

        json_next_token(&ctx->lex, &token);

        if (token.type == JSON_T_ARR_END) {
            json_decode_ascend(ctx);
            return;
        }

        if (token.type != JSON_T_COMMA)
            json_throw_parse_error(l, &ctx->lex, "comma or ']'", &token);

        json_next_token(&ctx->lex, &token);
    }
}

/* Handle the "value" context */
static void json_process_value(lua_State *l, struct json_decode_ctx *ctx,
                               json_token_t *token)
{
    switch (token->type) {
    case JSON_T_STRING:
        lua_pushlstring(l, token->value.string, token->string_len);
        break;;
    case JSON_T_UINT:
        luaL_pushuint64(l, token->value.ival);
        break;;
    case JSON_T_INT:
        luaL_pushint64(l, token->value.ival);
        break;;
    case JSON_T_DECIMAL:
    case JSON_T_DOUBLE:
        luaL_checkfinite(l, ctx->cfg, token->value.number);
        lua_pushnumber(l, token->value.number);
        break;;
    case JSON_T_BOOLEAN:
        lua_pushboolean(l, token->value.boolean);
        break;;
    case JSON_T_OBJ_BEGIN:
        json_parse_object_context(l, ctx);
        break;;
    case JSON_T_ARR_BEGIN:
        json_parse_array_context(l, ctx);
        break;;
    case JSON_T_NULL:
    luaL_pushnull(l);
        break;;
    default:
        json_throw_parse_error(l, &ctx->lex, "value", token);
    }
}

static int json_decode(lua_State *l)
{
    struct json_decode_ctx ctx;
    json_token_t token;
    size_t json_len;

    luaL_argcheck(l, lua_gettop(l) == 2 || lua_gettop(l) == 1, 1,
                  "expected 1 or 2 arguments");

    struct luaL_serializer *cfg = luaL_checkserializer(l);

    /*
     * user_cfg is per-call local version of serializer instance
     * options: it is used if a user passes custom options to
     * :decode() method within a separate argument. In this case
     * it is required to avoid modifying options of the instance.
     * Life span of user_cfg is restricted by the scope of
     * :decode() so it is enough to allocate it on the stack.
     */
    struct luaL_serializer user_cfg;
    if (lua_gettop(l) == 2) {
        /*
         * on_update triggers are left uninitialized for user_cfg.
         * The decoding code don't (and shouldn't) run them.
         */
        luaL_serializer_copy_options(&user_cfg, cfg);
        luaL_serializer_parse_options(l, &user_cfg);
        lua_pop(l, 1);
        cfg = &user_cfg;
    }

    ctx.cfg = cfg;
    const char *data = luaL_checklstring(l, 1, &json_len);
    ctx.lex.decode_invalid_numbers = cfg->decode_invalid_numbers;
    ctx.current_depth = 0;
    ctx.lex.ptr = data;
    ctx.lex.end = data + json_len;
    ctx.lex.line_count = 1;
    ctx.lex.cur_line_ptr = data;

    /* Detect Unicode other than UTF-8 (see RFC 4627, Sec 3)
     *
     * CJSON can support any simple data type, hence only the first
     * character is guaranteed to be ASCII (at worst: '"'). This is
     * still enough to detect whether the wrong encoding is in use. */
    if (json_len >= 2 && (!data[0] || !data[1]))
        luaL_error(l, "JSON parser does not support UTF-16 or UTF-32");

    /* Ensure the temporary buffer can hold the entire string.
     * This means we no longer need to do length checks since the decoded
     * string must be smaller than the entire json string */
    strbuf_t decode_buf;
    ctx.lex.tmp = &decode_buf;
    struct ibuf *ibuf = cord_ibuf_take();
    strbuf_create(&decode_buf, json_len, ibuf);

    json_next_token(&ctx.lex, &token);
    json_process_value(l, &ctx, &token);

    /* Ensure there is no more input left */
    json_next_token(&ctx.lex, &token);

    if (token.type != JSON_T_END)
        json_throw_parse_error(l, &ctx.lex, "the end", &token);

    strbuf_destroy(&decode_buf);
    cord_ibuf_put(ibuf);

    return 1;
}

/* ===== INITIALISATION ===== */

static int
json_new(lua_State *L);

static const luaL_Reg jsonlib[] = {
    { "encode", json_encode },
    { "decode", json_decode },
    { "new",    json_new },
    { NULL, NULL}
};

static int
json_new(lua_State *L)
{
    luaL_newserializer(L, NULL, jsonlib);
    return 1;
}

int
luaopen_json(lua_State *L)
{
    luaL_newserializer(L, "json", jsonlib);
    luaL_pushnull(L);
    lua_setfield(L, -2, "null"); /* compatibility with cjson */
    return 1;
}

/* vi:ai et sw=4 ts=4:
 */
