/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2022, Tarantool AUTHORS, please see AUTHORS file.
 */
#include "auth_md5.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "authentication.h"
#include "crypt.h"
#include "diag.h"
#include "errcode.h"
#include "error.h"
#include "fiber.h"
#include "msgpuck.h"
#include "small/region.h"
#include "trivia/util.h"

/**
 * These are the core bits of the md5 authentication.
 * The algorithm is the same as postgres md5 authentication:
 *
 * SERVER:  shadow_pass = md5(password, user)
 *          salt = create_random_string()
 *          send(salt)
 *
 * CLIENT:  recv(salt)
 *          shadow_pass = md5(password, user)
 *          client_pass = md5(shadow_pass, salt)
 *          send(client_pass)
 *
 * SERVER:  recv(client_pass)
 *          check(client_pass == md5(shadow_pass, salt))
 */

#define AUTH_MD5_NAME "md5"

/** md5 authenticator implementation. */
struct auth_md5_authenticator {
	/** Base class. */
	struct authenticator base;
	/** md5(password, user). */
	char shadow_pass[MD5_PASSWD_LEN];
};

/**
 * Prepare a client password to send over the wire to the server
 * for authentication. password may be not null-terminated.
 * client_pass and salt sizes are regulated by MD5_PASSWD_LEN and MD5_SALT_LEN.
 * Never fails.
 */
static void
client_password_prepare(char *client_pass,
			const void *password, size_t password_len,
			const char *user,
			const char *salt)
{
	char shadow_pass[MD5_PASSWD_LEN];
	md5_encrypt(password, password_len, user, strlen(user), shadow_pass);
	md5_encrypt(shadow_pass + strlen("md5"), MD5_PASSWD_LEN - strlen("md5"),
		    salt, MD5_SALT_LEN, client_pass);
}

/**
 * Verify a password.
 * salt size must be at least MD5_SALT_LEN.
 *
 * @retval true passwords match
 * @retval false passwords do not match or error occurred
 */
static bool
client_password_check(const char *client_pass,
		      const char *shadow_pass,
		      const char *salt)
{
	char candidate[MD5_PASSWD_LEN];
	/* Compute the correct answer for the MD5 challenge. */
	md5_encrypt(shadow_pass + strlen("md5"), MD5_PASSWD_LEN - strlen("md5"),
		    salt, MD5_SALT_LEN, candidate);
	return memcmp(client_pass, candidate, MD5_PASSWD_LEN) == 0;
}

/** auth_method::auth_method_delete */
static void
auth_md5_delete(struct auth_method *method)
{
	TRASH(method);
	free(method);
}

/** auth_method::auth_data_prepare */
static void
auth_md5_data_prepare(const struct auth_method *method,
		      const char *password, int password_len,
		      const char *user,
		      const char **auth_data,
		      const char **auth_data_end)
{
	(void)method;
	struct region *region = &fiber()->gc;
	size_t size = mp_sizeof_str(MD5_PASSWD_LEN);
	char *p = xregion_alloc(region, size);
	*auth_data = p;
	*auth_data_end = p + size;
	char *shadow_pass = mp_encode_strl(p, MD5_PASSWD_LEN);

	md5_encrypt(password, password_len, user, strlen(user), shadow_pass);
}

/** auth_method::auth_request_prepare */
static void
auth_md5_request_prepare(const struct auth_method *method,
			 const char *password, int password_len,
			 const char *user,
			 const char *salt,
			 const char **auth_request,
			 const char **auth_request_end)
{
	(void)method;
	struct region *region = &fiber()->gc;
	size_t size = mp_sizeof_str(MD5_PASSWD_LEN);
	char *p = xregion_alloc(region, size);
	*auth_request = p;
	*auth_request_end = p + size;
	char *client_password = mp_encode_strl(p, MD5_PASSWD_LEN);
	client_password_prepare(client_password,
				password, password_len, user, salt);
}

