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

#include "mp_json_norm.h"

#include "mp_json.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "mp_decimal.h"
#include "mp_extension_types.h"
#include "msgpuck.h"
#include "trivia/util.h"

/** What json_verify_element() found at the cursor. */
enum json_element_kind {
	/** A scalar, already consumed. */
	JSON_ELEMENT_SCALAR,
	/** An array header, consumed; its elements are the caller's job. */
	JSON_ELEMENT_ARRAY,
	/** A map header, consumed; its pairs are the caller's job. */
	JSON_ELEMENT_MAP,
	/** Not a JSON value. Fatal: the walk stops. */
	JSON_ELEMENT_INVALID,
};

bool
json_utf8_is_valid(const char *str, uint32_t len)
{
	const uint8_t *p = (const uint8_t *)str;
	const uint8_t *end = p + len;
	while (p < end) {
		/* Most text is ASCII, so skip it a word at a time. */
		while (end - p >= 8) {
			uint64_t word;
			memcpy(&word, p, sizeof(word));
			if ((word & 0x8080808080808080ULL) != 0)
				break;
			p += 8;
		}
		if (p == end)
			break;
		uint8_t c = *p;
		if (c < 0x80) {
			p++;
			continue;
		}
		/*
		 * How many continuation bytes follow, and the range the first
		 * of them must fall in, which is what rules out overlong
		 * forms, surrogates and code points above U+10FFFF.
		 */
		uint32_t n;
		uint8_t lo = 0x80, hi = 0xbf;
		if (c >= 0xc2 && c <= 0xdf) {
			n = 1;
		} else if (c >= 0xe0 && c <= 0xef) {
			n = 2;
			if (c == 0xe0)
				lo = 0xa0;
			else if (c == 0xed)
				hi = 0x9f;
		} else if (c >= 0xf0 && c <= 0xf4) {
			n = 3;
			if (c == 0xf0)
				lo = 0x90;
			else if (c == 0xf4)
				hi = 0x8f;
		} else {
			return false;
		}
		if ((size_t)(end - p) <= n)
			return false;
		if (p[1] < lo || p[1] > hi)
			return false;
		for (uint32_t i = 2; i <= n; i++) {
			if ((p[i] & 0xc0) != 0x80)
				return false;
		}
		p += n + 1;
	}
	return true;
}

/**
 * Verify the MP_STR at *@a data and skip it, setting @a body (unless NULL)
 * and @a len. The bytes must be valid UTF-8.
 *
 * A non-minimal header is reported through @a minimal rather than failed, so
 * the caller can classify the value as rewritable and keep walking. Strings
 * are re-emitted minimally like every other element; copying them verbatim
 * would let two spellings of one document reach storage.
 */
static int
json_verify_str(const char **data, const char *end, const char **body,
		uint32_t *len, bool *minimal)
{
	if (mp_check_strl(*data, end) > 0)
		return -1;
	const char *start = *data;
	uint32_t n = mp_decode_strl(data);
	*minimal = *data - start == (ptrdiff_t)mp_sizeof_strl(n);
	if ((size_t)(end - *data) < (size_t)n)
		return -1;
	if (!json_utf8_is_valid(*data, n))
		return -1;
	if (body != NULL)
		*body = *data;
	*data += n;
	*len = n;
	return 0;
}

/**
 * Verify one non-key element at *@a data and skip it, or, for a container,
 * its header alone, reporting the element count in @a count. The elements are
 * left to the caller's explicit stack: recursion here would put the input in
 * charge of the C stack depth, and this is reached from a vinyl reader thread.
 *
 * @a minimal is false for a legal JSON value spelled non-normalized;
 * JSON_ELEMENT_INVALID means no rewrite can help.
 */
