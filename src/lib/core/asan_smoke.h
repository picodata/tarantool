#pragma once
/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ASan smoke test for verifying AddressSanitizer instrumentation.
 */

#if defined(__cplusplus)
extern "C" {
#endif

/**
 * Trigger an ASan-detectable heap-buffer-overflow.
 *
 * This function intentionally causes a memory safety violation
 * that AddressSanitizer will detect. Use only for verifying
 * ASan instrumentation is working.
 *
 * WARNING: This function will cause the process to abort with
 * an ASan error report.
 *
 * @return value from the out-of-bounds read (forces the read to happen)
 */
char
asan_smoke_trigger(void);

/**
 * Check TARANTOOL_ASAN_SMOKE_TEST env var and trigger if set.
 *
 * @return 0 if env var not set (no action taken)
 * @return does not return if env var is set (triggers violation)
 */
int
asan_smoke_check_and_trigger(void);

#if defined(__cplusplus)
} /* extern "C" */
#endif
