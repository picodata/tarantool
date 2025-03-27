/*auth
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2023, Tarantool AUTHORS, please see AUTHORS file.
 */
#include "auth_ldap.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <ldap.h>

#include "authentication.h"
#include "coio_task.h"
#include "diag.h"
#include "errcode.h"
#include "error.h"
#include "fiber.h"
#include "msgpuck.h"
#include "small/region.h"
#include "trivia/util.h"

#define AUTH_LDAP_NAME "ldap"

/** ldap authenticator implementation. */
struct auth_ldap_authenticator {
	/** Base class. */
	struct authenticator base;
};

/** Try to format a proper LDAP Distinguished Name (DN). */
static int
format_dn(const char *fmt, const char *user, uint32_t user_len, char *buf, size_t len)
{
	/** Magic should be replaced with the actual user */
	const char *magic = "$USER";
	char *suffix = strstr(fmt, magic);
	if (suffix == NULL) {
		say_error("TT_LDAP_DN_FMT doesn't contain $USER");
		return -1;
	}

	size_t prefix_len = suffix - fmt;
	suffix += strlen(magic);
	size_t suffix_len = strlen(suffix);

	if (strstr(suffix, magic) != NULL) {
		say_error("TT_LDAP_DN_FMT contains more than one $USER");
		return -1;
	}

	size_t needed = prefix_len + user_len + suffix_len + 1;
	if (needed > len) {
		say_error("TT_LDAP_DN_FMT is too long (max %lu)", len);
		return -1;
	}

	memcpy(buf, fmt, prefix_len);
	buf += prefix_len;
	memcpy(buf, user, user_len);
	buf += user_len;
	memcpy(buf, suffix, suffix_len);
	buf += suffix_len;
	buf[0] = '\0';

	return 0;
}

/** Perform synchronous LDAP BIND method call to authenticate as user */
static ssize_t
coio_ldap_check_password(va_list ap)
{
	const char *password = va_arg(ap, const char *);
	uint32_t password_len = va_arg(ap, uint32_t);
	const char *user = va_arg(ap, const char *);
	uint32_t user_len = va_arg(ap, uint32_t);

	/**
	 * This should point to the LDAP authentication server.
	 * Example: `ldap://localhost:1389`.
	 */
	const char *url = va_arg(ap, const char *);

	/**
	 * This should be a proper LDAP Distinguished Name (DN) fmt string.
	 * Example: `cn=$USER,ou=users,dc=example,dc=org`.
	 */
	const char *dn_fmt = va_arg(ap, const char *);

	int ret = -1;
	LDAP *ldp = NULL;

	char dn[512];
	if (format_dn(dn_fmt, user, user_len, dn, sizeof(dn)) != 0)
		goto cleanup;

	/**
	 * Initialize the context, but don't connect just yet.
	 * According to the documentation, the actual connection open
	 * will occur when the first operation is attempted.
	 * Previosly we used to call ldap_connect() after this,
	 * but it's not available in libldap 2.4 (centos 7).
	 */
	ret = ldap_initialize(&ldp, url);
	if (ret != LDAP_SUCCESS) {
		say_error("failed to initialize LDAP connection: %s",
			  ldap_err2string(ret));
		diag_set(ClientError, ER_SYSTEM, ldap_err2string(ret));
		goto cleanup;
	}

	/** NB: older protocol versions may not be supported */
	ret = ldap_set_option(ldp, LDAP_OPT_PROTOCOL_VERSION,
			      &(int){LDAP_VERSION3});
	if (ret != LDAP_SUCCESS) {
		say_error("failed to set LDAP connection option: %s",
			  ldap_err2string(ret));
		diag_set(ClientError, ER_SYSTEM, ldap_err2string(ret));
		goto cleanup;
	}

	/** Check user's credentials by binding to the server on their behalf */
	say_info("attempting LDAP BIND as '%s'", dn);
	struct berval cred = {
		.bv_val = (char *)password,
		.bv_len = (ber_len_t)password_len,
	};
	/** See definition of ldap_simple_bind_s() */
	ret = ldap_sasl_bind_s(ldp, dn, LDAP_SASL_SIMPLE,
			       &cred, NULL, NULL, NULL);
	if (ret != LDAP_SUCCESS) {
		say_error("ldap authentication failed: %s",
			  ldap_err2string(ret));
		diag_set(ClientError, ER_SYSTEM, ldap_err2string(ret));
		goto cleanup;
	}

cleanup:
	if (ldp) {
		/** This also reclaims the memory */
		(void)ldap_unbind_ext_s(ldp, NULL, NULL);
	}

	return (ret == LDAP_SUCCESS) ? 0 : -1;
}

/** auth_method::auth_method_delete */
static void
auth_ldap_delete(struct auth_method *method)
{
	TRASH(method);
	free(method);
}

