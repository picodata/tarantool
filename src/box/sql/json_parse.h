#pragma once
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

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/**
 * Parse [text, text + len) as a JSON document into a normalized inner
 * MessagePack value (no MP_EXT/MP_JSON header), so the caller may wrap it
 * into an envelope without a further tnt_json_normalize() pass.
 *
 * A region savepoint must be captured before every call and reclaimed after
 * it, success or not: rejecting a document can still leave a temporary buffer
 * on the region.
 *
 * Numbers follow Tarantool SQL's lexical numeric-literal rule: a dotless
 * integer becomes MP_UINT/MP_INT (out of [int64_min, uint64_max] is
 * ER_INT_LITERAL_MAX), a fraction with no exponent MP_DECIMAL (over range,
 * ER_INVALID_DEC) and an exponent literal MP_DOUBLE. A syntax or structural
 * error, nesting at or past JSON_MAX_NESTING_DEPTH included, is ER_JSON_PARSE.
 * The grammar is strict JSON: leading zeros, a bare '.', '+', hex and nan/inf
 * are rejected, and so is a raw control character inside a string. That last
 * is stricter than Lua's json.decode(), which shares the lexer.
 *
 * @param text the JSON text; need not be NUL-terminated.
 * @param[out] out_len the result length in bytes on success.
 * @return the normalized inner value, or NULL with a diag set.
 */
char *
tnt_json_parse(const char *text, uint32_t len, uint32_t *out_len);

#if defined(__cplusplus)
} /* extern "C" */
#endif
