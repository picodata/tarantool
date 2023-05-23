/**
 * PostgreSQL Database Management System
 * (formerly known as Postgres, then as Postgres95)
 *
 * Portions Copyright (c) 1996-2023, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without a written agreement
 * is hereby granted, provided that the above copyright notice and this
 * paragraph and the following two paragraphs appear in all copies.
 *
 * IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING
 * LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS
 * DOCUMENTATION, EVEN IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 * THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
 * ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATIONS TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>

/** Type of cryptohash context. It is used by cryptohash_create. */
enum cryptohash_type {
	/** Context for MD5 algorithm. */
	CRYPTOHASH_MD5 = 0,
};

struct cryptohash_ctx;

/* Allocate a cryptohash context. Never fails. */
struct cryptohash_ctx *
cryptohash_create(enum cryptohash_type type);

/** Initialize a cryptohash context. Never fails. */
void
cryptohash_init(struct cryptohash_ctx *ctx);

/** Update a cryptohash context. Never fails. */
void
cryptohash_update(struct cryptohash_ctx *ctx, const uint8_t *data, size_t len);

/** Finalize a cryptohash context. Never fails. */
void
cryptohash_final(struct cryptohash_ctx *ctx, uint8_t *dest, size_t len);

/** Free cryptohash context resources. */
void
cryptohash_free(struct cryptohash_ctx *ctx);
