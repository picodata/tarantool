#include "iostream.h"
#include "trivia/util.h"
#include <openssl/ssl.h>
#include <openssl/err.h>

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct uri;

/**
 * Secure iostream context.
 */
struct ssl_iostream_ctx {
	/**
	 * SSL context.
	 */
	SSL_CTX *ctx;
};

void
ssl_init(void);

void
ssl_free(void);

struct ssl_iostream_ctx *
ssl_iostream_ctx_new(enum iostream_mode mode, const struct uri *uri);

static inline void
ssl_iostream_ctx_delete(struct ssl_iostream_ctx *ctx)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	(void)ctx;
	unreachable();
#else
	SSL_CTX_free(ctx->ctx);
	free(ctx);
#endif
}

int
ssl_iostream_create_supported(struct iostream *io, int fd,
			      const struct ssl_iostream_ctx *ctx);

static inline int
ssl_iostream_create(struct iostream *io, int fd, enum iostream_mode mode,
		    const struct ssl_iostream_ctx *ctx)
{
	(void)mode;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
	(void)io;
	(void)fd;
	(void)ctx;
	unreachable();
	return 0;
#else
	return ssl_iostream_create_supported(io, fd, ctx);
#endif
}

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
