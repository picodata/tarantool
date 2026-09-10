/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "user.h"
#include "assoc.h"
#include "schema.h"
#include "space.h"
#include "func.h"
#include "index.h"
#include "bit/bit.h"
#include "fiber.h"
#include "scoped_guard.h"
#include "sequence.h"
#include "tt_static.h"
#include "txn.h"
#include "authentication.h"

struct universe universe;
static struct user users[BOX_USER_MAX];
struct user *guest_user = users;
struct user *admin_user = users + 1;

struct mh_i32ptr_t *user_registry;

enum {
	USER_ACCESS_FULL = (box_user_access_mask_t)~0,
};

/* {{{ user_set */

/** The capacity a set is given on the first insert. */
static const uint32_t USER_SET_CAPACITY_MIN = 4;

/** Initialize an empty set. */
static inline void
user_set_create(struct user_set *set)
{
	set->users = NULL;
	set->count = 0;
	set->capacity = 0;
}

/** Release the memory the set owns. */
static inline void
user_set_destroy(struct user_set *set)
{
	free(set->users);
	user_set_create(set);
}

/** The number of users in the set. */
static inline uint32_t
user_set_size(struct user_set *set)
{
	return set->count;
}

/** The user stored at the given position. */
static inline struct user *
user_set_at(struct user_set *set, uint32_t i)
{
	assert(i < set->count);
	return set->users[i];
}

/** The position of the user in the set, UINT32_MAX if absent. */
static uint32_t
user_set_find(struct user_set *set, struct user *user)
{
	for (uint32_t i = 0; i < set->count; i++) {
		if (set->users[i] == user)
			return i;
	}
	return UINT32_MAX;
}

/**
 * Add a user to the set. A grant of an already granted role
 * arrives as a plain update of the _priv tuple, and is applied
 * as another grant, so a repeated add has to be a no-op.
 */
static void
user_set_add(struct user_set *set, struct user *user)
{
	if (user_set_find(set, user) != UINT32_MAX)
		return;
	if (set->count == set->capacity) {
		set->capacity = set->capacity > 0 ? set->capacity * 2 :
				USER_SET_CAPACITY_MIN;
		set->users = (struct user **)
			xrealloc(set->users,
				 set->capacity * sizeof(*set->users));
	}
	set->users[set->count++] = user;
}

/** Remove a user from the set. */
static void
user_set_del(struct user_set *set, struct user *user)
{
	uint32_t i = user_set_find(set, user);
	if (i != UINT32_MAX)
		set->users[i] = set->users[--set->count];
}

/* }}} */

/* {{{ user_map */

/**
 * A set of users, keyed by user id. The role graph traversals
 * build their layers in it, so it holds no more members than
 * there are users and roles.
 */
struct user_map {
	struct mh_i32ptr_t *h;
};

/** Initialize an empty map. */
static inline void
user_map_create(struct user_map *map)
{
	map->h = mh_i32ptr_new();
}

/** Release the resources the map holds. */
static inline void
user_map_destroy(struct user_map *map)
{
	mh_i32ptr_delete(map->h);
	map->h = NULL;
}

/** Remove all the members of the map. */
static inline void
user_map_reset(struct user_map *map)
{
	mh_i32ptr_clear(map->h);
}

/** Exchange the contents of the two maps. */
static inline void
user_map_swap(struct user_map *lhs, struct user_map *rhs)
{
	struct mh_i32ptr_t *tmp = lhs->h;
	lhs->h = rhs->h;
	rhs->h = tmp;
}

/** Add a user to the map. */
static inline void
user_map_set(struct user_map *map, struct user *user)
{
	struct mh_i32ptr_node_t node = { user->def->uid, user };
	mh_i32ptr_put(map->h, &node, NULL, NULL);
}

/* Check if the user is in the map. */
static inline bool
user_map_is_set(struct user_map *map, struct user *user)
{
	return mh_i32ptr_find(map->h, user->def->uid, NULL) != mh_end(map->h);
}

/** Check if the map has no members. */
static inline bool
user_map_is_empty(struct user_map *map)
{
	return mh_size(map->h) == 0;
}

/**
 * Merge two sets of users: add all users from right argument
 * to the left one.
 */
static void
user_map_union(struct user_map *lhs, struct user_map *rhs)
{
	mh_int_t i;
	mh_foreach(rhs->h, i)
		mh_i32ptr_put(lhs->h, mh_i32ptr_node(rhs->h, i), NULL, NULL);
}

