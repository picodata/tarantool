#pragma once
/**
 * Copyright (C) Picodata LLC - All Rights Reserved
 *
 * This source code is protected under international copyright law.  All rights
 * reserved and protected by the copyright holders.
 * This file is confidential and only available to authorized individuals with
 * the permission of the copyright holders.  If you encounter this file and do
 * not have permission, please contact the copyright holders and delete this
 * file.
 */

#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct obuf;
struct iovec;

/**
 * Allocate on the heap a new obuf.
 */
struct obuf *
obuf_new(void);

/**
 * Get the list of iovec structures for the given obuf.
 */
const struct iovec *
obuf_iovec_list(const struct obuf *buf, size_t *count);

/**
 * Get the used size of the given obuf.
 */
size_t
obuf_used(const struct obuf *buf);

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined __cplusplus */
