/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2022, Tarantool AUTHORS, please see AUTHORS file.
 */
#pragma once

#include <stdint.h>
#include <stdlib.h>

#include "schema_def.h" /* for SCHEMA_OBJECT_TYPE */
#define RB_COMPACT 1
#include "small/rb.h"
#include "small/rlist.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct authenticator;

/** \cond public */
typedef uint16_t box_user_access_mask_t;
/** \endcond public */

/**
 * Effective session user. A cache of user data
 * and access stored in session and fiber local storage.
 * Differs from the authenticated user when executing
 * setuid functions.
 */
struct credentials {
	/** A look up key to quickly find session user. */
	uint16_t auth_token;
	/**
	 * Cached global grants, to avoid an extra look up
	 * when checking global grants.
	 */
	box_user_access_mask_t universal_access;
	/** User id of the authenticated user. */
	uint32_t uid;
	/**
	 * Member of credentials list of the source user. The list
	 * is used to collect privilege updates to keep the
	 * credentials up to date.
	 */
	struct rlist in_user;
};

/** \cond public */
enum box_privilege_type {
	/* SELECT */
	BOX_PRIVILEGE_READ = 1,
	/* INSERT, UPDATE, UPSERT, DELETE, REPLACE */
	BOX_PRIVILEGE_WRITE = 2,
	/* CALL */
	BOX_PRIVILEGE_EXECUTE = 4,
	/* SESSION */
	BOX_PRIVILEGE_SESSION = 8,
	/* USAGE */
	BOX_PRIVILEGE_USAGE = 16,
	/* CREATE */
	BOX_PRIVILEGE_CREATE = 32,
	/* DROP */
	BOX_PRIVILEGE_DROP = 64,
	/* ALTER */
	BOX_PRIVILEGE_ALTER = 128,
	/* REFERENCE - required by ANSI - not implemented */
	BOX_PRIVILEGE_REFERENCE = 256,
	/* TRIGGER - required by ANSI - not implemented */
	BOX_PRIVILEGE_TRIGGER = 512,
	/* INSERT - required by ANSI - not implemented */
	BOX_PRIVILEGE_INSERT = 1024,
	/* UPDATE - required by ANSI - not implemented */
	BOX_PRIVILEGE_UPDATE = 2048,
	/* DELETE - required by ANSI - not implemented */
	BOX_PRIVILEGE_DELETE = 4096,
	/* This is never granted, but used internally. */
	BOX_PRIVILEGE_GRANT = 8192,
	/* Never granted, but used internally. */
	BOX_PRIVILEGE_REVOKE = 16384,
	/* all bits */
	BOX_PRIVILEGE_ALL  = ~((box_user_access_mask_t)0),
};

/** \endcond public */

/**
 * Definition of a privilege
 */
struct priv_def {
	/** Who grants the privilege. */
	uint32_t grantor_id;
	/** Whom the privilege is granted. */
	uint32_t grantee_id;
	/* Object id - is only defined for object type */
	uint32_t object_id;
	/* Object type - function, space, universe */
	enum box_schema_object_type object_type;
	/**
	 * What is being granted, has been granted, or is being
	 * revoked.
	 */
	box_user_access_mask_t access;
	/** To maintain a set of effective privileges. */
	rb_node(struct priv_def) link;
};

/* Privilege name for error messages */
const char *
priv_name(box_user_access_mask_t access);

/**
 * Encapsulates privileges of a user on an object.
 * I.e. "space" object has an instance of this
 * structure for each user.
 */
struct access {
	/**
	 * Granted access has been given to a user explicitly
	 * via some form of a grant.
	 */
	box_user_access_mask_t granted;
	/**
	 * Effective access is a sum of granted access and
	 * all privileges inherited by a user on this object
	 * via some role. Since roles may be granted to other
	 * roles, this may include indirect grants.
	 */
	box_user_access_mask_t effective;
};

/**
 * The grants on an object, one slot per grantee, indexed by the
 * grantee's authentication token. Most objects are granted to
 * nobody and hold no slots at all; a grant makes room up to the
 * token of its grantee, and the tokens above that are absent
 * rather than empty.
 */
struct access_map {
	/** The slots, NULL while the object has no grants. */
	struct access *data;
	/** The number of slots. */
	uint32_t size;
};

/** Initialize a map with no grants. */
static inline void
access_map_create(struct access_map *map)
{
	map->data = NULL;
	map->size = 0;
}

/** Release the memory the map owns. */
static inline void
access_map_destroy(struct access_map *map)
{
	free(map->data);
	access_map_create(map);
}

/** The effective access of the grantee, none if it has no slot. */
static inline box_user_access_mask_t
access_map_effective(const struct access_map *map, uint32_t auth_token)
{
	return auth_token < map->size ? map->data[auth_token].effective : 0;
}

/**
 * Make room up to the given grantee and return its slot. The
 * map must not reach the grantee yet.
 */
struct access *
access_map_grow(struct access_map *map, uint32_t auth_token);

/** The slot of the given grantee, made if the map lacks one. */
static inline struct access *
access_map_slot(struct access_map *map, uint32_t auth_token)
{
	if (auth_token >= map->size)
		return access_map_grow(map, auth_token);
	return &map->data[auth_token];
}

/**
 * Copy the grants on one object to another.
 * @param dst The map to copy to, must be empty.
 * @param src The map to copy from.
 */
void
access_map_copy(struct access_map *dst, const struct access_map *src);

/**
 * A cache entry for an existing user. Entries for all existing
 * users are always present in the cache. The entry is maintained
 * in sync with _user and _priv system spaces by system space
 * triggers.
 * @sa alter.cc
 */
struct user_def {
	/** User id. */
	uint32_t uid;
	/** Creator of the user */
	uint32_t owner;
	/** 'user' or 'role' */
	enum box_schema_object_type type;
	/**
	 * Authentication data or NULL if auth method is unset.
	 *
	 * XXX: Strictly speaking, this doesn't belong here.
	 * Ideally, we should store raw authentication data in
	 * the user_def struct while the authenticator should
	 * reside in the user struct.
	 */
	struct authenticator *auth;
	/**
	 * Last modification timestamp (seconds since UNIX epoch)
	 * or 0 if unknown.
	 */
	uint64_t last_modified;
	/** User name - for error messages and debugging */
	char *name;
};

/**
 * Allocates and initializes a new user definition.
 * This function never fails.
 */
struct user_def *
user_def_new(uint32_t uid, uint32_t owner, enum box_schema_object_type type,
	     const char *name, uint32_t name_len);

/** Destroys and frees a user definition. */
void
user_def_delete(struct user_def *def);

/** Predefined user ids. */
enum {
	BOX_SYSTEM_USER_ID_MIN = 0,
	GUEST = 0,
	ADMIN =  1,
	PUBLIC = 2, /* role */
	SUPER = 31, /* role */
	BOX_SYSTEM_USER_ID_MAX = PUBLIC
};

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