/** Replace the contents of the left map with a copy of the right one. */
static inline void
user_map_copy(struct user_map *lhs, struct user_map *rhs)
{
	user_map_reset(lhs);
	user_map_union(lhs, rhs);
}

/**
 * Iterate over users in the set of users. The map must not be
 * changed while an iterator over it is alive: a hash resize
 * moves the members an unfinished iterator has not seen yet.
 */
struct user_map_iterator
{
	struct mh_i32ptr_t *h;
	mh_int_t pos;
};

static void
user_map_iterator_init(struct user_map_iterator *it, struct user_map *map)
{
	it->h = map->h;
	it->pos = mh_first(it->h);
}

static struct user *
user_map_iterator_next(struct user_map_iterator *it)
{
	if (it->pos >= mh_end(it->h))
		return NULL;
	struct user *user = (struct user *)mh_i32ptr_node(it->h, it->pos)->val;
	it->pos = mh_next(it->h, it->pos);
	return user;
}

/** Add all the users of the set to the map. */
static void
user_map_add_users(struct user_map *map, struct user_set *set)
{
	for (uint32_t i = 0; i < user_set_size(set); i++)
		user_map_set(map, user_set_at(set, i));
}

/* }}} */

/* {{{ privset_t - set of effective privileges of a user */

extern "C" {

static int
priv_def_compare(const struct priv_def *lhs, const struct priv_def *rhs)
{
	if (lhs->object_type != rhs->object_type)
		return lhs->object_type > rhs->object_type ? 1 : -1;
	if (lhs->object_id != rhs->object_id)
		return lhs->object_id > rhs->object_id ? 1 : -1;
	return 0;
}

} /* extern "C" */

rb_gen(, privset_, privset_t, struct priv_def, link, priv_def_compare);

/* }}}  */

/** {{{ user */

/**
 * A role never acts, so it holds no authentication token: it
 * indexes nothing and lives outside the users[] array.
 */
static inline bool
user_is_role(const struct user *user)
{
	return user->def->type == BOX_SC_ROLE;
}

/** Take a free authentication token. */
static uint16_t
auth_token_get(void);

/** Give an authentication token back. */
static void
auth_token_put(uint16_t auth_token);

/**
 * Make a cache entry. A user is looked up by its authentication
 * token, so it lives in the array the token indexes; a role
 * takes no token and is allocated on its own.
 */
static struct user *
user_new(enum box_schema_object_type type)
{
	struct user *user;
	if (type == BOX_SC_ROLE) {
		user = (struct user *)xcalloc(1, sizeof(*user));
		user->auth_token = BOX_USER_MAX;
	} else {
		uint16_t auth_token = auth_token_get();
		user = users + auth_token;
		assert(user->auth_token == 0);
		user->auth_token = auth_token;
	}
	user_set_create(&user->users);
	user_set_create(&user->roles);
	access_map_create(&user->access);
	privset_new(&user->privs);
	region_create(&user->pool, &cord()->slabc);
	rlist_create(&user->credentials_list);
	return user;
}

/** Release a cache entry and whatever it was made of. */
static void
user_delete(struct user *user)
{
	bool is_role = user_is_role(user);
	if (!is_role)
		auth_token_put(user->auth_token);
	while (!rlist_empty(&user->credentials_list))
		rlist_shift(&user->credentials_list);
	/*
	 * Sic: we don't have to remove a deleted
	 * user from users set of roles, since
	 * to drop a user, one has to revoke
	 * all privileges from them first.
	 */
	user_set_destroy(&user->users);
	user_set_destroy(&user->roles);
	access_map_destroy(&user->access);
	region_destroy(&user->pool);
	user_def_delete(user->def);
	memset(user, 0, sizeof(*user));
	if (is_role)
		free(user);
}

/**
 * Add a privilege definition to the list
 * of effective privileges of a user.
 */
int
user_grant_priv(struct user *user, struct priv_def *def)
{
	struct priv_def *old = privset_search(&user->privs, def);
	if (old == NULL) {
		size_t size;
		old = region_alloc_object(&user->pool, typeof(*old), &size);
		if (old == NULL) {
			diag_set(OutOfMemory, size, "region_alloc_object",
				 "old");
			return -1;
		}
		*old = *def;
		privset_insert(&user->privs, old);
	} else {
		old->access |= def->access;
	}
	return 0;
}

