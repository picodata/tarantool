#include "lua.h"
#include "luajit/src/lauxlib.h"
#include "lua/utils.h"
#include "box/lua/misc.h"

/* A dummy export to make lua side know that WAL_EXT is enabled */
static int
cfg_set_wal_ext(struct lua_State *L)
{
	lua_settop(L, 0);
	return luaL_error(L, "setting WAL_EXT dynamically"
			  " is not supported in picodata's tarantool fork");
}

void
box_lua_wal_ext_init(struct lua_State *L)
{
	static const struct luaL_Reg wal_ext_internal[] = {
		{"cfg_set_wal_ext", cfg_set_wal_ext},
		{NULL, NULL}
	};

	luaL_findtable(L, LUA_GLOBALSINDEX, "box.internal", 0);
	luaL_setfuncs(L, wal_ext_internal, 0);
	lua_pop(L, 1);
}
