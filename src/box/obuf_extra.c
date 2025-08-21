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
#include "obuf_extra.h"

#include <small/obuf.h>
#include "trivia/util.h"

struct obuf *
obuf_new(void)
{
	struct obuf *buf = xmalloc(sizeof(*buf));
	return buf;
}

const struct iovec *
obuf_iovec_list(const struct obuf *buf, size_t *count)
{
	*count = obuf_iovcnt((struct obuf *)buf);
	return buf->iov;
}

size_t
obuf_used(const struct obuf *buf)
{
	return buf->used;
}
