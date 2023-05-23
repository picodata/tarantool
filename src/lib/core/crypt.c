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
#include "crypt.h"
#include "md5.h"
#include "cryptohash.h"
#include "trivia/util.h"
#include "diag.h"

#include <string.h>

/** Convert bytes to hex values.  */
static void
bytes_to_hex(uint8_t b[16], char *s)
{
	static const char *hex = "0123456789abcdef";
	int q, w;

	for (q = 0, w = 0; q < 16; q++) {
		s[w++] = hex[(b[q] >> 4) & 0x0F];
		s[w++] = hex[b[q] & 0x0F];
	}
	s[w] = '\0';
}

/**
 * Calculates the MD5 sum of the bytes in a buffer.
 *
 * @param buff the buffer containing the bytes that you want the MD5 sum of.
 * @param len  number of bytes in the buffer.
 *
 * @param hexsum the MD5 sum as a '\0'-terminated string of
 *		 hexadecimal digits.  an MD5 sum is 16 bytes long.
 *		 each byte is represented by two hexadecimal
 *		 characters.  you thus need to provide an array
 *		 of 33 characters, including the trailing '\0'.
 *		 errstr  filled with a constant-string error message
 *		 on failure return; NULL on success.
 *
 * @note MD5 is described in RFC 1321.
 *
 * @author Sverre H. Huseby <sverrehu@online.no>
 *
 */
static void
md5_hash(const void *buff, size_t len, char *hexsum)
{
	uint8_t sum[MD5_DIGEST_LENGTH];

	struct cryptohash_ctx *ctx = cryptohash_create(CRYPTOHASH_MD5);
	cryptohash_init(ctx);
	cryptohash_update(ctx, buff, len);
	cryptohash_final(ctx, sum, sizeof(sum));
	bytes_to_hex(sum, hexsum);
	cryptohash_free(ctx);
}

void
md5_encrypt(const char *password, size_t password_len,
	    const char *salt, size_t salt_len, char *buf)
{
	assert(password_len + salt_len > 0);

	char *crypt_buf = xmalloc(password_len + salt_len);
	/*
	 * Place salt at the end because it may be known by users trying to
	 * crack the MD5 output.
	 */
	memcpy(crypt_buf, password, password_len);
	memcpy(crypt_buf + password_len, salt, salt_len);

	memcpy(buf, "md5", strlen("md5"));
	md5_hash(crypt_buf, password_len + salt_len, buf + strlen("md5"));

	free(crypt_buf);
}
