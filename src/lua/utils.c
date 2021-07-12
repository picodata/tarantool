/*
 * Copyright 2010-2015, Tarantool AUTHORS, please see AUTHORS file.
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
#include "lua/utils.h"
#include <lj_trace.h>

#include <assert.h>
#include <errno.h>

#include <trivia/util.h>
#include <diag.h>
#include <fiber.h>

int luaL_nil_ref = LUA_REFNIL;
static int CTID_CONST_STRUCT_ERROR_REF = 0;

static int luaT_newthread_ref = LUA_NOREF;

static uint32_t CTID_STRUCT_IBUF;
static uint32_t CTID_STRUCT_IBUF_PTR;
static uint32_t CTID_CHAR_PTR;
static uint32_t CTID_CONST_CHAR_PTR;

void *
luaL_pushcdata(struct lua_State *L, uint32_t ctypeid)
{
	/*
	 * ctypeid is actually has CTypeID type.
	 * CTypeId is defined somewhere inside luajit's internal
	 * headers.
	 */
	assert(sizeof(ctypeid) == sizeof(CTypeID));

	/* Code below is based on ffi_new() from luajit/src/lib_ffi.c */

	/* Get information about ctype */
	CTSize size;
	CTState *cts = ctype_cts(L);
	CTInfo info = lj_ctype_info(cts, ctypeid, &size);
	assert(size != CTSIZE_INVALID);

	/* Allocate a new cdata */
	GCcdata *cd = lj_cdata_new(cts, ctypeid, size);

	/* Anchor the uninitialized cdata with the stack. */
	TValue *o = L->top;
	setcdataV(L, o, cd);
	incr_top(L);

	/*
	 * lj_cconv_ct_init is omitted for non-structs because it actually
	 * does memset()
	 * Caveats: cdata memory is returned uninitialized
	 */
	if (ctype_isstruct(info)) {
		/* Initialize cdata. */
		CType *ct = ctype_raw(cts, ctypeid);
		lj_cconv_ct_init(cts, ct, size, cdataptr(cd), o,
				 (MSize)(L->top - o));
		/* Handle ctype __gc metamethod. Use the fast lookup here. */
		cTValue *tv = lj_tab_getinth(cts->miscmap, -(int32_t)ctypeid);
		if (tv && tvistab(tv) && (tv = lj_meta_fast(L, tabV(tv), MM_gc))) {
			GCtab *t = cts->finalizer;
			if (gcref(t->metatable)) {
				/* Add to finalizer table, if still enabled. */
				copyTV(L, lj_tab_set(L, t, o), tv);
				lj_gc_anybarriert(L, t);
				cd->marked |= LJ_GC_CDATA_FIN;
			}
		}
	}

	lj_gc_check(L);
	return cdataptr(cd);
}

int
luaL_iscdata(struct lua_State *L, int idx)
{
	return lua_type(L, idx) == LUA_TCDATA;
}

void *
luaL_checkcdata(struct lua_State *L, int idx, uint32_t *ctypeid)
{
	/* Calculate absolute value in the stack. */
	if (idx < 0)
		idx = lua_gettop(L) + idx + 1;

	if (lua_type(L, idx) != LUA_TCDATA) {
		*ctypeid = 0;
		luaL_error(L, "expected cdata as %d argument", idx);
		return NULL;
	}

	GCcdata *cd = cdataV(L->base + idx - 1);
	*ctypeid = cd->ctypeid;
	return (void *)cdataptr(cd);
}

uint32_t
luaL_ctypeid(struct lua_State *L, const char *ctypename)
{
	int idx = lua_gettop(L);
	/* This function calls ffi.typeof to determine CDataType */

	/* Get ffi.typeof function */
	luaL_loadstring(L, "return require('ffi').typeof");
	lua_call(L, 0, 1);
	/* FFI must exist */
	assert(lua_gettop(L) == idx + 1 && lua_isfunction(L, idx + 1));
	/* Push the first argument to ffi.typeof */
	lua_pushstring(L, ctypename);
	/* Call ffi.typeof() */
	lua_call(L, 1, 1);
	/* Returned type must be LUA_TCDATA with CTID_CTYPEID */
	uint32_t ctypetypeid;
	CTypeID ctypeid = *(CTypeID *)luaL_checkcdata(L, idx + 1, &ctypetypeid);
	assert(ctypetypeid == CTID_CTYPEID);

	lua_settop(L, idx);
	return ctypeid;
}

