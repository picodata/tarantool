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
#include "ssl.h"

#include <stddef.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#include "diag.h"
#include "iostream.h"
#include "ssl_init.h"
#include "sio.h"
#include "coio.h"
#include "uri/uri.h"
#include "tt_static.h"
#include "ssl_error.h"
#include "coio_task.h"

void
ssl_init(void)
{
	ssl_init_impl();
}

void
ssl_free(void)
{
	ssl_free_impl();
}

/**
 * Return true if ssl error is fatal (most of operations
 * must be cancelled in this case).
 */
static inline bool
ssl_is_fatal_error(int ssl_err)
{
	return ssl_err == SSL_ERROR_SYSCALL || ssl_err == SSL_ERROR_SSL;
}

/**
 * Return string representation of last ssl error.
 */
static inline const char*
ssl_last_error(void)
{
	char *buf = tt_static_buf();
	ERR_error_string_n(ERR_get_error(), buf, TT_STATIC_BUF_LEN);
	return buf;
}

/**
 * Callback, hands back the password to be used during decryption.
 *
 * @param buf password buffer, must be filled by this function
 * @param size password buffer size
 * @param rwflag indicates for which callback is used for
 * (decryption or encryption). For our purposes always 0.
 * @param ud user data, set by application. In our case
 * contains pointer to a password string.
 */
static int
password_callback(char *buf, int size, int rwflag, void *ud)
{
	(void)rwflag;
	assert(ud != NULL);

	strlcpy(buf, (char *)ud, size);
	buf[size - 1] = '\0';
	return (int) strlen(buf);
}

/**
 * Applies password for decode private key one by one, return 0 if
 * key successfully decoded with one of those passwords.
 *
 * @param ctx ssl context
 * @param file private key file
 * @param key_password_file private key password file
 */
static inline int
try_apply_passwords_from_file(SSL_CTX *ctx, const char *file, const char *key_password_file)
{
	int ret = -1;

	FILE *fp = fopen(key_password_file, "r");
	if (fp == NULL) {
		const char *msg = "Unable to set private key file, "
				  "failed to open password file";
		diag_set(IllegalParams, msg);
		goto end;
	}

	char *line = NULL;
	size_t len = 0;

	while (getline(&line, &len, fp) != -1) {
		/* trim password variants */
		if (line[strlen(line) - 1] == '\n') {
			line[strlen(line) - 1] = '\0';
		}
		SSL_CTX_set_default_passwd_cb_userdata(ctx, (void *)line);
		if (SSL_CTX_use_PrivateKey_file(ctx, file,
						SSL_FILETYPE_PEM) == 1) {
			ret = 0;
			goto end_clear;
		}
	}

	diag_set(IllegalParams, "Unable to set private key file: %s",
		 ssl_last_error());

end_clear:
	fclose(fp);
	free(line);
end:
	return ret;
}

/**
 * Same as `try_apply_passwords_from_file`, using in non-blocking context.
 */
static ssize_t
va_try_apply_passwords_from_file(va_list ap)
{
	SSL_CTX *ctx = va_arg(ap, SSL_CTX *);
	const char *file = va_arg(ap, const char *);
	const char *key_password_file = va_arg(ap, const char *);
	return try_apply_passwords_from_file(ctx, file, key_password_file);
}

/**
 * Try to set private key to ssl context. If key is encrypted password may be
 * found in string or in file.
 *
 * @param ctx ssl context
 * @param file private key file path
 * @param key_password private key password (if needed)
 * @param key_password_file private key password file (if needed)
 */
