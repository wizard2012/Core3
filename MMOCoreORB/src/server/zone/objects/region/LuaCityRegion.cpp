
#include "server/zone/objects/region/LuaCityRegion.h"
#include "server/zone/objects/region/CityRegion.h"

const char LuaCityRegion::className[] = "LuaCityRegion";

Luna<LuaCityRegion>::RegType LuaCityRegion::Register[] = {
		{ "_setObject", &LuaCityRegion::_setObject },
		{ "_getObject", &LuaCityRegion::_getObject },
		{ "isClientRegion", &LuaCityRegion::isClientRegion },
		{ "getBazaarCount", &LuaCityRegion::getBazaarCount },
		{ "getBazaar", &LuaCityRegion::getBazaar },
		{ 0, 0 }
};

LuaCityRegion::LuaCityRegion(lua_State *L) {
	realObject = reinterpret_cast<CityRegion*>(lua_touserdata(L, 1));
}

LuaCityRegion::~LuaCityRegion() {
}

int LuaCityRegion::_getObject(lua_State* L) {
	if (realObject == nullptr)
		lua_pushnil(L);
	else
		lua_pushlightuserdata(L, realObject.get());

	return 1;
}

int LuaCityRegion::_setObject(lua_State* L) {
	realObject = reinterpret_cast<CityRegion*>(lua_touserdata(L, -1));

	return 0;
}

int LuaCityRegion::isClientRegion(lua_State* L) {
	bool val = realObject->isClientRegion();

	lua_pushboolean(L, val);

	return 1;
}

// Bazaar stocking (stage S1) -- see docs/DECISIONS.md
//
// getBazaarCount()/getBazaar(idx) are vanilla CityRegion.idl API with zero prior call
// sites. Verified: bazaars is a VectorMap<unsigned long, TangibleObject>, and
// VectorMap::get(int index) is an exact overload match for an int argument (no
// conversion needed), beating get(const unsigned long&) (which would need an int ->
// unsigned long conversion) -- so CityRegion::getBazaar(int idx) already does
// index-based enumeration, not key lookup. Confirmed against the running server by the
// bazaar_probe.lua screenplay (0..getBazaarCount()-1 all resolved to real terminals).
int LuaCityRegion::getBazaarCount(lua_State* L) {
	int count = realObject->getBazaarCount();

	lua_pushinteger(L, count);

	return 1;
}

int LuaCityRegion::getBazaar(lua_State* L) {
	int idx = lua_tointeger(L, -1);

	// Defect fix (post-S1 verifier pass): CityRegion::getBazaar(int) is upstream
	// (bazaars.get(idx), a VectorMap) and does not bounds-check -- an out-of-range or
	// negative index throws ArrayIndexOutOfBoundsException (ArrayList.h:577-578).
	// LuaFunction::callFunction only catches LuaPanicException, so that exception is
	// uncaught on the console `test` path and terminates the server outright, and on
	// the screenplay-task path it's caught but leaves the Lua VM mid-pcall and corrupt.
	// getBazaar() is our own wrapper file (in scope), so the bounds check belongs here
	// rather than touching the upstream CityRegion.idl method.
	int count = realObject->getBazaarCount();

	if (idx < 0 || idx >= count) {
		lua_pushnil(L);
		return 1;
	}

	TangibleObject* bazaar = realObject->getBazaar(idx);

	if (bazaar == nullptr)
		lua_pushnil(L);
	else
		lua_pushlightuserdata(L, bazaar);

	return 1;
}
