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
#include <stdint.h>
#include <stdio.h>

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

/**
 * The SQL JSON type: an MP_EXT with subtype MP_JSON wrapping a single
 * normalized plain MessagePack value (the "inner value"). Single source of
 * truth for the format: envelope codec, validator, normalizer, JSONB
 * comparator and renderer. No SQL or box dependencies.
 */

/** Maximum JSON nesting depth. Matches MongoDB's limit. */
#define JSON_MAX_NESTING_DEPTH 100

/**
 * A JSON value known to be in normal form: the inner value, without the
 * MP_EXT/MP_JSON header, and its length.
 *
 * It comes from tnt_json_normalize() or tnt_json_parse(), or from
 * json_norm_from_trusted() at a place whose comment says why it is sure.
 * Everything that needs normal form takes this type, and a const char * does
 * not convert to it on its own, so raw bytes cannot slip in by accident. It
 * stops mistakes, not determination: aggregate initialization still
 * compiles.
 */
struct json_norm {
	/** The inner value, with the MP_EXT/MP_JSON header stripped. */
	const char *data;
	/** Its length in bytes. */
	uint32_t len;
};

/**
 * Wrap bytes that are in normal form for a reason the caller knows and the
 * compiler cannot see. Every call site MUST say why in a comment, normally by
 * pointing into doc/json-perimeter.md: this and aggregate initialization are
 * the only two ways to claim JSON bytes are fine without proving it, so they
 * are the only two places to audit.
 */
struct json_norm
json_norm_from_trusted(const char *data, uint32_t len);

/**
 * Size of the MP_EXT/MP_JSON envelope around an inner value of @a len bytes.
 * Takes a length rather than a json_norm for the two callers that need the
 * size before they hold the value: the Lua encoder sizes its mpstream
 * reservation before normalizing into it, and the FFI shim gets a length
 * across a cdef that cannot spell a struct.
 */
uint32_t
mp_sizeof_json_len(uint32_t len);

/** Size of the MP_EXT/MP_JSON envelope around @a value. */
uint32_t
mp_sizeof_json(struct json_norm value);

/**
 * Encode the MP_EXT/MP_JSON envelope around @a value into @a data.
 * @return @a data + mp_sizeof_json(@a value).
 */
char *
mp_encode_json(char *data, struct json_norm value);

/**
 * Decode the MP_EXT/MP_JSON envelope.
 * @param data advanced past the whole MP_EXT value on success, untouched
 *        otherwise.
 * @return the inner value (plain MessagePack) and its @a len, or NULL if
 *         @a data is not an MP_EXT/MP_JSON value.
 */
const char *
mp_decode_json(const char **data, uint32_t *len);

/**
 * Normal-form verdict on a candidate JSON value, or on a MessagePack range
 * holding any number of them. Shared by the value walk in mp_json_norm.h and
 * by mp_verify_json() below.
 */
enum json_norm_status {
	/** Byte-for-byte what this build would emit. */
	JSON_NORM_OK = 0,
	/**
	 * A JSON value written the wrong way: a header longer than it needs
	 * to be, unsorted or duplicate object keys, or a non-negative MP_INT.
	 *
	 * This answer is a promise to the rewriter, which does no bounds
	 * checking of its own: well formed within its length, allowed kinds
	 * only, within JSON_MAX_NESTING_DEPTH, string-only object keys, and
	 * exactly len bytes long.
	 */
	JSON_NORM_REWRITABLE,
	/**
	 * Not a JSON value: malformed, truncated, a disallowed kind, or a
	 * string or key that is not valid UTF-8.
	 */
	JSON_NORM_INVALID,
};

/**
 * Whether [@a str, @a str + @a len) is valid UTF-8 as RFC 3629 defines it:
 * no stray continuation bytes, no sequences cut short, no overlong forms, no
 * surrogates and nothing above U+10FFFF. RFC 8259 requires JSON text to be
 * UTF-8, so every string and key in a JSON value must pass this.
 */
bool
json_utf8_is_valid(const char *str, uint32_t len);

/**
 * Normalize an untrusted MessagePack value into JSON normal form.
 *
 * Bounds-checked on both sides, so it is safe to pass bytes from anywhere.
 * Anything that is not JSON is refused rather than copied through, so this one
 * call is both the rewrite and the check. Output never grows, so @a len bytes
 * are always enough.
 *
 * @param[out] err_off offset of the innermost offending value, or NULL.
 * @return past the last byte written, or NULL. Sets no diag: callable from a
 *         vinyl reader thread.
 */
char *
tnt_json_normalize(const char *data, uint32_t len, char *out, char *out_end,
		   uint32_t *err_off);

/**
 * Verify every MP_JSON value in [@a data, @a end), at any depth and position,
 * including the fields of an MP_ERROR. Bounds-checked throughout, and a full
 * MessagePack well-formedness check of the range as a side effect, which is
 * what lets callers drop the mp_check() that used to precede it.
 *
 * There are two separate depth limits here, and merging them would be wrong.
 * This walk is bounded by an element counter and by no depth limit at all,
 * exactly like mp_check(), so a tuple may nest as deep as it likes.
 * JSON_MAX_NESTING_DEPTH applies only inside an MP_JSON payload.
 *
 * @param[out] errpos offset of the first offending value, or NULL.
 * @return JSON_NORM_OK when no JSON is present, or all of it is normalized.
 */
enum json_norm_status
mp_verify_json(const char *data, const char *end, uint32_t *errpos);

struct region;

/**
 * Compare two MP_EXT/MP_JSON values using PostgreSQL JSONB ordering:
 * null < string < number < bool < array < object. Strings compare bytewise,
 * then by length once a shared prefix ties; numbers by value across
 * representations; arrays by element count first, then element by element;
 * objects by size, then sorted keys, then values.
 *
 * Needs no error channel: taking json_norm makes it structurally unreachable
 * from unparsed bytes. It asserts its depth bound rather than rejecting, and
 * compares object keys positionally, both safe exactly because the type says
 * the keys are sorted and the depth is bounded.
 *
 * @return <0, 0 or >0 if @a a is less than, equal to or greater than @a b.
 */
int
mp_compare_json(struct json_norm a, struct json_norm b);

#ifndef NDEBUG
/**
 * Whether bytes that some caller is trusting really are in normal form. Not
 * present in release builds, on purpose: inside the cluster this is settled
 * once on the way in and never worked out again. Meant for use inside
 * assert(), so it must never be called for its side effects.
 */
bool
tnt_json_is_normalized(const char *data, uint32_t len);
#endif /* NDEBUG */

/**
 * Print a JSON inner value's canonical text into a buffer.
 *
 * It accepts bytes from anywhere: every decode is bounded by @a len. That
 * matters because it is installed as the global print hook, where nothing can
 * vet the input first, and because request_str() calls it with exactly the
 * payload a check has just refused.
 *
 * @param data the inner value, without the MP_EXT header.
 * @retval >=0 bytes written, or that would have been.
 * @retval <0  the value could not be decoded.
 */
int
mp_snprint_json(char *buf, int size, const char **data, uint32_t len);

/**
 * Print a JSON inner value's canonical text into a stream. Accepts bytes from
 * anywhere, on the same terms as mp_snprint_json().
 *
 * @retval >=0 bytes written.
 * @retval <0  the value could not be decoded or written.
 */
int
mp_fprint_json(FILE *file, const char **data, uint32_t len);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