static int
ssl_ctx_try_set_key(SSL_CTX *ctx, const char *file, const char *key_password,
		    const char *key_password_file, enum iostream_mode mode)
{
	int ret = -1;

	/*
	 * if private key file not defined - it is ok,
	 * possible errors may cauth in other steps
	 */
	if (file == NULL) {
		ret = 0;
		goto end;
	}

	SSL_CTX_set_default_passwd_cb(ctx, password_callback);

	/* if password for a key not defined tries to use it as-is */
	if (key_password_file == NULL && key_password == NULL) {
		if (SSL_CTX_use_PrivateKey_file(ctx, file,
						SSL_FILETYPE_PEM) == 1) {
			ret = 0;
			goto end;
		}
		diag_set(IllegalParams, "Unable to set private key file: %s",
			 ssl_last_error());
		goto end;
	}

	/* step 1 try to encode key with key_password */
	if (key_password != NULL) {
		SSL_CTX_set_default_passwd_cb_userdata(ctx,
						       (void *)key_password);
		if (SSL_CTX_use_PrivateKey_file(ctx, file,
						SSL_FILETYPE_PEM) == 1) {
			ret = 0;
			goto end;
		}
	}

	/* step 2, load password file and try to apply passwords line by line */
	if (key_password_file == NULL) {
		diag_set(IllegalParams, "Unable to set private key file: %s",
			 ssl_last_error());
		goto end;
	}

	if (mode == IOSTREAM_CLIENT) {
		ret = (int)coio_call(va_try_apply_passwords_from_file, ctx,
				     file, key_password_file);
	} else {
		ret = try_apply_passwords_from_file(ctx, file,
						    key_password_file);
	}

	ERR_clear_error();
end:
	return ret;
}

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
/**
 * Same as `X509_STORE_load_file`, using in non-blocking context.
 */
static ssize_t
va_X509_STORE_load_file(va_list ap)
{
	X509_STORE *store = va_arg(ap, X509_STORE *);
	const char *ca_file = va_arg(ap, const char *);
	return X509_STORE_load_file(store, ca_file);
}
#else
/**
 * Same as `X509_STORE_load_locations`, using in non-blocking context.
 */
static ssize_t
va_X509_STORE_load_locations(va_list ap)
{
	X509_STORE *store = va_arg(ap, X509_STORE *);
	const char *ca_file = va_arg(ap, const char *);
	return X509_STORE_load_locations(store, ca_file, NULL);
}
#endif

/**
 * Create a new ssl context from given uri.
 */
static inline struct ssl_iostream_ctx *
ssl_iostream_ctx_new_inner(enum iostream_mode mode, const struct uri *uri)
{
	const char *key = uri_param(uri, "ssl_key_file", 0);
	const char *cert = uri_param(uri, "ssl_cert_file", 0);
	const char *key_password = uri_param(uri, "ssl_password", 0);
	const char *key_password_file = uri_param(uri, "ssl_password_file", 0);
	const char *ca_file = uri_param(uri, "ssl_ca_file", 0);
	const char *cipher_list = uri_param(uri, "ssl_ciphers", 0);

	const SSL_METHOD *method = NULL;
	switch (mode) {
	case IOSTREAM_MODE_UNINITIALIZED:
		unreachable();
	case IOSTREAM_CLIENT:
		method = TLS_client_method();
		break;
	case IOSTREAM_SERVER:
		method = TLS_server_method();

		const char *error = "ssl_key_file and ssl_cert_file"
			" parameters are mandatory for a server";
		if (key == NULL || cert == NULL) {
			diag_set(IllegalParams, error);
			return NULL;
		}
		break;
	}

	SSL_CTX *ctx = SSL_CTX_new(method);
	if (ctx == NULL) {
		diag_set(SSLError, "Unable to create SSL context");
		return NULL;
	}

	SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);

	if (ca_file != NULL) {
		X509_STORE *store = SSL_CTX_get_cert_store(ctx);

		int load_ret;

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
		if (mode == IOSTREAM_CLIENT) {
			load_ret = (int)coio_call(va_X509_STORE_load_file,
						  store, ca_file);
		} else {
			load_ret = X509_STORE_load_file(store, ca_file);
		}
#else
		if (mode == IOSTREAM_CLIENT) {
			load_ret = (int)coio_call(va_X509_STORE_load_locations,
						  store, ca_file);
		} else {
			load_ret = X509_STORE_load_locations(store, ca_file,
							     NULL);
		}
#endif

		if (load_ret == 0) {
			diag_set(SSLError, "Unable to load CA file");
			return NULL;
		}

		int vmode = SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT |
			    SSL_VERIFY_CLIENT_ONCE;
		SSL_CTX_set_verify(ctx, vmode, NULL);
	}

	if (cipher_list != NULL) {
		if (SSL_CTX_set_cipher_list(ctx, cipher_list) == 0) {
			diag_set(IllegalParams,
				 "Unable to set cipher list: %s",
				 cipher_list);
			goto err;
		}
	}

	if (cert != NULL) {
		int ret = SSL_CTX_use_certificate_file(ctx, cert,
						       SSL_FILETYPE_PEM);
		if (ret <= 0) {
			diag_set(IllegalParams,
				 "Unable to set certificate file: %s",
				 ssl_last_error());
			goto err;
		}
	}

	int key_ret = ssl_ctx_try_set_key(
		ctx, key, key_password, key_password_file, mode);
	if (key_ret != 0) {
		goto err;
	}

	struct ssl_iostream_ctx *io_ctx =
		xmalloc(sizeof(struct ssl_iostream_ctx));
	io_ctx->ctx = ctx;

	return io_ctx;