/**
 * Find the grants on an object that keeps them in an access map:
 * a space, a function, a user or a role, or a sequence.
 * @param object_type Type of the object.
 * @param object_id Id of the object.
 * @retval NULL The object does not exist or keeps no map.
 * @retval not NULL The grants on the object.
 */
static struct access_map *
access_map_find(enum box_schema_object_type object_type, uint32_t object_id)
{
	switch (object_type) {
	case BOX_SC_SPACE:
	{
		struct space *space = space_by_id(object_id);
		return space != NULL ? &space->access : NULL;
	}
	case BOX_SC_FUNCTION:
	{
		struct func *func = func_by_id(object_id);
		return func != NULL ? &func->access : NULL;
	}
	case BOX_SC_USER:
	case BOX_SC_ROLE:
	{
		struct user *user = user_by_id(object_id);
		return user != NULL ? &user->access : NULL;
	}
	case BOX_SC_SEQUENCE:
	{
		struct sequence *seq = sequence_by_id(object_id);
		return seq != NULL ? &seq->access : NULL;
	}
	default:
		return NULL;
	}
}

struct access *
access_slot(enum box_schema_object_type object_type, uint32_t object_id,
	    uint32_t auth_token)
{
	/* A role holds no token, and never reaches a slot. */
	assert(auth_token < BOX_USER_MAX);
	switch (object_type) {
	case BOX_SC_UNIVERSE:
		return &universe.access[auth_token];
	case BOX_SC_ENTITY_SPACE:
	case BOX_SC_ENTITY_FUNCTION:
	case BOX_SC_ENTITY_USER:
	case BOX_SC_ENTITY_ROLE:
	case BOX_SC_ENTITY_SEQUENCE:
		return &entity_access_get(object_type)[auth_token];
	default:
		break;
	}
	struct access_map *map = access_map_find(object_type, object_id);
	return map != NULL ? access_map_slot(map, auth_token) : NULL;
}

box_user_access_mask_t
access_effective(enum box_schema_object_type object_type, uint32_t object_id,
		 uint32_t auth_token)
{
	struct access_map *map = access_map_find(object_type, object_id);
	if (map != NULL)
		return access_map_effective(map, auth_token);
	/*
	 * The universe and the entity classes keep a slot per token
	 * in an array rather than a map.
	 */
	struct access *access = access_slot(object_type, object_id,
					    auth_token);
	return access != NULL ? access->effective : 0;
}

/**
 * Reset effective access of the user in the
 * corresponding objects.
 */
static void
user_set_effective_access(struct user *user)
{
	/* A role keeps no slot on an object. */
	if (user_is_role(user))
		return;
	struct privset_iterator it;
	privset_ifirst(&user->privs, &it);
	struct priv_def *priv;
	while ((priv = privset_inext(&it)) != NULL) {
		struct access *access = access_slot(priv->object_type,
						    priv->object_id,
						    user->auth_token);
		/* Protect against a concurrent drop. */
		if (access == NULL)
			continue;
		access->effective = access->granted | priv->access;
	}
}

/**
 * Reload a single user privilege from a privilege tuple.
 */
static int
user_reload_priv(struct user *user, struct tuple *tuple)
{
	struct priv_def priv;
	if (priv_def_create_from_tuple(&priv, tuple) != 0)
		return -1;
	/**
	 * Skip role grants, we're only
	 * interested in real objects.
	 */
	if (priv.object_type != BOX_SC_ROLE ||
	    !(priv.access & BOX_PRIVILEGE_EXECUTE))
		return user_grant_priv(user, &priv);
	return 0;
}

/**
 * Reload user privileges and re-grant them. If a rolled back statement is
 * passed, the privileges are reloaded as part of the rollback process, so we
 * must account for the changes made by the statement and use the old data
 * (which will be the actual data after rollback).
 */
