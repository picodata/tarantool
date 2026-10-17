#include <lua.h>
#include <lauxlib.h>
#include <lj_obj.h>
#include "trivia/util.h"

struct allocation_test {
	lua_Alloc alloc;
	void *ud;
	int count;
	int fail_at;
	size_t fail_size;
	int failed;
	size_t sizes[512];
};

static void *
test_alloc(void *ud, void *ptr, size_t old_size, size_t size)
{
	struct allocation_test *test = ud;
	if (size != 0) {
		int index = test->count++;
		if (index < (int)lengthof(test->sizes))
			test->sizes[index] = size;
		if (!test->failed &&
		    (test->count == test->fail_at || size == test->fail_size)) {
			test->failed = 1;
			return NULL;
		}
	}
	return test->alloc(test->ud, ptr, old_size, size);
}

/* Call a real YAML operation, failing one allocation by its ordinal number. */
static int
call(lua_State *L)
{
	struct allocation_test test = {0};
	test.fail_at = luaL_checkinteger(L, 3);
	test.fail_size = luaL_optinteger(L, 4, 0);
	test.alloc = lua_getallocf(L, &test.ud);
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_setallocf(L, test_alloc, &test);
	int status = lua_pcall(L, 1, 1, 0);
	lua_setallocf(L, test.alloc, test.ud);
	/* Restore the allocator before checks or further Lua allocations. */
	lua_pushinteger(L, status);
	lua_pushboolean(L, test.failed);
	lua_newtable(L);
	int capacity = lengthof(test.sizes);
	if (test.count > capacity)
		return luaL_error(L, "too many allocations in YAML test");
	for (int i = 0; i < test.count; i++) {
		lua_pushinteger(L, test.sizes[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 4;
}

LUA_API int
luaopen_libyaml_oom(lua_State *L)
{
	lua_newtable(L);
	lua_pushcfunction(L, call);
	lua_setfield(L, -2, "call");
	lua_pushinteger(L, LUAL_BUFFERSIZE);
	lua_setfield(L, -2, "buffer_size");
	lua_pushinteger(L, sizeof(GCstr) + 1);
	lua_setfield(L, -2, "string_overhead");
	lua_pushinteger(L, sizeof(GCcdataVar) + sizeof(GCcdata));
	lua_setfield(L, -2, "varbinary_overhead");
	return 1;
}
