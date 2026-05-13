/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ASan smoke test for verifying AddressSanitizer instrumentation.
 */
#include "asan_smoke.h"
#include "trivia/util.h"

#include <stdlib.h>
#include <string.h>

char
asan_smoke_trigger(void)
{
	/*
	 * Canonical heap-buffer-overflow:
	 * Allocate 8 bytes, read at offset 8 (one past the end).
	 */
	char *buf = xmalloc(8);

	/* Out-of-bounds read - ASan will catch this */
	char result = buf[8];

	/* Never reached if ASan is working */
	free(buf);
	return result;
}

int
asan_smoke_check_and_trigger(void)
{
	char *env = getenv_safe("TARANTOOL_ASAN_SMOKE_TEST", NULL, 0);
	if (env == NULL || strcmp(env, "1") != 0) {
		free(env);
		return 0;
	}
	free(env);

	asan_smoke_trigger();
	/* Not reached */
	return 1;
}