static enum json_element_kind
json_verify_element(const char **data, const char *end, uint32_t *count,
		    bool *minimal)
{
	if (*data >= end)
		return JSON_ELEMENT_INVALID;
	const char *p = *data;
	const char *start = p;
	switch (mp_typeof(*p)) {
	case MP_NIL:
		if (mp_check_nil(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		mp_decode_nil(&p);
		break;
	case MP_BOOL:
		if (mp_check_bool(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		mp_decode_bool(&p);
		break;
	case MP_UINT: {
		if (mp_check_uint(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		uint64_t v = mp_decode_uint(&p);
		if (p - start != (ptrdiff_t)mp_sizeof_uint(v))
			*minimal = false;
		break;
	}
	case MP_INT: {
		if (mp_check_int(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		int64_t v = mp_decode_int(&p);
		/*
		 * A non-negative value under an MP_INT marker is legal but
		 * not normalized: MP_UINT is the normalized integer
		 * encoding. Check the sign before mp_sizeof_int(), which
		 * asserts a negative argument.
		 */
		if (v >= 0 || p - start != (ptrdiff_t)mp_sizeof_int(v))
			*minimal = false;
		break;
	}
	case MP_DOUBLE:
		/* Number kinds are never folded, so 0xcb is always minimal. */
		if (mp_check_double(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		if (!isfinite(mp_decode_double(&p)))
			return JSON_ELEMENT_INVALID;
		break;
	case MP_STR: {
		uint32_t n;
		bool str_minimal;
		if (json_verify_str(&p, end, NULL, &n, &str_minimal) != 0)
			return JSON_ELEMENT_INVALID;
		if (!str_minimal)
			*minimal = false;
		break;
	}
	case MP_EXT: {
		/*
		 * 0xc1 is "never used", yet mp_type_hint maps it to MP_EXT and
		 * mp_check_extl() aborts on it. This walk deliberately avoids
		 * mp_check(), whose extension hook would re-enter for a nested
		 * MP_JSON, so rule 0xc1 out here.
		 */
		if ((uint8_t)*p == 0xc1 || mp_check_extl(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		int8_t ext_type;
		uint32_t ext_len = mp_decode_extl(&p, &ext_type);
		if (ext_type != MP_DECIMAL)
			return JSON_ELEMENT_INVALID;
		if ((size_t)(end - p) < (size_t)ext_len)
			return JSON_ELEMENT_INVALID;
		/*
		 * Encodable under ext8/16/32 and reachable from the wire, but
		 * an extension must carry at least one byte: decimal_unpack()
		 * asserts on an empty payload and would read past the buffer
		 * without that assertion.
		 */
		if (ext_len == 0)
			return JSON_ELEMENT_INVALID;
		if (mp_validate_decimal(p, ext_len) != 0)
			return JSON_ELEMENT_INVALID;
		/*
		 * The header, not the payload: the payload keeps its scale,
		 * because number kinds and written forms are preserved.
		 */
		if (p - start != (ptrdiff_t)mp_sizeof_extl(ext_len))
			*minimal = false;
		p += ext_len;
		break;
	}
	case MP_ARRAY: {
		if (mp_check_array(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		uint32_t n = mp_decode_array(&p);
		if (p - start != (ptrdiff_t)mp_sizeof_array(n))
			*minimal = false;
		*data = p;
		*count = n;
		return JSON_ELEMENT_ARRAY;
	}
	case MP_MAP: {
		if (mp_check_map(p, end) > 0)
			return JSON_ELEMENT_INVALID;
		uint32_t n = mp_decode_map(&p);
		if (p - start != (ptrdiff_t)mp_sizeof_map(n))
			*minimal = false;
		*data = p;
		*count = n;
		return JSON_ELEMENT_MAP;
	}
	/* A 32-bit float is not a JSON number kind (see mp_json.h). */
	case MP_FLOAT:
	case MP_BIN:
	default:
		return JSON_ELEMENT_INVALID;
	}
	*data = p;
	return JSON_ELEMENT_SCALAR;
}

/**
 * One frame of the verifier's container stack. A map counts its key and its
 * value as two slots, so one counter serves both kinds.
 */
struct json_frame {
	/**
	 * Slots left in this container. 64 bits because a map's pair count is
	 * a uint32 and a slot count is twice that: an oversized count must not
	 * be able to wrap this counter.
	 */
	uint64_t remaining;
	/** Previous key body, NULL before this container's first key. */
	const char *prev_key;
	/** Its length. */
	uint32_t prev_key_len;
	/** True for a map, false for an array. */
	bool is_map;
	/** True when the next slot of a map is a key rather than a value. */
	bool want_key;
};

static int
json_key_compare(const char *a, uint32_t alen, const char *b, uint32_t blen)
{
	if (alen != blen)
		return alen < blen ? -1 : 1;
	return memcmp(a, b, alen);
}

enum json_norm_status
json_verify(const char *data, uint32_t len, uint32_t *err_off)
{
	const char *p = data;
	const char *end = data + len;
	bool minimal = true;
	const char *first_bad = NULL;
	/*
	 * Frame 0 is a synthetic one-slot array standing for the top-level
	 * value, so the loop needs no special case and an element read in
	 * frame t sits at depth t. The bound is therefore a test on the
	 * element about to be read, not on the container about to be pushed:
	 * 100 nested empty arrays are accepted, because no value ever sits at
	 * depth 100. Frame JSON_MAX_NESTING_DEPTH exists only to hold such a
	 * container, hence one stack slot more than the depth limit.
	 */
	struct json_frame stack[JSON_MAX_NESTING_DEPTH + 1];
	int top = 0;
	stack[0].remaining = 1;
	stack[0].prev_key = NULL;
	stack[0].prev_key_len = 0;
	stack[0].is_map = false;
	stack[0].want_key = false;

	while (top >= 0) {
		struct json_frame *frame = &stack[top];
		if (frame->remaining == 0) {
			top--;
			continue;
		}
		if (top >= JSON_MAX_NESTING_DEPTH) {
			/* This element would sit at depth >= the limit. */
			goto invalid;
		}
		frame->remaining--;
		const char *slot = p;
		if (frame->is_map && frame->want_key) {
			frame->want_key = false;
			if (p >= end || mp_typeof(*p) != MP_STR)
				goto invalid;
			const char *key;
			uint32_t key_len;
			bool key_minimal;
			if (json_verify_str(&p, end, &key, &key_len,
					    &key_minimal) != 0)
				goto invalid;
			if (!key_minimal && first_bad == NULL)
				first_bad = slot;
			minimal = minimal && key_minimal;
			/*
			 * Requiring each key to be strictly greater than the
			 * last catches both unsorted keys and duplicates in
			 * one comparison. Checking the order costs O(k) and
			 * producing it costs O(k log k), which is why the
			 * fast path checks instead of rewriting and
			 * comparing.
			 */
			if (frame->prev_key != NULL &&
			    json_key_compare(frame->prev_key,
					     frame->prev_key_len,
					     key, key_len) >= 0) {
				if (first_bad == NULL)
					first_bad = slot;
				minimal = false;
			}
			frame->prev_key = key;
			frame->prev_key_len = key_len;
			continue;
		}
		if (frame->is_map)
			frame->want_key = true;
		uint32_t count = 0;
		bool was_minimal = minimal;
		enum json_element_kind kind =
			json_verify_element(&p, end, &count, &minimal);
		if (was_minimal && !minimal && first_bad == NULL)
			first_bad = slot;
		if (kind == JSON_ELEMENT_SCALAR)
			continue;
		if (kind == JSON_ELEMENT_INVALID) {
			p = slot;
			goto invalid;
		}
		/* Always room: the depth test above rejects the last frame. */
		assert(top + 1 <= JSON_MAX_NESTING_DEPTH);
		bool is_map = kind == JSON_ELEMENT_MAP;
		frame = &stack[++top];
		frame->remaining = is_map ? (uint64_t)count * 2 : count;
		frame->prev_key = NULL;
		frame->prev_key_len = 0;
		frame->is_map = is_map;
		frame->want_key = is_map;
	}
	if (p != end)
		goto invalid;
	if (minimal)
		return JSON_NORM_OK;
	if (err_off != NULL)
		*err_off = (uint32_t)(first_bad - data);
	return JSON_NORM_REWRITABLE;
invalid:
	if (err_off != NULL)
		*err_off = (uint32_t)(p - data);
	return JSON_NORM_INVALID;
}

/** One object entry, as the key sort sees it. */
struct json_kv {
	/** Key body in the source MessagePack. */
	const char *key;
	/** Its length. */
	uint32_t key_len;
	/** Its value, likewise. */
	const char *value;
};

/** Stack capacity for small objects, avoiding a heap allocation. */
#define JSON_KV_STACK_SIZE 16

/** Fail unless @a n bytes are available at *@a out. */
#define JSON_RESERVE(out, out_end, n)					\
do {									\
	if ((size_t)((out_end) - *(out)) < (size_t)(n))			\
		return -1;						\
} while (0)

/**
 * Above this key count insertion sort's quadratic worst case outweighs its
 * constant factor and the merge sort takes over. Deliberately above
 * JSON_KV_STACK_SIZE, so an object large enough to need the merge already
 * owns the xmalloc'd buffer it borrows temporary space from: no allocation
 * site is added, which keeps the module callable from a vinyl reader thread.
 */
#define JSON_KV_SORT_MAX 32

/**
 * Merge two sorted runs of @a kvs into @a tmp and copy back, keeping equal
 * keys in their original relative order.
 */
static void
json_kv_merge(struct json_kv *kvs, uint32_t lo, uint32_t mid, uint32_t hi,
	      struct json_kv *tmp)
{
	uint32_t i = lo, j = mid, w = 0;
	while (i < mid && j < hi) {
		int cmp = json_key_compare(kvs[i].key, kvs[i].key_len,
					   kvs[j].key, kvs[j].key_len);
		/* <= takes from the left run on a tie: that is stable. */
		tmp[w++] = (cmp <= 0) ? kvs[i++] : kvs[j++];
	}
	while (i < mid)
		tmp[w++] = kvs[i++];
	while (j < hi)
		tmp[w++] = kvs[j++];
	memcpy(&kvs[lo], tmp, w * sizeof(*kvs));
}

/**
 * Sort @a kvs into normal key order, stably.
 *
 * Insertion sort below JSON_KV_SORT_MAX: input reaching the rewriter has
 * already failed verification, so it is usually near-sorted, where insertion
 * sort is O(k + inversions). The reverse-sorted case pays for that, and the
 * trade is deliberate: do not "fix" it by sorting everything.
 *
 * Above it, a bottom-up merge sort, stable and not qsort(): normalization is
 * last-wins on duplicate keys, so an unstable sort would make the survivor
 * implementation-defined, and two nodes on different libc builds would
 * normalize one document to two byte strings.
 *
 * @a tmp must hold @a count entries above JSON_KV_SORT_MAX, and may be NULL
 * below it.
 */
static void
json_kv_sort(struct json_kv *kvs, uint32_t count, struct json_kv *tmp)
{
	if (count > JSON_KV_SORT_MAX) {
		assert(tmp != NULL);
		for (uint32_t width = 1; width < count; width *= 2) {
			for (uint32_t lo = 0; lo + width < count;
			     lo += 2 * width) {
				uint32_t mid = lo + width;
				uint32_t hi = mid + width;
				if (hi > count)
					hi = count;
				json_kv_merge(kvs, lo, mid, hi, tmp);
			}
		}
		return;
	}
	for (uint32_t i = 1; i < count; i++) {
		struct json_kv held = kvs[i];
		uint32_t j = i;
		while (j > 0) {
			int cmp = json_key_compare(kvs[j - 1].key,
						   kvs[j - 1].key_len,
						   held.key, held.key_len);
			/* Equal keys keep their original order: last wins. */
			if (cmp <= 0)
				break;
			kvs[j] = kvs[j - 1];
			j--;
		}
		kvs[j] = held;
	}
}

/** Rewriting an object or an array recurses back through this. */
static int
json_rewrite_value(const char **data, char **out, char *out_end, int depth);

/**
 * Rewrite a JSON object: sort keys (length-first, then byte-by-byte), drop
 * duplicates keeping the last occurrence, then rewrite the surviving values.
 *
 * The xmalloc above JSON_KV_STACK_SIZE keys cannot move to the fiber region,
 * because this is callable from a vinyl reader thread, and the rewriter is
 * off the hot path anyway: tnt_json_normalize() verifies first.
 */
static int
json_rewrite_map(const char **data, char **out, char *out_end, int depth)
{
	uint32_t count = mp_decode_map(data);
	if (count == 0) {
		JSON_RESERVE(out, out_end, mp_sizeof_map(0));
		*out = mp_encode_map(*out, 0);
		return 0;
	}
	struct json_kv stack_kvs[JSON_KV_STACK_SIZE];
	struct json_kv *kvs = stack_kvs;
	struct json_kv *tmp = NULL;
	if (count > JSON_KV_STACK_SIZE) {
		/*
		 * One allocation for both: the entries, then the merge
		 * buffer. JSON_KV_SORT_MAX > JSON_KV_STACK_SIZE, so the
		 * merge never runs without this buffer.
		 */
		kvs = xmalloc(2 * count * sizeof(*kvs));
		tmp = kvs + count;
	}
	int rc = -1;

	for (uint32_t i = 0; i < count; i++) {
		/* json_verify() has established that every key is an MP_STR. */
		assert(mp_typeof(**data) == MP_STR);
		kvs[i].key = mp_decode_str(data, &kvs[i].key_len);
		kvs[i].value = *data;
		mp_next(data);
	}
	json_kv_sort(kvs, count, tmp);

	/* Keep the last occurrence of each key (PostgreSQL "last wins"). */
	uint32_t w = 0;
	for (uint32_t i = 0; i < count; i++) {
		if (i + 1 < count &&
		    json_key_compare(kvs[i].key, kvs[i].key_len,
				     kvs[i + 1].key, kvs[i + 1].key_len) == 0)
			continue;
		kvs[w++] = kvs[i];
	}

	if ((size_t)(out_end - *out) < (size_t)mp_sizeof_map(w))
		goto out;
	*out = mp_encode_map(*out, w);
	for (uint32_t i = 0; i < w; i++) {
		if ((size_t)(out_end - *out) <
		    (size_t)mp_sizeof_str(kvs[i].key_len))
			goto out;
		*out = mp_encode_str(*out, kvs[i].key, kvs[i].key_len);
		const char *value = kvs[i].value;
		if (json_rewrite_value(&value, out, out_end, depth + 1) != 0)
			goto out;
	}
	rc = 0;
out:
	if (kvs != stack_kvs)
		free(kvs);
	return rc;
}

/** The rewrite itself; json_rewrite_value() wraps it with the assert. */
static int
json_rewrite_value_impl(const char **data, char **out, char *out_end, int depth)
{
	assert(depth < JSON_MAX_NESTING_DEPTH);
	switch (mp_typeof(**data)) {
	case MP_UINT: {
		uint64_t v = mp_decode_uint(data);
		JSON_RESERVE(out, out_end, mp_sizeof_uint(v));
		*out = mp_encode_uint(*out, v);
		return 0;
	}
	case MP_INT: {
		/*
		 * A non-negative value may arrive under an MP_INT marker.
		 * Rewrite it as MP_UINT: mp_encode_int() asserts num < 0.
		 */
		int64_t v = mp_decode_int(data);
		if (v < 0) {
			JSON_RESERVE(out, out_end, mp_sizeof_int(v));
			*out = mp_encode_int(*out, v);
		} else {
			JSON_RESERVE(out, out_end,
				     mp_sizeof_uint((uint64_t)v));
			*out = mp_encode_uint(*out, (uint64_t)v);
		}
		return 0;
	}
	case MP_STR: {
		uint32_t n;
		const char *body = mp_decode_str(data, &n);
		JSON_RESERVE(out, out_end, mp_sizeof_str(n));
		*out = mp_encode_str(*out, body, n);
		return 0;
	}
	case MP_EXT: {
		int8_t ext_type;
		uint32_t n = mp_decode_extl(data, &ext_type);
		assert(ext_type == MP_DECIMAL);
		JSON_RESERVE(out, out_end, mp_sizeof_ext(n));
		*out = mp_encode_ext(*out, ext_type, *data, n);
		*data += n;
		return 0;
	}
	case MP_ARRAY: {
		uint32_t n = mp_decode_array(data);
		JSON_RESERVE(out, out_end, mp_sizeof_array(n));
		*out = mp_encode_array(*out, n);
		for (uint32_t i = 0; i < n; i++) {
			if (json_rewrite_value(data, out, out_end,
					       depth + 1) != 0)
				return -1;
		}
		return 0;
	}
	case MP_MAP:
		return json_rewrite_map(data, out, out_end, depth);
	case MP_NIL:
	case MP_BOOL:
	case MP_DOUBLE: {
		/* One encoding each, so a verbatim copy is normalized. */
		const char *start = *data;
		mp_next(data);
		JSON_RESERVE(out, out_end, *data - start);
		memcpy(*out, start, *data - start);
		*out += *data - start;
		return 0;
	}
	default:
		/*
		 * Unreachable on the JSON_NORM_REWRITABLE promise. An error
		 * rather than unreachable(): a caller that breaks the contract
		 * must get a failure back, not undefined behaviour.
		 */
		return -1;
	}
}

static int
json_rewrite_value(const char **data, char **out, char *out_end, int depth)
{
	const char *in_start = *data;
	char *out_start = *out;
	int rc = json_rewrite_value_impl(data, out, out_end, depth);
	/*
	 * Output never grows. That is checked for each element rather than
	 * once at the top, so when it does not hold, the failure points at the
	 * rule that broke it, and a rule added later is covered the moment it
	 * is written. JSON_RESERVE is what does the checking in a release
	 * build.
	 */
	assert(rc != 0 || *out - out_start <= *data - in_start);
	(void)in_start;
	(void)out_start;
	return rc;
}

char *
json_normalize_rewrite(const char *data, uint32_t len, char *out,
		       char *out_end)
{
	const char *p = data;
	char *o = out;
	if (json_rewrite_value(&p, &o, out_end, 0) != 0)
		return NULL;
	/* The other half of the contract: exact input consumption. */
	assert(p == data + len);
	(void)len;
	(void)p;
	return o;
}