int
luaL_cdef(struct lua_State *L, const char *what)
{
	int idx = lua_gettop(L);
	(void) idx;
	/* This function calls ffi.cdef  */

	/* Get ffi.typeof function */
	luaL_loadstring(L, "return require('ffi').cdef");
	lua_call(L, 0, 1);
	/* FFI must exist */
	assert(lua_gettop(L) == idx + 1 && lua_isfunction(L, idx + 1));
	/* Push the argument to ffi.cdef */
	lua_pushstring(L, what);
	/* Call ffi.cdef() */
	return lua_pcall(L, 1, 0, 0);
}

void
luaL_setcdatagc(struct lua_State *L, int idx)
{
	/* Calculate absolute value in the stack. */
	if (idx < 0)
		idx = lua_gettop(L) + idx + 1;

	/* Code below is based on ffi_gc() from luajit/src/lib_ffi.c */

	/* Get cdata from the stack */
	assert(lua_type(L, idx) == LUA_TCDATA);
	GCcdata *cd = cdataV(L->base + idx - 1);

	/* Get finalizer from the stack */
	TValue *fin = lj_lib_checkany(L, lua_gettop(L));

#if !defined(NDEBUG)
	CTState *cts = ctype_cts(L);
	CType *ct = ctype_raw(cts, cd->ctypeid);
	(void) ct;
	assert(ctype_isptr(ct->info) || ctype_isstruct(ct->info) ||
	       ctype_isrefarray(ct->info));
#endif /* !defined(NDEBUG) */

	/* Set finalizer */
	lj_cdata_setfin(L, cd, gcval(fin), itype(fin));

	/* Pop finalizer */
	lua_pop(L, 1);
}

/**
 * A helper to register a single type metatable.
 */
void
luaL_register_type(struct lua_State *L, const char *type_name,
		   const struct luaL_Reg *methods)
{
	luaL_newmetatable(L, type_name);
	/*
	 * Conventionally, make the metatable point to itself
	 * in __index. If 'methods' contain a field for __index,
	 * this is a no-op.
	 */
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");
	lua_pushstring(L, type_name);
	lua_setfield(L, -2, "__metatable");
	luaL_register(L, NULL, methods);
	lua_pop(L, 1);
}

void
luaL_register_module(struct lua_State *L, const char *modname,
		     const struct luaL_Reg *methods)
{
	assert(methods != NULL && modname != NULL); /* use luaL_register instead */
	lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
	if (strchr(modname, '.') == NULL) {
		/* root level, e.g. box */
		lua_getfield(L, -1, modname); /* get package.loaded.modname */
		if (!lua_istable(L, -1)) {  /* module is not found */
			lua_pop(L, 1);  /* remove previous result */
			lua_newtable(L);
			lua_pushvalue(L, -1);
			lua_setfield(L, -3, modname);  /* _LOADED[modname] = new table */
		}
	} else {
		/* 1+ level, e.g. box.space */
		if (luaL_findtable(L, -1, modname, 0) != NULL)
			luaL_error(L, "Failed to register library");
	}
	lua_remove(L, -2);  /* remove _LOADED table */
	luaL_register(L, NULL, methods);
}

/*
 * Maximum integer that doesn't lose precision on tostring() conversion.
 * Lua uses sprintf("%.14g") to format its numbers, see gh-1279.
 */
#define DBL_INT_MAX (1e14 - 1)
#define DBL_INT_MIN (-1e14 + 1)

void
luaL_pushuint64(struct lua_State *L, uint64_t val)
{
#if defined(LJ_DUALNUM) /* see setint64V() */
	if (val <= INT32_MAX) {
		/* push int32_t */
		lua_pushinteger(L, (int32_t) val);
	} else
#endif /* defined(LJ_DUALNUM) */
	if (val <= DBL_INT_MAX) {
		/* push double */
		lua_pushnumber(L, (double) val);
	} else {
		/* push uint64_t */
		*(uint64_t *) luaL_pushcdata(L, CTID_UINT64) = val;
	}
}

void
luaL_pushint64(struct lua_State *L, int64_t val)
{
#if defined(LJ_DUALNUM) /* see setint64V() */
	if (val >= INT32_MIN && val <= INT32_MAX) {
		/* push int32_t */
		lua_pushinteger(L, (int32_t) val);
	} else
#endif /* defined(LJ_DUALNUM) */
	if (val >= DBL_INT_MIN && val <= DBL_INT_MAX) {
		/* push double */
		lua_pushnumber(L, (double) val);
	} else {
		/* push int64_t */
		*(int64_t *) luaL_pushcdata(L, CTID_INT64) = val;
	}
}

