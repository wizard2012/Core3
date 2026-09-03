/*
 * FactionManager.h
 *
 *  Created on: Mar 17, 2011
 *      Author: crush
 */

#ifndef FACTIONMANAGER_H_
#define FACTIONMANAGER_H_

#include "FactionMap.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "templates/faction/FactionRanks.h"

class FactionManager : public Singleton<FactionManager>, public Logger, public Object {
	FactionMap factionMap;
	FactionRanks factionRanks;

public:
	FactionManager();

	static const int TEFTIMER = 300000;

	/**
	 * Loads faction configuration information from the faction manager lua file: managers/faction_manager.lua
	 * Loads faction ranks from datatable
	 * Sets up faction relationships
	 */
	void loadData();

	/**
	 * Awards points to the player based on the faction they killed.
	 * @pre: player locked
	 * @post: player locked
	 * @param player The player receiving the faction points for the kill.
	 * @param faction The string key of the faction that was killed.
	 * @param level The level of the mob that was killed
	 */
	void awardFactionStanding(CreatureObject* player, const String& factionName, int level);

	void awardSpaceFactionPoints(CreatureObject* player,  uint32 typeHash, const String& factionName, uint32 shipLevel, int totalShipmates, int imperialReward, int rebelReward);

	void awardPvpFactionPoints(TangibleObject* killer, CreatureObject* destructedObject);

	/**
	 * Gets a list of enemy factions to the faction passed to the method.
	 * @param faction The faction to check for enemies.
	 */
	SortedVector<String> getEnemyFactions(const String& faction);

	/**
	 * Gets a list of ally factions to the faction passed to the method.
	 * @param faction The faction to check for enemies.
	 */
	SortedVector<String> getAllyFactions(const String& faction);

	FactionMap* getFactionMap();

	String getRankName(int idx);
	int getRankCost(int rank);
	int getRankDelegateRatioFrom(int rank);
	int getRankDelegateRatioTo(int rank);
	int getFactionPointsCap(int rank);

	/**
	 * Promotes a player's faction rank by exactly one step.
	 * Hard-clamped: never sets a rank that is out of range for the loaded
	 * faction rank table (see B20 -- getFactionPointsCap returns -1 for any
	 * rank >= factionRanks.getCount(), which would drive faction standing to
	 * -1 if ever reached). No override/bypass parameter exists on purpose.
	 * @pre: player locked or lockable by this thread
	 * @post: player's factionRank unchanged if the clamp would be violated,
	 *        otherwise incremented by one and the client notified.
	 * @return true if the player was promoted, false if already at (or would
	 *         exceed) the highest loaded rank -- a safe no-op, not an error.
	 */
	bool promoteFactionRank(CreatureObject* player);

	bool isHighestRank(int rank) {
		return rank >= factionRanks.getCount() - 1 || rank >= 15;
	}

	bool isFaction(const String& faction);
	bool isEnemy(const String& faction1, const String& faction2);
	bool isAlly(const String& faction1, const String& faction2);

	String getSpaceFactionBySquadron(int spaceSquadron, int tier);
	uint32 getSpaceFactionHashBySquadron(int spaceSquadron, int tier);

protected:
	void loadFactionRanks();
	void loadLuaConfig(String file);
};

#endif /* FACTIONMANAGER_H_ */
