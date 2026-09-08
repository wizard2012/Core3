/*
 * WarTravel.h -- SWGWar B60 (owner rulings 2026-09-08): a town the other
 * side holds refuses a declared character its starport, its shuttleport and
 * its cloner, both ways. Design: docs/DESIGN-TRAVEL.md in the SWGWar repo.
 *
 * The war lives in Lua and MySQL; this is its one C++ reader. The exporter
 * writes scripts/custom_scripts/war/war_holders.txt beside war_state.lua
 * every tick, one line per town with a city:
 *     zone <TAB> city-token <TAB> holder <TAB> capital     e.g.  corellia  coronet  imperial  1
 * (capital = 1 when the town is its holder's own capital, from the sim's map)
 * where city-token is the last segment of the Core3 city-region name
 * ("@corellia_region_names:coronet" -> "coronet"). This singleton re-reads
 * the file when its mtime changes (checked at most every five seconds) and
 * keeps the last good table when the file is missing.
 *
 * Closed means: the player carries a faction, is not on leave, and the
 * holder is the other side. Neutrals, on-leave characters and cities the
 * war does not know are never closed. Header-only on purpose: the build's
 * source list is a configure-time glob, so a new .cpp would not be seen by
 * an incremental build.
 */

#ifndef WARTRAVEL_H_
#define WARTRAVEL_H_

#include <sys/stat.h>
#include <fstream>
#include <string>
#include <ctime>

#include "engine/engine.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/FactionStatus.h"
#include "server/zone/objects/region/CityRegion.h"
#include "server/zone/managers/planet/PlanetTravelPoint.h"
#include "templates/faction/Factions.h"
#include "templates/building/CloningBuildingObjectTemplate.h"

class WarTravel : public Logger {
	Mutex mutex;
	VectorMap<String, String> holders; // "zone|city" -> "imperial" / "rebel"
	VectorMap<String, String> capitals; // "zone|city" -> "1" when the city is its holder's capital
	time_t loadedMtime;
	time_t lastCheck;
	String path;

	WarTravel() : Logger("WarTravel"), loadedMtime(0), lastCheck(0), path("scripts/custom_scripts/war/war_holders.txt") {
		holders.setNoDuplicateInsertPlan();
		capitals.setNoDuplicateInsertPlan();
	}

	// Caller holds the mutex.
	void reloadIfChanged() {
		time_t now = time(nullptr);

		if (now - lastCheck < 5)
			return;

		lastCheck = now;

		struct stat st;

		if (stat(path.toCharArray(), &st) != 0)
			return; // missing: keep the last good table

		if (st.st_mtime == loadedMtime)
			return;

		std::ifstream in(path.toCharArray());

		if (!in.is_open())
			return;

		VectorMap<String, String> fresh;
		fresh.setNoDuplicateInsertPlan();
		VectorMap<String, String> freshCapitals;
		freshCapitals.setNoDuplicateInsertPlan();

		std::string line;

		while (std::getline(in, line)) {
			if (line.empty() || line[0] == '#')
				continue;

			size_t a = line.find('\t');

			if (a == std::string::npos)
				continue;

			size_t b = line.find('\t', a + 1);

			if (b == std::string::npos)
				continue;

			std::string rest = line.substr(b + 1);
			std::string capital;
			size_t c = rest.find('\t');

			if (c != std::string::npos) {
				capital = rest.substr(c + 1);
				rest = rest.substr(0, c);
			}

			String zone(line.substr(0, a).c_str());
			String city(line.substr(a + 1, b - a - 1).c_str());
			String holder(rest.c_str());

			holder = holder.replaceAll("\r", "");

			if (zone.isEmpty() || city.isEmpty() || holder.isEmpty())
				continue;

			fresh.put(zone + "|" + city, holder);

			if (!capital.empty() && capital[0] == '1')
				freshCapitals.put(zone + "|" + city, "1");
		}

		holders = fresh;
		capitals = freshCapitals;
		loadedMtime = st.st_mtime;

		info("loaded " + String::valueOf(holders.size()) + " cities from " + path, true);
	}

public:
	static WarTravel* instance() {
		static WarTravel inst;
		return &inst;
	}

	// "@corellia_region_names:coronet" -> "coronet"
	static String cityToken(CityRegion* city) {
		if (city == nullptr)
			return "";

		String name = city->getCityRegionName();
		int idx = name.lastIndexOf(':');

		if (idx >= 0)
			return name.subString(idx + 1);

		return name;
	}

	static String sideOf(CreatureObject* player) {
		if (player == nullptr)
			return "";

		uint32 f = player->getFaction();

		if (f == Factions::FACTIONIMPERIAL)
			return "imperial";

		if (f == Factions::FACTIONREBEL)
			return "rebel";

		return "";
	}

