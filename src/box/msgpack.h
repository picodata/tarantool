#pragma once
/*
 * Copyright 2020, Tarantool AUTHORS, please see AUTHORS file.
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

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

void
msgpack_init(void);

/**
 * Act on a verdict from json_verify() or mp_verify_json(): pass a normalized
 * value through, and name which of the two mistakes its producer made
 * otherwise. Spelled non-canonically gets ER_JSON_NOT_NORMALIZED and the
 * offset; anything else ER_INVALID_MSGPACK and "invalid JSON value in @a where
 * at offset N".
 *
 * Every perimeter in box reports through this, so the two verdicts reach a
 * client as the same pair of codes worded the same way whichever caught the
 * value. @a where is the only part a caller chooses: a noun for the thing
 * being decoded, as in "a bind" or "a key". It is evaluated on the good path
 * too, so it has to be cheap, a literal in practice. One site cannot meet that
 * and reports on its own: tuple_validate_json() names the offending field,
 * which costs a walk of the tuple.
 *
 * Above box, src/lua has no access to these codes and reports the same two
 * verdicts as a LuajitError through luaT_json_check().
 *
 * @retval 0 if @a rc is JSON_NORM_OK, -1 otherwise with the diag set.
 */
int
json_norm_handle(enum json_norm_status rc, uint32_t err_off,
		 const char *where);

#if defined(__cplusplus)
}
#endif /* defined(__cplusplus) */