static inline int
luaL_convertint64(lua_State *L, int idx, bool unsignd, int64_t *result)
{
	uint32_t ctypeid;
	void *cdata;
	/*
	 * This code looks mostly like luaL_tofield(), but has less
	 * cases and optimized for numbers.
	 */
	switch (lua_type(L, idx)) {
	case LUA_TNUMBER:
		*result = lua_tonumber(L, idx);
		return 0;
	case LUA_TCDATA:
		cdata = luaL_checkcdata(L, idx, &ctypeid);
		switch (ctypeid) {
		case CTID_CCHAR:
		case CTID_INT8:
			*result = *(int8_t *) cdata;
			return 0;
		case CTID_INT16:
			*result = *(int16_t *) cdata;
			return 0;
		case CTID_INT32:
			*result = *(int32_t *) cdata;
			return 0;
		case CTID_INT64:
			*result = *(int64_t *) cdata;
			return 0;
		case CTID_UINT8:
			*result = *(uint8_t *) cdata;
			return 0;
		case CTID_UINT16:
			*result = *(uint16_t *) cdata;
			return 0;
		case CTID_UINT32:
			*result = *(uint32_t *) cdata;
			return 0;
		case CTID_UINT64:
			*result = *(uint64_t *) cdata;
			return 0;
		}
		*result = 0;
		return -1;
	case LUA_TSTRING:
	{
		const char *arg = luaL_checkstring(L, idx);
		char *arge;
		errno = 0;
		*result = (unsignd ? (long long) strtoull(arg, &arge, 10) :
			strtoll(arg, &arge, 10));
		if (errno == 0 && arge != arg)
			return 0;
		return 1;
	}
	}
	*result = 0;
	return -1;
}

uint64_t
luaL_checkuint64(struct lua_State *L, int idx)
{
	int64_t result;
	if (luaL_convertint64(L, idx, true, &result) != 0) {
		lua_pushfstring(L, "expected uint64_t as %d argument", idx);
		lua_error(L);
		return 0;
	}
	return result;
}

int64_t
luaL_checkint64(struct lua_State *L, int idx)
{
	int64_t result;
	if (luaL_convertint64(L, idx, false, &result) != 0) {
		lua_pushfstring(L, "expected int64_t as %d argument", idx);
		lua_error(L);
		return 0;
	}
	return result;
}

uint64_t
luaL_touint64(struct lua_State *L, int idx)
{
	int64_t result;
	if (luaL_convertint64(L, idx, true, &result) == 0)
		return result;
	return 0;
}

int64_t
luaL_toint64(struct lua_State *L, int idx)
{
	int64_t result;
	if (luaL_convertint64(L, idx, false, &result) == 0)
		return result;
	return 0;
}

struct error *
luaL_iserror(struct lua_State *L, int narg)
{
	assert(CTID_CONST_STRUCT_ERROR_REF != 0);
	if (lua_type(L, narg) != LUA_TCDATA)
		return NULL;

	uint32_t ctypeid;
	void *data = luaL_checkcdata(L, narg, &ctypeid);
	if (ctypeid != (uint32_t) CTID_CONST_STRUCT_ERROR_REF)
		return NULL;

	struct error *e = *(struct error **) data;
	assert(e->refs);
	return e;
}

static struct error *
luaL_checkerror(struct lua_State *L, int narg)
{
	struct error *error = luaL_iserror(L, narg);
	if (error == NULL)  {
		luaL_error(L, "Invalid argument #%d (error expected, got %s)",
		   narg, lua_typename(L, lua_type(L, narg)));
	}
	return error;
}

static int
luaL_error_gc(struct lua_State *L)
{
	struct error *error = luaL_checkerror(L, 1);
	error_unref(error);
	return 0;
}

void
luaT_pusherror(struct lua_State *L, struct error *e)
{
	/*
	 * gh-1955 luaT_pusherror allocates Lua objects, thus it
	 * may trigger GC. GC may invoke finalizers which are
	 * arbitrary Lua code, potentially invalidating last error
	 * object, hence error_ref below.
	 *
	 * It also important to reference the error first and only
	 * then set the finalizer.
	 */
	error_ref(e);
	assert(CTID_CONST_STRUCT_ERROR_REF != 0);
	struct error **ptr = (struct error **) luaL_pushcdata(L,
		CTID_CONST_STRUCT_ERROR_REF);
	*ptr = e;
	lua_pushcfunction(L, luaL_error_gc);
	luaL_setcdatagc(L, -2);
}

int
luaT_error(lua_State *L)
{
	struct error *e = diag_last_error(&fiber()->diag);
	assert(e != NULL);
	luaT_pusherror(L, e);
	lua_error(L);
	unreachable();
	return 0;
}