	static String sideName(const String& side) {
		if (side == "imperial")
			return "the Empire";

		if (side == "rebel")
			return "the Alliance";

		return "no one";
	}

	// The holder of a city by zone and token; "" when the war does not know it.
	String holderOf(const String& zone, const String& city) {
		Locker locker(&mutex);

		reloadIfChanged();

		String key = zone + "|" + city;

		if (!holders.contains(key))
			return "";

		return holders.get(key);
	}

	// The city is its holder's own capital (the sim's map, through the file).
	bool isCapitalCity(const String& zone, const String& city) {
		Locker locker(&mutex);

		reloadIfChanged();

		return capitals.contains(zone + "|" + city);
	}

	String holderOfCity(CityRegion* city) {
		if (city == nullptr)
			return "";

		Zone* zone = city->getZone();

		if (zone == nullptr)
			return "";

		return holderOf(zone->getZoneName(), cityToken(city));
	}

	// Closed: a declared character of the other side.
	bool isCityClosedTo(CreatureObject* player, CityRegion* city) {
		if (player == nullptr || city == nullptr)
			return false;

		String side = sideOf(player);

		if (side.isEmpty())
			return false; // neutral

		if (player->getFactionStatus() == FactionStatus::ONLEAVE)
			return false; // a civilian

		String holder = holderOfCity(city);

		if (holder.isEmpty())
			return false; // not a war town

		return holder != side;
	}

	bool isPointClosedTo(CreatureObject* player, PlanetTravelPoint* point) {
		if (player == nullptr || point == nullptr)
			return false;

		ManagedReference<CreatureObject*> shuttle = point->getShuttle();

		if (shuttle == nullptr)
			return false;

		ManagedReference<CityRegion*> city = shuttle->getCityRegion().get();

		return isCityClosedTo(player, city.get());
	}

	// "The Empire holds Coronet; its port and cloner serve the Empire now."
	String closedText(CityRegion* city) {
		String name = (city != nullptr) ? city->getRegionDisplayedName() : String("this town");
		String side = holderOfCity(city);

		if (side.isEmpty())
			return name + " is closed to you for now.";

		String holder = sideName(side);
		String cap = holder;

		if (!cap.isEmpty())
			cap = cap.subString(0, 1).toUpperCase() + cap.subString(1);

		return cap + " holds " + name + "; its port and cloner serve " + holder + " now.";
	}

	static String clonerName(SceneObject* cloner) {
		if (cloner == nullptr)
			return "None";

		ManagedReference<CityRegion*> city = cloner->getCityRegion().get();

		if (city != nullptr)
			return city->getRegionDisplayedName();

		return cloner->getDisplayedName();
	}

	// A friendly cloner on another planet (owner ruling: no new buildings).
	// "Nearest" between planets means: the side's own capitals first (the
	// holders file flags them), then the first open standard cloner in the
	// server's zone order. nullptr only when nothing is open anywhere.
	ManagedReference<SceneObject*> fallbackCloner(CreatureObject* player, ZoneServer* server) {
		if (player == nullptr || server == nullptr)
			return nullptr;

		String side = sideOf(player);

		for (int pass = 0; pass < 2; ++pass) {
			for (int i = 0; i < server->getZoneCount(); ++i) {
				Zone* zone = server->getZone(i);

				if (zone == nullptr || zone->isSpaceZone())
					continue;

				SortedVector<ManagedReference<SceneObject*> > list = zone->getPlanetaryObjectList("cloningfacility");

				for (int j = 0; j < list.size(); ++j) {
					ManagedReference<SceneObject*> loc = list.get(j);

					if (loc == nullptr)
						continue;

					CloningBuildingObjectTemplate* cbot = cast<CloningBuildingObjectTemplate*>(loc->getObjectTemplate());

					if (cbot == nullptr || cbot->isJediCloner())
						continue;

					if (cbot->getFacilityType() == CloningBuildingObjectTemplate::FACTION_IMPERIAL && side != "imperial")
						continue;

					if (cbot->getFacilityType() == CloningBuildingObjectTemplate::FACTION_REBEL && side != "rebel")
						continue;

					ManagedReference<CityRegion*> city = loc->getCityRegion().get();

					if (city != nullptr && city->isBanned(player->getObjectID()))
						continue;

					if (isCityClosedTo(player, city.get()))
						continue;

					if (pass == 0) {
						if (city == nullptr || !isCapitalCity(zone->getZoneName(), cityToken(city.get())))
							continue;
					}

					return loc;
				}
			}
		}

		return nullptr;
	}
};

#endif /* WARTRAVEL_H_ */