/** auth_method::auth_data_prepare */
static void
auth_ldap_data_prepare(const struct auth_method *method,
		       const char *password,
		       uint32_t password_len,
		       const char *user,
		       uint32_t user_len,
		       const char **auth_data,
		       const char **auth_data_end)
{
	(void)method;
	(void)user;
	(void)user_len;
	(void)password;
	(void)password_len;
	struct region *region = &fiber()->gc;
	size_t size = mp_sizeof_str(0);
	char *p = xregion_alloc(region, size);
	*auth_data = p;
	*auth_data_end = p + size;
	p = mp_encode_strl(p, 0);
}

/** auth_method::auth_request_prepare */
static void
auth_ldap_request_prepare(const struct auth_method *method,
			  const char *password,
			  uint32_t password_len,
			  const char *user,
			  uint32_t user_len,
			  const char *salt,
			  const char **auth_request,
			  const char **auth_request_end)
{
	(void)method;
	(void)user;
	(void)user_len;
	(void)salt;
	struct region *region = &fiber()->gc;
	size_t size = mp_sizeof_str(password_len);
	char *p = xregion_alloc(region, size);
	*auth_request = p;
	*auth_request_end = p + size;
	p = mp_encode_strl(p, password_len);
	memcpy(p, password, password_len);
}

/** auth_method::auth_request_check */
static int
auth_ldap_request_check(const struct auth_method *method,
			const char *auth_request,
			const char *auth_request_end)
{
	(void)method;
	uint32_t password_len;
	(void)password_len;
	if (mp_typeof(*auth_request) == MP_STR) {
		password_len = mp_decode_strl(&auth_request);
	} else if (mp_typeof(*auth_request) == MP_BIN) {
		password_len = mp_decode_binl(&auth_request);
	} else {
		diag_set(ClientError, ER_INVALID_AUTH_REQUEST,
			 AUTH_LDAP_NAME, "password must be string");
		return -1;
	}
	assert(auth_request + password_len == auth_request_end);
	(void)auth_request_end;
	return 0;
}

/** auth_method::authenticator_new */
static struct authenticator *
auth_ldap_authenticator_new(const struct auth_method *method,
			    const char *auth_data,
			    const char *auth_data_end)
{
	/** NB: we don't use stored data anyway */
	(void)auth_data;
	(void)auth_data_end;

	struct auth_ldap_authenticator *auth = xmalloc(sizeof(*auth));
	auth->base.method = method;
	return (struct authenticator *)auth;
}

/** auth_method::authenticator_delete */
static void
auth_ldap_authenticator_delete(struct authenticator *auth_)
{
	struct auth_ldap_authenticator *auth =
		(struct auth_ldap_authenticator *)auth_;
	TRASH(auth);
	free(auth);
}

/** auth_method::authenticator_check_request */
static bool
auth_ldap_authenticate_request(const struct authenticator *auth,
			       const char *user,
			       uint32_t user_len,
			       const char *salt,
			       const char *auth_request,
			       const char *auth_request_end)
{
	(void)auth;
	(void)salt;
	uint32_t password_len;
	const char *password;
	if (mp_typeof(*auth_request) == MP_STR) {
		password = mp_decode_str(&auth_request, &password_len);
	} else if (mp_typeof(*auth_request) == MP_BIN) {
		password = mp_decode_bin(&auth_request, &password_len);
	} else {
		unreachable();
	}
	assert(auth_request == auth_request_end);
	(void)auth_request_end;

	ssize_t ret = -1;

	/** NB: we shouldn't call getenv() from coio since it's MT-Unsafe */
	char url[512];
	if (getenv_safe("TT_LDAP_URL", url, sizeof(url)) == NULL) {
		say_error("LDAP server not configured, "
			  "please set env variable TT_LDAP_URL");
		diag_set(ClientError, ER_SYSTEM, "LDAP server not configured");
		goto fail;
	}

	char dn_fmt[512];
	if (getenv_safe("TT_LDAP_DN_FMT", dn_fmt, sizeof(dn_fmt)) == NULL) {
		say_error("LDAP DN format string not configured, "
			  "please set env variable TT_LDAP_DN_FMT");
		diag_set(ClientError, ER_SYSTEM,
			 "LDAP DN format string not configured");
		goto fail;
	}

	ret = coio_call(coio_ldap_check_password,
			password, password_len,
			user, user_len, url, dn_fmt);
fail:
	return ret == 0;
}

struct auth_method *
auth_ldap_new(void)
{
	struct auth_method *method = xmalloc(sizeof(*method));
	method->name = AUTH_LDAP_NAME;
	method->flags = AUTH_METHOD_PASSWORDLESS_DATA_PREPARE;
	method->auth_method_delete = auth_ldap_delete;
	method->auth_data_prepare = auth_ldap_data_prepare;
	method->auth_request_prepare = auth_ldap_request_prepare;
	method->auth_request_check = auth_ldap_request_check;
	method->authenticator_new = auth_ldap_authenticator_new;
	method->authenticator_delete = auth_ldap_authenticator_delete;
	method->authenticate_request = auth_ldap_authenticate_request;
	return method;
}
