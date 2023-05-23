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
#include "cryptohash.h"
#include "md5.h"

#include "trivia/util.h"

/**
 * Internal cryptohash_ctx structure.
 * It may seem overcomplicated since only one method is supported at the moment,
 * but more methods are planned to be added, for instance, SHA-256.
 */
struct cryptohash_ctx {
	/* which algorithm to use */
	enum cryptohash_type type;

	/* algorithm context, depending on the type field */
	union {
		/* md5 context */
		struct md5_ctx md5;
	} data;
};

struct cryptohash_ctx *
cryptohash_create(enum cryptohash_type type)
{
	/*
	 * Note that this always allocates enough space for the largest hash.
	 * The small extra amount of memory does not make it worth complicating
	 * this code.
	 */
	struct cryptohash_ctx *ctx = xcalloc(1, sizeof(*ctx));
	ctx->type = type;
	return ctx;
}

void
cryptohash_init(struct cryptohash_ctx *ctx)
{
	switch (ctx->type) {
	case CRYPTOHASH_MD5:
		md5_init(&ctx->data.md5);
		break;
	default:
		unreachable();
	}
}

void
cryptohash_update(struct cryptohash_ctx *ctx, const uint8_t *data, size_t len)
{
	switch (ctx->type) {
	case CRYPTOHASH_MD5:
		md5_update(&ctx->data.md5, data, len);
		break;
	default:
		unreachable();
	}
}

void
cryptohash_final(struct cryptohash_ctx *ctx, uint8_t *dest, size_t len)
{
	(void)len;
	switch (ctx->type) {
	case CRYPTOHASH_MD5:
		assert(len >= MD5_DIGEST_LENGTH);
		md5_final(&ctx->data.md5, dest);
		break;
	default:
		unreachable();
	}
}

void
cryptohash_free(struct cryptohash_ctx *ctx)
{
	if (ctx == NULL)
		return;

	TRASH(ctx);
	free(ctx);
}
