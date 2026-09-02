#pragma once
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

/**
 * This header contains a list of functions used to work with
 * additional data types (defined in tarantool) in the msgpack
 * format. Intended for use in tests to avoid copy-pasting
 * function declarations.
 */

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

#include "mp_datetime.h"
#include "mp_decimal.h"
#include "box/mp_error.h"
#include "mp_uuid.h"

struct interval;

char *
tnt_mp_encode_decimal(char *data, const decimal_t *dec);

uint32_t
tnt_mp_sizeof_decimal(const decimal_t *dec);

char *
tnt_mp_encode_uuid(char *data, const struct tt_uuid *uuid);

uint32_t
tnt_mp_sizeof_uuid(void);

char *
tnt_mp_encode_error(char *data, const struct error *error);

uint32_t
tnt_mp_sizeof_error(const struct error *error);

char *
tnt_mp_encode_datetime(char *data, const struct datetime *date);

uint32_t
tnt_mp_sizeof_datetime(const struct datetime *date);

/** Wrapper around mp_encode_interval(). */
char *
tnt_mp_encode_interval(char *data, const struct interval *itv);

/** Wrapper around mp_sizeof_interval(). */
uint32_t
tnt_mp_sizeof_interval(const struct interval *itv);

/** Wrapper around mp_encode_json(). */
char *
tnt_mp_encode_json(char *data, const char *value, uint32_t value_len);

/** Wrapper around mp_sizeof_json(). */
uint32_t
tnt_mp_sizeof_json(uint32_t data_len);

/**
 * Normal-form verdict on a JSON inner value of @a len bytes, as a flat int
 * because an FFI cdef cannot spell enum json_norm_status: 0 OK, 1 REWRITABLE,
 * 2 INVALID. The caller needs the two failures apart to say which mistake its
 * producer made. @a err_off is optional.
 */
int
tnt_mp_verify_json(const char *data, uint32_t len, uint32_t *err_off);

/** Wrapper around mp_snprint_json(). Refuses a non-normalized payload. */
int
tnt_mp_snprint_json(char *buf, int size, const char **data, uint32_t len);

/**
 * Wrapper around mp_compare_json(): compare two JSON inner values the way
 * storage and SQL do. Both must be in normal form, as for box_insert(); this
 * does not check it.
 *
 * @return <0, 0 or >0 as @a a is less than, equal to or greater than @a b.
 */
int
tnt_mp_compare_json(const char *a, uint32_t a_len, const char *b,
		    uint32_t b_len);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
