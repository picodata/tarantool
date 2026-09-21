/*
 * Copyright 2010-2021, Tarantool AUTHORS, please see AUTHORS file.
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

#include <assert.h>

#include "msgpuck.h"
#include "tnt_msgpuck.h"
#include "mp_interval.h"
#include "mp_json.h"
#include "mp_json_norm.h"

char *
tnt_mp_encode_float(char *data, float num)
{
	return mp_encode_float(data, num);
}

char *
tnt_mp_encode_double(char *data, double num)
{
	return mp_encode_double(data, num);
}

float
tnt_mp_decode_float(const char **data)
{
	return mp_decode_float(data);
}

double
tnt_mp_decode_double(const char **data)
{
	return mp_decode_double(data);
}

uint32_t
tnt_mp_decode_extl(const char **data, int8_t *type)
{
	return mp_decode_extl(data, type);
}

char *
tnt_mp_encode_decimal(char *data, const decimal_t *dec)
{
	return mp_encode_decimal(data, dec);
}

uint32_t
tnt_mp_sizeof_decimal(const decimal_t *dec)
{
	return mp_sizeof_decimal(dec);
}

char *
tnt_mp_encode_uuid(char *data, const struct tt_uuid *uuid)
{
	return mp_encode_uuid(data, uuid);
}

uint32_t
tnt_mp_sizeof_uuid(void)
{
	return mp_sizeof_uuid();
}

char *
tnt_mp_encode_error(char *data, const struct error *error)
{
	return mp_encode_error(data, error);
}

uint32_t
tnt_mp_sizeof_error(const struct error *error)
{
	return mp_sizeof_error(error);
}

char *
tnt_mp_encode_datetime(char *data, const struct datetime *date)
{
	return mp_encode_datetime(data, date);
}

uint32_t
tnt_mp_sizeof_datetime(const struct datetime *date)
{
	return mp_sizeof_datetime(date);
}

char *
tnt_mp_encode_interval(char *data, const struct interval *itv)
{
	return mp_encode_interval(data, itv);
}

uint32_t
tnt_mp_sizeof_interval(const struct interval *itv)
{
	return mp_sizeof_interval(itv);
}

char *
tnt_mp_encode_json(char *data, const char *value, uint32_t value_len)
{
	/*
	 * The only Lua caller has just checked these bytes, see
	 * doc/json-perimeter.md#lua-ffi-encoder. The signature stays flat
	 * because an FFI cdef cannot spell struct json_norm.
	 */
	assert(json_is_normalized(value, value_len));
	return mp_encode_json(data, json_norm_from_trusted(value, value_len));
}

uint32_t
tnt_mp_sizeof_json(uint32_t data_len)
{
	return mp_sizeof_json_len(data_len);
}

int
tnt_mp_verify_json(const char *data, uint32_t len, uint32_t *err_off)
{
	return (int)json_verify(data, len, err_off);
}

int
tnt_mp_snprint_json(char *buf, int size, const char **data, uint32_t len)
{
	/* JSON is taken as is, see doc/json-perimeter.md#external-renderer. */
	assert(json_is_normalized(*data, len));
	return mp_snprint_json(buf, size, data, len);
}

int
tnt_mp_compare_json(const char *a, uint32_t a_len, const char *b,
		    uint32_t b_len)
{
	/*
	 * JSON is taken as is, see
	 * doc/json-perimeter.md#external-comparator.
	 */
	assert(json_is_normalized(a, a_len));
	assert(json_is_normalized(b, b_len));
	return mp_compare_json(json_norm_from_trusted(a, a_len),
			       json_norm_from_trusted(b, b_len));
}
