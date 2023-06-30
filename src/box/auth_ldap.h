/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2023, Tarantool AUTHORS, please see AUTHORS file.
 */
#pragma once

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct auth_method;

/**
 * Allocates and initializes 'ldap' authentication method.
 * This function never fails.
 */
struct auth_method *
auth_ldap_new(void);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