static int
user_reload_privs(struct user *user, struct txn_stmt *rolled_back_stmt)
{
	if (user->is_dirty == false)
		return 0;
	struct priv_def *priv;
	/**
	 * Reset effective access of the user in the
	 * corresponding objects to have
	 * only the stuff that it's granted directly.
	 */
	struct privset_iterator it;
	privset_ifirst(&user->privs, &it);
	while ((priv = privset_inext(&it)) != NULL) {
		priv->access = 0;
	}
	user_set_effective_access(user);
	region_free(&user->pool);
	privset_new(&user->privs);
	/* Load granted privs from _priv space. */
	{
		struct space *space = space_cache_find(BOX_PRIV_ID);
		if (space == NULL)
			return -1;
		char key[6];
		/** Primary key - by user id */
		if (!space_is_memtx(space)) {
			diag_set(ClientError, ER_UNSUPPORTED,
			          space->engine->name, "system data");
			return -1;
		}
		struct index *index = index_find(space, 0);
		if (index == NULL)
			return -1;
		mp_encode_uint(key, user->def->uid);

		struct iterator *it = index_create_iterator(index, ITER_EQ,
							       key, 1);
		if (it == NULL)
			return -1;
		IteratorGuard iter_guard(it);
		bool in_rollback = rolled_back_stmt != NULL;
		struct tuple *old_tuple = in_rollback ?
			rolled_back_stmt->old_tuple : NULL;
		struct tuple *new_tuple = in_rollback ?
			rolled_back_stmt->new_tuple : NULL;
		assert(!in_rollback || old_tuple != NULL || new_tuple != NULL);
		struct key_def *key_def = index->def->key_def;
		int cmp_old = old_tuple != NULL ?
			      tuple_compare_with_key(old_tuple, HINT_NONE, key,
						     1, HINT_NONE, key_def) : 0;
		int cmp_new = new_tuple != NULL && old_tuple == NULL ?
			      tuple_compare_with_key(new_tuple, HINT_NONE, key,
						     1, HINT_NONE, key_def) : 0;
		if (cmp_old != 0 || cmp_new != 0)
			in_rollback = false;
		assert(old_tuple == NULL || new_tuple == NULL ||
		       tuple_compare(new_tuple, HINT_NONE, old_tuple, HINT_NONE,
				     key_def) == 0);
		struct tuple *tuple;
		if (iterator_next(it, &tuple) != 0)
			return -1;
		while (tuple != NULL) {
			if (in_rollback && tuple == new_tuple) {
				tuple = old_tuple;
				if (tuple == NULL)
					goto next_tuple;
			}
			if (user_reload_priv(user, tuple) != 0)
				return -1;
next_tuple:
			if (iterator_next(it, &tuple) != 0)
				return -1;
		}
		if (in_rollback && new_tuple == NULL &&
		    user_reload_priv(user, old_tuple) != 0)
			return -1;
	}
	{
		/* Take into account privs granted through roles. */
		for (uint32_t i = 0; i < user_set_size(&user->roles); i++) {
			struct user *role = user_set_at(&user->roles, i);
			struct privset_iterator it;
			privset_ifirst(&role->privs, &it);
			struct priv_def *def;
			while ((def = privset_inext(&it))) {
				if (user_grant_priv(user, def) != 0)
					return -1;
			}
		}
	}
	user_set_effective_access(user);
	user->is_dirty = false;
	/* A role has no token, so no slot in the universe. */
	if (user_is_role(user))
		return 0;
	struct credentials *creds;
	box_user_access_mask_t new_access =
		universe.access[user->auth_token].effective;
	rlist_foreach_entry(creds, &user->credentials_list, in_user)
		creds->universal_access = new_access;
	return 0;
}

const char *
user_auth_method_name(const char *user_name, uint32_t user_name_len)
{
	struct user *user = user_find_by_name(user_name, user_name_len);
	struct authenticator *auth = user != NULL ? user->def->auth : NULL;
	return auth != NULL ? auth->method->name : NULL;
}

/** }}} */

/* {{{ authentication tokens */

/** A map to quickly look up free slots in users[] array. */
static umap_int_t tokens[USER_MAP_SIZE];

static inline int
auth_token_calc_idx(uint16_t auth_token, uint8_t *bit_no)
{
	*bit_no = auth_token & (UMAP_INT_BITS - 1);
	return auth_token / UMAP_INT_BITS;
}

/**
 * Index of the minimal element of the tokens array which
 * has an unused token.
 */
static int min_token_idx = 0;

/**
 * Find and return a spare authentication token.
 * Raise an exception when the maximal number of users
 * is reached (and we're out of tokens).
 */
