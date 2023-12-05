#include "lua.h"
#include "lib/core/mp_extension_types.h"
#include <lauxlib.h>

#include "lua/utils.h" /* luaT_error() */

#include "box/txn.h"

#include "box/lua/misc.h"
#include "box/lua/execute.h"
#include "box/wal_ext.h"

/* Enable or disable wal extensions */
static int
cfg_set_wal_ext(struct lua_State *L)
{
	char *error = "";

	if (luaL_dostring(L, "return box.cfg.wal_ext") != 0)
		panic("cfg_get('wal_ext')");

	bool is_table = lua_istable(L, -1);
	if (!is_table) {
		error = "wal_ext value must be a table";
		goto validation_error;
	}

	lua_pushnil(L);
	/* "wal_ext" table now at -2 */
	while (lua_next(L, -2) != 0) {
		const char *key = lua_tostring(L, -2);

		/* key is an extension name */
		if (!lua_isboolean(L, -1)) {
			error = "extension value must be a boolean";
			goto validation_error;
		}
		bool value = lua_toboolean(L, -1);
		if (set_enable_extension(key, value) != 0) {
			error = "no such extension";
			goto validation_error;
		}

		/* pop a value */
		lua_pop(L, 1);
	}

	goto end;

validation_error:
	lua_settop(L, 0);
	return luaL_error(L, error);

end:
	lua_settop(L, 0);
	return 0;
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