err:
	SSL_CTX_free(ctx);
	return NULL;
}

/**
 * Create a new ssl context.
 */
struct ssl_iostream_ctx *
ssl_iostream_ctx_new(enum iostream_mode mode, const struct uri *uri)
{
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	(void)mode;
	(void)uri;
	diag_set(IllegalParams, "SSL is not available in this build");
	return NULL;
#else
	return ssl_iostream_ctx_new_inner(mode, uri);
#endif
}

/**
 * iostream_vtab ssl implementation
 */
static const struct iostream_vtab ssl_iostream_vtab;

int
ssl_iostream_create_supported(struct iostream *io, int fd,
			      const struct ssl_iostream_ctx *ctx)
{
	SSL *ssl = SSL_new(ctx->ctx);
	if (ssl == NULL) {
		diag_set(SSLError, "Create ssl object error: %s",
			 ssl_last_error());
		return -1;
	}

	if (SSL_set_fd(ssl, fd) == 0) {
		diag_set(SSLError, "SSL set fd error: %s",
			 ssl_last_error());
		SSL_free(ssl);
		return -1;
	}

	io->flags = IOSTREAM_IS_ENCRYPTED;
	io->fd = fd;
	io->data = ssl;
	io->vtab = &ssl_iostream_vtab;
#ifndef NDEBUG
	io->owner = NULL;
#endif
	return 0;
}

static void
ssl_iostream_destroy(struct iostream *io)
{
	SSL *ssl = (SSL *)io->data;

	/*
	 * two checks here:
	 * 1) check SSL_IOSTREAM_SESSION_READY flag, this will prevent
	 * from calling coio_* functions from non-coio thread (iproto)
	 * 2) check !SSL_IOSTREAM_POISON, according too documentation,
	 * SSL_shutdown function mustn't be called
	 * if a previous fatal error has occurred on a connection
	 */
	bool do_shutdown = (io->flags & SSL_IOSTREAM_SESSION_READY) &&
			   !(io->flags & SSL_IOSTREAM_POISON);
	if (do_shutdown) {
		while (true) {
			int ret = SSL_shutdown(ssl);
			if (ret == 1)
				break;
			if (ret == 0)
				continue;

			int ssl_error = SSL_get_error(ssl, ret);
			switch (ssl_error) {
			case SSL_ERROR_WANT_READ:
				coio_wait(io->fd, COIO_READ, 1);
				break;
			case SSL_ERROR_WANT_WRITE:
				coio_wait(io->fd, COIO_WRITE, 1);
				break;
			default:
			{
				const char *le = ssl_last_error();
				say_error("SSL_shutdown error: %s", le);
				goto free;
			}
			}
		}
	}

free:
	SSL_free(ssl);
}