static uint16_t
auth_token_get(void)
{
	uint8_t bit_no = 0;
	while (min_token_idx < USER_MAP_SIZE) {
		bit_no = __builtin_ffs(tokens[min_token_idx]);
		if (bit_no)
			break;
		min_token_idx++;
	}
	/*
	 * find-first-set returns bit index starting from 1,
	 * or 0 if no bit is set. Rebase the index to offset 0.
	 */
	uint32_t auth_token = bit_no > 0 ?
			      min_token_idx * UMAP_INT_BITS + bit_no - 1 :
			      BOX_USER_MAX;
	if (auth_token >= BOX_USER_MAX) {
		/*
		 * A cap on the number of users was reached. The
		 * map holds more tokens than the cap allows when
		 * the cap is not a multiple of the word size.
		 */
		tnt_raise(LoggedError, ER_USER_MAX, BOX_USER_MAX);
	}
	tokens[min_token_idx] ^= ((umap_int_t)1) << (bit_no - 1);
	return auth_token;
}

/**
 * Return an authentication token to the set of unused
 * tokens.
 */
static void
auth_token_put(uint16_t auth_token)
{
	uint8_t bit_no;
	int idx = auth_token_calc_idx(auth_token, &bit_no);
	tokens[idx] |= ((umap_int_t) 1) << bit_no;
	if (idx < min_token_idx)
		min_token_idx = idx;
}

/* }}} */

/* {{{ user cache */

struct user *
user_cache_replace(struct user_def *def)
{
	struct user *user = user_by_id(def->uid);
	if (user == NULL) {
		user = user_new(def->type);
		struct mh_i32ptr_node_t node = { def->uid, user };
		mh_i32ptr_put(user_registry, &node, NULL, NULL);
	} else {
		user_def_delete(user->def);
	}
	user->def = def;
	return user;
}

void
user_cache_delete(uint32_t uid)
{
	mh_int_t k = mh_i32ptr_find(user_registry, uid, NULL);
	if (k != mh_end(user_registry)) {
		struct user *user = (struct user *)
			mh_i32ptr_node(user_registry, k)->val;
		assert(user_set_is_empty(&user->roles));
		assert(user_set_is_empty(&user->users));
		assert(user_is_role(user) || user->auth_token > ADMIN);
		user_delete(user);
		/*
		 * Sic: we don't have to remove a deleted
		 * user from users hash of roles, since
		 * to drop a user, one has to revoke
		 * all privileges from them first.
		 */
		mh_i32ptr_del(user_registry, k, NULL);
	}
}

/** Find user by id. */
struct user *
user_by_id(uint32_t uid)
{
	mh_int_t k = mh_i32ptr_find(user_registry, uid, NULL);
	if (k == mh_end(user_registry))
		return NULL;
	return (struct user *) mh_i32ptr_node(user_registry, k)->val;
}

struct user *
user_find(uint32_t uid)
{
	struct user *user = user_by_id(uid);
	if (user != NULL && !user_is_role(user))
		return user;
	/* Name the role rather than the id the caller had. */
	diag_set(ClientError, ER_NO_SUCH_USER,
		 user != NULL ? user->def->name : int2str(uid));
	return NULL;
}

/** Find user by name. */
struct user *
user_find_by_name(const char *name, uint32_t len)
{
	uint32_t uid;
	if (schema_find_id(BOX_USER_ID, 2, name, len, &uid) != 0)
		return NULL;
	if (uid != BOX_ID_NIL) {
		struct user *user = user_by_id(uid);
		if (user != NULL && !user_is_role(user))
			return user;
	}
	diag_set(ClientError, ER_NO_SUCH_USER,
		 tt_cstr(name, MIN((uint32_t) BOX_INVALID_NAME_MAX, len)));
	return NULL;
}