/** auth_method::auth_request_check */
static int
auth_md5_request_check(const struct auth_method *method,
		       const char *auth_request,
		       const char *auth_request_end)
{
	(void)method;
	uint32_t client_pass_len;
	if (mp_typeof(*auth_request) == MP_STR) {
		client_pass_len = mp_decode_strl(&auth_request);
	} else if (mp_typeof(*auth_request) == MP_BIN) {
		/*
		 * Password is not a character stream, so some codecs
		 * automatically pack it as MP_BIN.
		 */
		client_pass_len = mp_decode_binl(&auth_request);
	} else {
		diag_set(ClientError, ER_INVALID_AUTH_REQUEST,
			 AUTH_MD5_NAME, "client password must be a string");
		return -1;
	}
	assert(auth_request + client_pass_len == auth_request_end);
	(void)auth_request_end;
	if (client_pass_len != MD5_PASSWD_LEN) {
		diag_set(ClientError, ER_INVALID_AUTH_REQUEST,
			 AUTH_MD5_NAME, "invalid client password size");
		return -1;
	}
	return 0;
}

/** auth_method::authenticator_new */
static struct authenticator *
auth_md5_authenticator_new(const struct auth_method *method,
			   const char *auth_data,
			   const char *auth_data_end)
{
	if (mp_typeof(*auth_data) != MP_STR) {
		diag_set(ClientError, ER_INVALID_AUTH_DATA,
			 AUTH_MD5_NAME, "password must be a string");
		return NULL;
	}

	uint32_t shadow_pass_len;
	const char *shadow_pass = mp_decode_str(&auth_data, &shadow_pass_len);
	assert(auth_data == auth_data_end);
	(void)auth_data_end;

	if (shadow_pass_len != MD5_PASSWD_LEN) {
		diag_set(ClientError, ER_INVALID_AUTH_DATA,
			 AUTH_MD5_NAME, "invalid shadow password size");
		return NULL;
	}

	struct auth_md5_authenticator *auth = xcalloc(1, sizeof(*auth));
	auth->base.method = method;
	memcpy(auth->shadow_pass, shadow_pass, MD5_PASSWD_LEN);
	return (struct authenticator *)auth;
}

/** auth_method::authenticator_delete */
static void
auth_md5_authenticator_delete(struct authenticator *auth_)
{
	struct auth_md5_authenticator *auth =
		(struct auth_md5_authenticator *)auth_;
	TRASH(auth);
	free(auth);
}

/** auth_method::authenticator_check_request */
static bool
auth_md5_authenticate_request(const struct authenticator *auth_,
			      const char *user,
			      const char *salt,
			      const char *auth_request,
			      const char *auth_request_end)
{
	(void)user;
	const struct auth_md5_authenticator *auth =
		(const struct auth_md5_authenticator *)auth_;
	uint32_t client_pass_len;
	const char *client_pass;
	if (mp_typeof(*auth_request) == MP_STR) {
		client_pass = mp_decode_str(&auth_request, &client_pass_len);
	} else if (mp_typeof(*auth_request) == MP_BIN) {
		client_pass = mp_decode_bin(&auth_request, &client_pass_len);
	} else {
		unreachable();
	}

	assert(auth_request == auth_request_end);
	(void)auth_request_end;
	assert(client_pass_len == MD5_PASSWD_LEN);
	return client_password_check(client_pass, auth->shadow_pass, salt);
}

struct auth_method *
auth_md5_new(void)
{
	struct auth_method *method = xmalloc(sizeof(*method));
	method->name = AUTH_MD5_NAME;
	method->flags = 0;
	method->auth_method_delete = auth_md5_delete;
	method->auth_method_delete = auth_md5_delete;
	method->auth_data_prepare = auth_md5_data_prepare;
	method->auth_request_prepare = auth_md5_request_prepare;
	method->auth_request_check = auth_md5_request_check;
	method->authenticator_new = auth_md5_authenticator_new;
	method->authenticator_delete = auth_md5_authenticator_delete;
	method->authenticate_request = auth_md5_authenticate_request;
	return method;
}
