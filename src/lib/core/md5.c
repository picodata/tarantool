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
#include "md5.h"

#include "trivia/util.h"

#define md5_n    md5_count.md5_count64
#define md5_n8   md5_count.md5_count8
#define md5_sta  md5_st.md5_state32[0]
#define md5_stb  md5_st.md5_state32[1]
#define md5_stc  md5_st.md5_state32[2]
#define md5_std  md5_st.md5_state32[3]
#define md5_st8  md5_st.md5_state8

#define SHIFT(X, s) (((X) << (s)) | ((X) >> (32 - (s))))

#define F(X, Y, Z) (((X) & (Y)) | ((~X) & (Z)))
#define G(X, Y, Z) (((X) & (Z)) | ((Y) & (~(Z))))
#define H(X, Y, Z) ((X) ^ (Y) ^ (Z))
#define I(X, Y, Z) ((Y) ^ ((X) | (~(Z))))

#define ROUND1(a, b, c, d, k, s, i) \
do { \
	(a) = (a) + F((b), (c), (d)) + X[(k)] + T[(i)]; \
	(a) = SHIFT((a), (s)); \
	(a) = (a) + (b); \
} while (0)

#define ROUND2(a, b, c, d, k, s, i) \
do { \
	(a) = (a) + G((b), (c), (d)); \
	(a) = (a) + X[(k)]; \
	(a) = (a) + T[(i)]; \
	(a) = SHIFT((a), (s)); \
	(a) = (a) + (b); \
} while (0)

#define ROUND3(a, b, c, d, k, s, i) \
do { \
	(a) = (a) + H((b), (c), (d)); \
	(a) = (a) + X[(k)]; \
	(a) = (a) + T[(i)]; \
	(a) = SHIFT((a), (s)); \
	(a) = (a) + (b); \
} while (0)

#define ROUND4(a, b, c, d, k, s, i) \
do { \
	(a) = (a) + I((b), (c), (d)); \
	(a) = (a) + X[(k)]; \
	(a) = (a) + T[(i)]; \
	(a) = SHIFT((a), (s)); \
	(a) = (a) + (b); \
} while (0)

#define Sa	 7
#define Sb	12
#define Sc	17
#define Sd	22

#define Se	 5
#define Sf	 9
#define Sg	14
#define Sh	20

#define Si	 4
#define Sj	11
#define Sk	16
#define Sl	23

#define Sm	 6
#define Sn	10
#define So	15
#define Sp	21

#define MD5_A0	0x67452301
#define MD5_B0	0xefcdab89
#define MD5_C0	0x98badcfe
#define MD5_D0	0x10325476

/* Integer part of 4294967296 times abs(sin(i)), where i is in radians. */
static const uint32_t T[65] = {
	0,
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
	0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
	0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,

	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
	0xd62f105d, 0x2441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
	0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,

	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
	0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x4881d05,
	0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,

	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
	0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
	0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

static const uint8_t md5_paddat[MD5_BUFLEN] = {
	0x80, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
};

static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
	      "md5 hash calculation only supports little endian architecture");