int
luaT_toerror(lua_State *L)
{
	struct error *e = luaL_iserror(L, -1);
	if (e != NULL) {
		/* Re-throw original error */
		diag_add_error(&fiber()->diag, e);
	} else {
		/* Convert Lua error to a Tarantool exception. */
		diag_set(LuajitError, luaT_tolstring(L, -1, NULL));
	}
	return 1;
}

int
luaT_call(struct lua_State *L, int nargs, int nreturns)
{
	if (lua_pcall(L, nargs, nreturns, 0))
		return luaT_toerror(L);
	return 0;
}

int
luaT_cpcall(lua_State *L, lua_CFunction func, void *ud)
{
	if (lua_cpcall(L, func, ud))
		return luaT_toerror(L);
	return 0;
}

/**
 * This function exists because lua_tostring does not use
 * __tostring metamethod, and this metamethod has to be used
 * if we want to print Lua userdata correctly.
 */
const char *
luaT_tolstring(lua_State *L, int idx, size_t *len)
{
	if (!luaL_callmeta(L, idx, "__tostring")) {
		switch (lua_type(L, idx)) {
		case LUA_TNUMBER:
		case LUA_TSTRING:
			lua_pushvalue(L, idx);
			break;
		case LUA_TBOOLEAN: {
			int val = lua_toboolean(L, idx);
			lua_pushstring(L, val ? "true" : "false");
			break;
		}
		case LUA_TNIL:
			lua_pushliteral(L, "nil");
			break;
		default:
			lua_pushfstring(L, "%s: %p", luaL_typename(L, idx),
						     lua_topointer(L, idx));
		}
	}

	return lua_tolstring(L, -1, len);
}

box_ibuf_t *
luaT_toibuf(struct lua_State *L, int idx)
{
	if (lua_type(L, idx) != LUA_TCDATA)
		return NULL;
	uint32_t cdata_type;
	void *cdata = luaL_checkcdata(L, idx, &cdata_type);
	if (cdata_type == CTID_STRUCT_IBUF)
		return (box_ibuf_t *) cdata;
	if (cdata_type == CTID_STRUCT_IBUF_PTR && cdata != NULL)
		return *(box_ibuf_t **) cdata;
	return NULL;
}

int
luaL_checkconstchar(struct lua_State *L, int idx, const char **res,
		    uint32_t *cdata_type_p)
{
	if (lua_type(L, idx) != LUA_TCDATA)
		return -1;
	uint32_t cdata_type;
	void *cdata = luaL_checkcdata(L, idx, &cdata_type);
	if (cdata_type != CTID_CHAR_PTR && cdata_type != CTID_CONST_CHAR_PTR)
		return -1;
	*res = cdata != NULL ? *(const char **) cdata : NULL;
	*cdata_type_p = cdata_type;
	return 0;
}

/* Based on ffi_meta___call() from luajit/src/lib_ffi.c. */
static int
luaL_cdata_iscallable(lua_State *L, int idx)
{
	/* Calculate absolute value in the stack. */
	if (idx < 0)
		idx = lua_gettop(L) + idx + 1;

	/* Get cdata from the stack. */
	assert(lua_type(L, idx) == LUA_TCDATA);
	GCcdata *cd = cdataV(L->base + idx - 1);

	CTState *cts = ctype_cts(L);
	CTypeID id = cd->ctypeid;
	CType *ct = ctype_raw(cts, id);
	if (ctype_isptr(ct->info))
		id = ctype_cid(ct->info);

	/* Get ctype metamethod. */
	cTValue *tv = lj_ctype_meta(cts, id, MM_call);

	return tv != NULL;
}

int
luaL_iscallable(lua_State *L, int idx)
{
	/* Whether it is function. */
	int res = lua_isfunction(L, idx);
	if (res == 1)
		return 1;

	/* Whether it is cdata with metatype with __call field. */
	if (lua_type(L, idx) == LUA_TCDATA)
		return luaL_cdata_iscallable(L, idx);

	/* Whether it has metatable with __call field. */
	res = luaL_getmetafield(L, idx, "__call");
	if (res == 1)
		lua_pop(L, 1); /* Pop __call value. */
	return res;
}

lua_State *
luaT_state(void)
{
	return tarantool_L;
}

/**
 * @brief A wrapper for <lua_newthread> to be called via luaT_call
 * in luaT_newthread. Whether new Lua coroutine is created it is
 * returned on the top of the guest stack.
 * @param L is a Lua state
 * @sa <lua_newthread>
 */
