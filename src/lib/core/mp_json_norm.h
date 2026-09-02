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

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "mp_json.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

/**
 * How the JSON normalizer works inside; the public way in is
 * tnt_json_normalize() in mp_json.h. Nothing outside this module may ask
 * whether bytes are normalized and branch on the answer: that is the defect
 * this design exists to remove, so a new includer is a design change, not a
 * convenience. The legitimate ones are mp_json.c, test/unit/mp_json.c
 * and src/lua/tnt_msgpuck.c.
 *
 * tnt_msgpuck.c is on that list for a single call. tnt_mp_snprint_json()
 * renders for external modules, which have no way to know whether their bytes
 * are in normal form, and it cannot fix them in place. So it asks, and then
 * refuses to render; it never takes a second route to accepting the value.
 *
 * The normal form is one rule, not a list:
 *
 *   Every element is written in the shortest MessagePack encoding of its
 *   value. Object keys ascend strictly by (length, bytes). Number kinds are
 *   never folded into one another.
 *
 * "Shortest" means whatever mp_encode_*() produces, and the check is "the
 * header takes mp_sizeof_*() bytes", so the rule cannot drift away from the
 * encoder.
 */

/**
 * Classify the value at @a data in a single read-only pass. Every decode is
 * bounds-checked, so it is safe to pass bytes from anywhere.
 *
 * @param data the inner value, without the MP_EXT header; exactly @a len
 *        bytes must be consumed.
 * @param[out] err_off offset of the innermost offending value, or NULL. It
 *         goes into error messages.
 */
enum json_norm_status
json_verify(const char *data, uint32_t len, uint32_t *err_off);

/**
 * True if the value at @a data is already in normal form. Tested against the
 * rewriter in both directions: this holds exactly when
 * json_normalize_rewrite(x) reproduces x byte for byte.
 */
static inline bool
json_is_normalized(const char *data, uint32_t len)
{
	return json_verify(data, len, NULL) == JSON_NORM_OK;
}

/**
 * Rewrite a JSON value into normal form. Needs a JSON_NORM_REWRITABLE answer
 * from json_verify() first; given that promise, this walk needs no bounds
 * checks on the read side.
 *
 * The write side is checked in every build. Output never grows, so @a len
 * bytes are always enough, but @a out_end is respected anyway: if that ever
 * stopped being true, the result should be a failed call and not a heap
 * overflow.
 *
 * Sets no diag and does not touch the fiber or the region: callable from a
 * vinyl reader thread.
 *
 * @return past the last byte written, or NULL if the output does not fit.
 */
char *
json_normalize_rewrite(const char *data, uint32_t len, char *out,
		       char *out_end);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