/** Calculate a single md5 hash interation. */
static void
md5_calc(const uint8_t *b64, struct md5_ctx *ctx)
{
	uint32_t A = ctx->md5_sta;
	uint32_t B = ctx->md5_stb;
	uint32_t C = ctx->md5_stc;
	uint32_t D = ctx->md5_std;

	const uint32_t *X = (const uint32_t *)b64;
	ROUND1(A, B, C, D, 0, Sa, 1);
	ROUND1(D, A, B, C, 1, Sb, 2);
	ROUND1(C, D, A, B, 2, Sc, 3);
	ROUND1(B, C, D, A, 3, Sd, 4);
	ROUND1(A, B, C, D, 4, Sa, 5);
	ROUND1(D, A, B, C, 5, Sb, 6);
	ROUND1(C, D, A, B, 6, Sc, 7);
	ROUND1(B, C, D, A, 7, Sd, 8);
	ROUND1(A, B, C, D, 8, Sa, 9);
	ROUND1(D, A, B, C, 9, Sb, 10);
	ROUND1(C, D, A, B, 10, Sc, 11);
	ROUND1(B, C, D, A, 11, Sd, 12);
	ROUND1(A, B, C, D, 12, Sa, 13);
	ROUND1(D, A, B, C, 13, Sb, 14);
	ROUND1(C, D, A, B, 14, Sc, 15);
	ROUND1(B, C, D, A, 15, Sd, 16);

	ROUND2(A, B, C, D, 1, Se, 17);
	ROUND2(D, A, B, C, 6, Sf, 18);
	ROUND2(C, D, A, B, 11, Sg, 19);
	ROUND2(B, C, D, A, 0, Sh, 20);
	ROUND2(A, B, C, D, 5, Se, 21);
	ROUND2(D, A, B, C, 10, Sf, 22);
	ROUND2(C, D, A, B, 15, Sg, 23);
	ROUND2(B, C, D, A, 4, Sh, 24);
	ROUND2(A, B, C, D, 9, Se, 25);
	ROUND2(D, A, B, C, 14, Sf, 26);
	ROUND2(C, D, A, B, 3, Sg, 27);
	ROUND2(B, C, D, A, 8, Sh, 28);
	ROUND2(A, B, C, D, 13, Se, 29);
	ROUND2(D, A, B, C, 2, Sf, 30);
	ROUND2(C, D, A, B, 7, Sg, 31);
	ROUND2(B, C, D, A, 12, Sh, 32);

	ROUND3(A, B, C, D, 5, Si, 33);
	ROUND3(D, A, B, C, 8, Sj, 34);
	ROUND3(C, D, A, B, 11, Sk, 35);
	ROUND3(B, C, D, A, 14, Sl, 36);
	ROUND3(A, B, C, D, 1, Si, 37);
	ROUND3(D, A, B, C, 4, Sj, 38);
	ROUND3(C, D, A, B, 7, Sk, 39);
	ROUND3(B, C, D, A, 10, Sl, 40);
	ROUND3(A, B, C, D, 13, Si, 41);
	ROUND3(D, A, B, C, 0, Sj, 42);
	ROUND3(C, D, A, B, 3, Sk, 43);
	ROUND3(B, C, D, A, 6, Sl, 44);
	ROUND3(A, B, C, D, 9, Si, 45);
	ROUND3(D, A, B, C, 12, Sj, 46);
	ROUND3(C, D, A, B, 15, Sk, 47);
	ROUND3(B, C, D, A, 2, Sl, 48);

	ROUND4(A, B, C, D, 0, Sm, 49);
	ROUND4(D, A, B, C, 7, Sn, 50);
	ROUND4(C, D, A, B, 14, So, 51);
	ROUND4(B, C, D, A, 5, Sp, 52);
	ROUND4(A, B, C, D, 12, Sm, 53);
	ROUND4(D, A, B, C, 3, Sn, 54);
	ROUND4(C, D, A, B, 10, So, 55);
	ROUND4(B, C, D, A, 1, Sp, 56);
	ROUND4(A, B, C, D, 8, Sm, 57);
	ROUND4(D, A, B, C, 15, Sn, 58);
	ROUND4(C, D, A, B, 6, So, 59);
	ROUND4(B, C, D, A, 13, Sp, 60);
	ROUND4(A, B, C, D, 4, Sm, 61);
	ROUND4(D, A, B, C, 11, Sn, 62);
	ROUND4(C, D, A, B, 2, So, 63);
	ROUND4(B, C, D, A, 9, Sp, 64);

	ctx->md5_sta += A;
	ctx->md5_stb += B;
	ctx->md5_stc += C;
	ctx->md5_std += D;
}

/** Add padding to md5 buffer. */
static void
md5_pad(struct md5_ctx *ctx)
{
	unsigned int gap;

	/* Don't count up padding. Keep md5_n. */
	gap = MD5_BUFLEN - ctx->md5_i;
	if (gap > 8) {
		memmove(ctx->md5_buf + ctx->md5_i, md5_paddat,
			gap - sizeof(ctx->md5_n));
	} else {
		/* including gap == 8 */
		memmove(ctx->md5_buf + ctx->md5_i, md5_paddat, gap);
		md5_calc(ctx->md5_buf, ctx);
		memmove(ctx->md5_buf, md5_paddat + gap,
			MD5_BUFLEN - sizeof(ctx->md5_n));
	}

	/* 8 byte word */
	memmove(&ctx->md5_buf[56], &ctx->md5_n8[0], 8);

	md5_calc(ctx->md5_buf, ctx);
}

static void
md5_result(uint8_t *digest, struct md5_ctx *ctx)
{
	/* 4 byte words */
	memmove(digest, &ctx->md5_st8[0], 16);
}

void
md5_init(struct md5_ctx *ctx)
{
	ctx->md5_n = 0;
	ctx->md5_i = 0;
	ctx->md5_sta = MD5_A0;
	ctx->md5_stb = MD5_B0;
	ctx->md5_stc = MD5_C0;
	ctx->md5_std = MD5_D0;
	memset(ctx->md5_buf, 0, sizeof(ctx->md5_buf));
}

void
md5_update(struct md5_ctx *ctx, const uint8_t *data, size_t len)
{
	unsigned int gap, i;

	ctx->md5_n += len * 8;		/* byte to bit */
	gap = MD5_BUFLEN - ctx->md5_i;

	if (len >= gap) {
		memmove(ctx->md5_buf + ctx->md5_i, data, gap);
		md5_calc(ctx->md5_buf, ctx);

		for (i = gap; i + MD5_BUFLEN <= len; i += MD5_BUFLEN)
			md5_calc(data + i, ctx);

		ctx->md5_i = len - i;
		memmove(ctx->md5_buf, data + i, ctx->md5_i);
	} else {
		memmove(ctx->md5_buf + ctx->md5_i, data, len);
		ctx->md5_i += len;
	}
}

void
md5_final(struct md5_ctx *ctx, uint8_t *dest)
{
	md5_pad(ctx);
	md5_result(dest, ctx);
}