static int
luaT_newthread_wrapper(struct lua_State *L)
{
	(void)lua_newthread(L);
	return 1;
}

struct lua_State *
luaT_newthread(struct lua_State *L)
{
	assert(luaT_newthread_ref != LUA_NOREF);
	lua_rawgeti(L, LUA_REGISTRYINDEX, luaT_newthread_ref);
	assert(lua_isfunction(L, -1));
	if (luaT_call(L, 0, 1) != 0)
		return NULL;
	struct lua_State *L1 = lua_tothread(L, -1);
	assert(L1 != NULL);
	return L1;
}

int
tarantool_lua_utils_init(struct lua_State *L)
{
	/* Get CTypeID for `struct error *' */
	int rc = luaL_cdef(L, "struct error;");
	assert(rc == 0);
	(void) rc;
	CTID_CONST_STRUCT_ERROR_REF = luaL_ctypeid(L, "const struct error &");
	assert(CTID_CONST_STRUCT_ERROR_REF != 0);

	/* Create NULL constant */
	*(void **) luaL_pushcdata(L, CTID_P_VOID) = NULL;
	luaL_nil_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	rc = luaL_cdef(L, "struct ibuf;");
	assert(rc == 0);
	(void) rc;
	CTID_STRUCT_IBUF = luaL_ctypeid(L, "struct ibuf");
	assert(CTID_STRUCT_IBUF != 0);
	CTID_STRUCT_IBUF_PTR = luaL_ctypeid(L, "struct ibuf *");
	assert(CTID_STRUCT_IBUF_PTR != 0);
	CTID_CHAR_PTR = luaL_ctypeid(L, "char *");
	assert(CTID_CHAR_PTR != 0);
	CTID_CONST_CHAR_PTR = luaL_ctypeid(L, "const char *");
	assert(CTID_CONST_CHAR_PTR != 0);

	lua_pushcfunction(L, luaT_newthread_wrapper);
	luaT_newthread_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

/*
 * XXX: There is already defined <panic> macro in say.h header
 * (included in diag.h). As a result the call below is misexpanded
 * and compilation fails with the corresponding error. To avoid
 * this error the macro is undefined since it's not used anymore
 * in scope of this translation unit.
 */
#undef panic

/**
 * This routine encloses the checks and actions to be done when
 * the running fiber yields the execution.
 * Since Tarantool fibers don't switch-over the way Lua coroutines
 * do the platform ought to notify JIT engine when one lua_State
 * substitutes another one. Furthermore fiber switch is forbidden
 * when GC hook (i.e. __gc metamethod) is running.
 */
void cord_on_yield(void)
{
	struct global_State *g = G(tarantool_L);
	/*
	 * XXX: Switching fibers while running the trace leads to
	 * code misbehaviour and failures, so stop its execution.
	 */
	if (unlikely(tvref(g->jit_base))) {
		/*
		 * XXX: mcode is executed only in scope of Lua
		 * world and one can obtain the corresponding Lua
		 * coroutine from the fiber storage.
		 */
		struct lua_State *L = fiber()->storage.lua.stack;
		assert(L != NULL);
		lua_pushfstring(L, "fiber %d is switched while running the"
				" compiled code (it's likely a function with"
				" a yield underneath called via LuaJIT FFI)",
				fiber()->fid);
		if (g->panic)
			g->panic(L);
		exit(EXIT_FAILURE);
	}
	/*
	 * Unconditionally abort trace recording whether fibers
	 * switch each other. Otherwise, further compilation may
	 * lead to a failure on any next compiler phase.
	 */
	lj_trace_abort(g);

	/*
	 * XXX: While running GC hook (i.e. __gc  metamethod)
	 * garbage collector is formally "stopped" since the
	 * memory penalty threshold is set to its maximum value,
	 * ergo incremental GC step is not triggered. Thereby,
	 * yielding the execution at this point leads to further
	 * running platform with disabled LuaJIT GC. The fiber
	 * doesn't get the execution back until it's ready, so
	 * in pessimistic scenario LuaJIT OOM might occur
	 * earlier. As a result fiber switch is prohibited when
	 * GC hook is active and the platform is forced to stop.
	 */
	if (unlikely(g->hookmask & HOOK_GC)) {
		struct lua_State *L = fiber()->storage.lua.stack;
		assert(L != NULL);
		lua_pushfstring(L, "fiber %d is switched while running GC"
				" finalizer (i.e. __gc metamethod)",
				fiber()->fid);
		if (g->panic)
			g->panic(L);
		exit(EXIT_FAILURE);
	}
}