/**
 * This function implement "lazy session initialization" on ssl connection.
 * Lazy means that secure session will be initialized (SSL_accept/SSL_connect
 * called) not when connection is created, but on first io
 * operation (read/write).
 */
static inline ssize_t
ssl_iostream_init_session(struct iostream *io)
{
	if (likely(io->flags & SSL_IOSTREAM_SESSION_READY))
		return 0;

	SSL *ssl = (SSL *)io->data;

	int r;
	if (SSL_is_server(ssl)) {
		r = SSL_accept(ssl);
	} else {
		r = SSL_connect(ssl);
	}

	if (r <= 0) {
		int ssl_error = SSL_get_error(ssl, r);
		switch (ssl_error) {
		case SSL_ERROR_WANT_READ:
			return IOSTREAM_WANT_READ;
		case SSL_ERROR_WANT_WRITE:
			return IOSTREAM_WANT_WRITE;
		default:
			diag_set(
				SSLError,
				"Init session error: %s",
				ssl_last_error());
			return IOSTREAM_ERROR;
		}
	}

	io->flags |= SSL_IOSTREAM_SESSION_READY;
	return 0;
}

/**
 * Check stream state and initialize ssl session if needed.
 */
static inline ssize_t
ssl_iostream_io_prolog(struct iostream *io)
{
	assert(io->fd >= 0);
	if (io->flags & SSL_IOSTREAM_POISON)
		return IOSTREAM_ERROR;
	return ssl_iostream_init_session(io);
}

static inline ssize_t
ssl_err_to_iostream_err(int ssl_error)
{
	switch (ssl_error) {
	case SSL_ERROR_WANT_READ:
		return IOSTREAM_WANT_READ;
	case SSL_ERROR_WANT_WRITE:
		return IOSTREAM_WANT_WRITE;
	case SSL_ERROR_ZERO_RETURN:
		return 0;
	default:
		return IOSTREAM_ERROR;
	}
}

static ssize_t
ssl_iostream_read(struct iostream *io, void *buf, size_t count)
{
	ssize_t r = ssl_iostream_io_prolog(io);
	if (r != 0)
		return r;

	SSL *ssl = (SSL *)io->data;

	int ret = ssl_sio_read(ssl, io->fd, buf, count);
	if (ret > 0)
		return ret;

	int ssl_error = SSL_get_error(ssl, ret);
	if (ssl_is_fatal_error(ssl_error)) {
		io->flags |= SSL_IOSTREAM_POISON;
	}
	return ssl_err_to_iostream_err(ssl_error);
}

static ssize_t
ssl_iostream_write(struct iostream *io, const void *buf, size_t count)
{
	ssize_t r = ssl_iostream_io_prolog(io);
	if (r != 0)
		return r;

	SSL *ssl = (SSL *)io->data;

	int ret = ssl_sio_write(ssl, io->fd, buf, count);
	if (ret > 0)
		return ret;

	int ssl_error = SSL_get_error(ssl, ret);
	if (ssl_is_fatal_error(ssl_error)) {
		io->flags |= SSL_IOSTREAM_POISON;
	}
	return ssl_err_to_iostream_err(ssl_error);
}

static ssize_t
ssl_iostream_writev(struct iostream *io, const struct iovec *iov, int iovcnt)
{
	ssize_t r = ssl_iostream_io_prolog(io);
	if (r != 0)
		return r;

	SSL *ssl = (SSL *)io->data;

	int ret = ssl_sio_writev(ssl, io->fd, iov, iovcnt);
	if (ret > 0)
		return ret;

	int ssl_error = SSL_get_error(ssl, ret);
	if (ssl_is_fatal_error(ssl_error)) {
		io->flags |= SSL_IOSTREAM_POISON;
	}
	return ssl_err_to_iostream_err(ssl_error);
}

static const struct iostream_vtab ssl_iostream_vtab = {
	/* .destroy = */ ssl_iostream_destroy,
	/* .read = */ ssl_iostream_read,
	/* .write = */ ssl_iostream_write,
	/* .writev = */ ssl_iostream_writev,
};