void
user_cache_init(void)
{
	/** Mark all tokens as unused. */
	memset(tokens, 0xFF, sizeof(tokens));
	user_registry = mh_i32ptr_new();
	/*
	 * Solve a chicken-egg problem:
	 * we need a functional user cache entry for superuser to
	 * perform recovery, but the superuser credentials are
	 * stored in the snapshot. So, pre-create cache entries
	 * for 'guest' and 'admin' users here, they will be
	 * updated with snapshot contents during recovery.
	 */
	const char *name = "guest";
	struct user_def *def = user_def_new(GUEST, ADMIN, BOX_SC_USER,
					    name, strlen(name));
	/* Free def in a case of exception. */
	auto guest_def_guard = make_scoped_guard([=] { user_def_delete(def); });
	struct user *user = user_cache_replace(def);
	/* Now the user cache owns the def. */
	guest_def_guard.is_active = false;
	/* 0 is the auth token and user id by default. */
	assert(user->def->uid == GUEST && user->auth_token == GUEST);
	(void) user;

	name = "admin";
	def = user_def_new(ADMIN, ADMIN, BOX_SC_USER, name, strlen(name));
	auto admin_def_guard = make_scoped_guard([=] { user_def_delete(def); });
	user = user_cache_replace(def);
	admin_def_guard.is_active = false;
	/*
	 * For performance reasons, we do not always explicitly
	 * look at user id in access checks, while still need to
	 * ensure 'admin' user has full access to all objects in
	 * the universe.
	 *
	 * This is why  _priv table contains a record with grants
	 * of full access to universe to 'admin' user.
	 *
	 * Making a record in _priv table is, however,
	 * insufficient, since some checks are done at bootstrap,
	 * before _priv table is read (e.g. when we're
	 * bootstrapping a replica in applier fiber).
	 *
	 * When user_cache_init() is called, admin user access is
	 * not loaded yet (is 0), force global access.
	 */
	universe.access[ADMIN].effective = USER_ACCESS_FULL;
	/* ADMIN is both the auth token and user id for 'admin' user. */
	assert(user->def->uid == ADMIN && user->auth_token == ADMIN);
}

void
user_cache_free(void)
{
	if (user_registry == NULL)
		return;
	mh_int_t i;
	mh_foreach(user_registry, i) {
		user_delete((struct user *)
			    mh_i32ptr_node(user_registry, i)->val);
	}
	mh_i32ptr_delete(user_registry);
	user_registry = NULL;
}

/* }}} user cache */

/** {{{ roles */

/**
 * A handle on the role graph, whose edges are the role grants
 * kept in every user. It holds the sets a traversal builds, so
 * that they are taken and given back once and the traversals
 * themselves own no resources.
 */
struct role_graph {
	/** The nodes a traversal has already passed. */
	struct user_map closure;
	/** The nodes of the layer being visited. */
	struct user_map current;
	/** The nodes to visit in the next layer. */
	struct user_map next;
};

static void
role_graph_create(struct role_graph *graph)
{
	user_map_create(&graph->closure);
	user_map_create(&graph->current);
	user_map_create(&graph->next);
}

static void
role_graph_destroy(struct role_graph *graph)
{
	user_map_destroy(&graph->next);
	user_map_destroy(&graph->current);
	user_map_destroy(&graph->closure);
}

/**
 * Check if the first role holds the second one, directly or
 * through the roles granted to it. Granting a role to someone
 * that already holds it closes a loop in the graph.
 */
static bool
role_has_role(struct role_graph *graph, struct user *role,
	      struct user *granted)
{
	user_map_reset(&graph->closure);
	user_map_set(&graph->closure, granted);
	user_map_copy(&graph->current, &graph->closure);
	while (!user_map_is_empty(&graph->current)) {
		/*
		 * As long as we're traversing a directed
		 * acyclic graph, we're bound to end at some
		 * point in a layer with no incoming edges.
		 */
		user_map_reset(&graph->next);
		struct user_map_iterator it;
		user_map_iterator_init(&it, &graph->current);
		struct user *user;
		while ((user = user_map_iterator_next(&it)))
			user_map_add_users(&graph->next, &user->users);
		user_map_union(&graph->closure, &graph->next);
		user_map_swap(&graph->current, &graph->next);
	}
	return user_map_is_set(&graph->closure, role);
}

int
role_check(struct user *grantee, struct user *role)
{
	/*
	 * Granting the role to the grantee closes a loop if the
	 * role already holds the grantee.
	 */
	struct role_graph graph;
	role_graph_create(&graph);
	bool is_loop = role_has_role(&graph, role, grantee);
	role_graph_destroy(&graph);
	if (is_loop) {
		diag_set(ClientError, ER_ROLE_LOOP,
			  role->def->name, grantee->def->name);
		return -1;
	}
	return 0;
}

static int
role_graph_rebuild(struct role_graph *graph, struct user *grantee,
		   struct txn_stmt *rolled_back_stmt)
{
	/*
	 * Recurse over all roles to which grantee is granted
	 * and mark them as dirty - in need for rebuild.
	 */
	struct user_map_iterator it;
	struct user *user;
	user_map_reset(&graph->current);
	user_map_set(&graph->current, grantee);
	while (!user_map_is_empty(&graph->current)) {
		user_map_reset(&graph->next);
		user_map_iterator_init(&it, &graph->current);
		while ((user = user_map_iterator_next(&it))) {
			user->is_dirty = true;
			user_map_add_users(&graph->next, &user->users);
		}
		/*
		 * Switch to the nodes which are not in the set
		 * yet.
		 */
		user_map_swap(&graph->current, &graph->next);
	}
	/*
	 * Propagate effective privileges from the nodes with no
	 * roles left to rebuild to the remaining nodes. Every
	 * round ends at the nodes with no outgoing edges.
	 */
	user_map_reset(&graph->current);
	user_map_set(&graph->current, grantee);
	while (!user_map_is_empty(&graph->current)) {
		user_map_reset(&graph->next);
		user_map_iterator_init(&it, &graph->current);
		while ((user = user_map_iterator_next(&it))) {
			bool is_ready = true;
			for (uint32_t i = 0; i < user_set_size(&user->roles);
			     i++) {
				struct user *role =
					user_set_at(&user->roles, i);
				if (role->is_dirty) {
					is_ready = false;
					user_map_set(&graph->next, role);
				}
			}
			if (is_ready) {
				if (user_reload_privs(user,
						      rolled_back_stmt) != 0)
					return -1;
				user_map_add_users(&graph->next, &user->users);
			} else {
				/*
				 * The user has roles whose
				 * effective grants have not been
				 * calculated yet. Postpone
				 * evaluation of effective grants
				 * of this user till these roles'
				 * effective grants have been
				 * built.
				 */
				user_map_set(&graph->next, user);
			}
		}
		user_map_swap(&graph->current, &graph->next);
	}
	return 0;
}

/**
 * Re-calculate effective grants of the linked subgraph this user/role is a
 * part of. For the purpose of the rolled back statement, please refer to
 * `user_reload_privs`.
 */
int
rebuild_effective_grants(struct user *grantee,
			 struct txn_stmt *rolled_back_stmt)
{
	struct role_graph graph;
	role_graph_create(&graph);
	int rc = role_graph_rebuild(&graph, grantee, rolled_back_stmt);
	role_graph_destroy(&graph);
	return rc;
}


/**
 * Update verges in the graph of dependencies.
 * Grant all effective privileges of the role to whoever
 * this role was granted to.
 */
int
role_grant(struct user *grantee, struct user *role)
{
	user_set_add(&role->users, grantee);
	user_set_add(&grantee->roles, role);
	if (rebuild_effective_grants(grantee, NULL) != 0)
		return -1;
	return 0;
}

/**
 * Update the role dependencies graph.
 * Rebuild effective privileges of the grantee.
 */
int
role_revoke(struct user *grantee, struct user *role)
{
	user_set_del(&role->users, grantee);
	user_set_del(&grantee->roles, role);
	if (rebuild_effective_grants(grantee, NULL) != 0)
		return -1;
	return 0;
}

int
priv_grant(struct user *grantee, struct priv_def *priv,
	   struct txn_stmt *rolled_back_stmt)
{
	if (!user_is_role(grantee)) {
		struct access *access = access_slot(priv->object_type,
						    priv->object_id,
						    grantee->auth_token);
		if (access == NULL)
			return 0;
		if (grantee->auth_token == ADMIN &&
		    priv->object_type == BOX_SC_UNIVERSE &&
		    priv->access != USER_ACCESS_FULL) {
			diag_set(ClientError, ER_GRANT,
				 "can't revoke universe from the admin user");
			return -1;
		}
		access->granted = priv->access;
	}
	if (rebuild_effective_grants(grantee, rolled_back_stmt) != 0)
		return -1;
	return 0;
}

/** }}} */

void
credentials_create(struct credentials *cr, struct user *user)
{
	/* Nothing runs as a role, so nothing caches one. */
	assert(!user_is_role(user));
	cr->auth_token = user->auth_token;
	cr->universal_access =
		universe.access[user->auth_token].effective;
	cr->uid = user->def->uid;
	rlist_add_entry(&user->credentials_list, cr, in_user);
}

void
credentials_create_empty(struct credentials *cr)
{
	cr->auth_token = BOX_USER_MAX;
	cr->universal_access = 0;
	cr->uid = BOX_USER_MAX;
	rlist_create(&cr->in_user);
}

void
credentials_destroy(struct credentials *cr)
{
	rlist_del_entry(cr, in_user);
}
