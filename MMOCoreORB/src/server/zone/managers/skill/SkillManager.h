/*
				Copyright <SWGEmu>
		See file COPYING for copying conditions.
*/

#ifndef SKILLMANAGER_H_
#define SKILLMANAGER_H_

#include "server/zone/objects/player/variables/Ability.h"
#include "server/zone/objects/creature/variables/Skill.h"

class PerformanceManager;
class TransactionLog;

namespace server {
namespace zone {
namespace objects {
namespace creature {
	class CreatureObject;
}
}
}
}

using namespace server::zone::objects::creature;

namespace server {
namespace zone {
namespace objects {
namespace player {
	class PlayerObject;
}
}
}
}

using namespace server::zone::objects::player;

namespace server {
namespace zone {
namespace managers {
namespace skill {

class SkillManager : public Singleton<SkillManager>, public Logger, public Object {
	PerformanceManager* performanceManager;

	HashTable<String, Reference<Ability*> > abilityMap;
	HashTable<uint32, Reference<Skill*> > skillMap;

	Reference<Skill*> rootNode;

	VectorMap<String, int> defaultXpLimits;

	VectorMap<uint32, int> droidProgramSizes;

	SortedVector<String> droidCommands;

	bool apprenticeshipEnabled;

	// Applied to every skill's xpCost in loadClientData(). See skill_manager.lua for why
	// this exists (small private population) and what a missing/invalid value means.
	float xpCostMultiplier;

	// Exact skill names (Squad Leader tree) whose skillPointsRequired is zeroed out in
	// loadClientData(). Loaded from squadLeaderZeroPointSkills in skill_manager.lua; see
	// that file for why an exact list, and Skill::setSkillPointsRequired for why this is
	// done at load time rather than as a check-time special case. Empty (exempts nothing)
	// if the config table is missing or malformed.
	SortedVector<String> zeroPointCostSkills;

	/**
	 * Performs the actual grant bookkeeping for a skill once all checks have passed:
	 * skill points/XP withdrawal, ability/schematic/modifier grants, badge/level/group
	 * updates, and the client delta update. Shared by awardSkill() (which walks
	 * prerequisites and enforces cost/points) and forceAwardSkill() (which does not).
	 * Always returns true -- extracted verbatim from the tail of awardSkill(), no
	 * behaviour change. noXpRequired mirrors awardSkill()'s own parameter: forceAwardSkill()
	 * always passes false (it always charges XP normally; the only thing it skips is the
	 * prerequisite walk and canLearnSkill() check).
	 */
	bool grantSkillEffects(Skill* skill, CreatureObject* creature, bool notifyClient, TransactionLog& trx, bool noXpRequired);

public:
	SkillManager();
	~SkillManager();

	static int includeFile(lua_State* L);
	static int addSkill(lua_State* L);

	void loadLuaConfig();
	void loadClientData();
	void loadFromLua();
	void loadSkill(LuaObject* skill);
	void loadXpLimits();

	void addAbility(PlayerObject* ghost, const String& abilityName, bool notifyClient = true);
	void removeAbility(PlayerObject* ghost, const String& abilityName, bool notifyClient = true);

	void addAbilities(PlayerObject* ghost, const Vector<String>& abilityNames, bool notifyClient = true);
	void removeAbilities(PlayerObject* ghost, const Vector<String>& abilityNames, bool notifyClient = true);

	void addDroidCommands(PlayerObject* ghost, const Vector<String>& abilityNames, bool notifyClient = true);
	void removeDroidCommands(PlayerObject* ghost);

	bool awardSkill(const String& skillName, CreatureObject* creature, bool notifyClient = true, bool awardRequiredSkills = false, bool noXpRequired = false);

	/**
	 * Grants a single skill unconditionally: no prerequisite walk (and therefore no risk
	 * of cascading into unrelated trees), no canLearnSkill() cost/points check. Used for
	 * onboarding grants (e.g. free Squad Leader novice on character creation) where the
	 * skill must always be granted regardless of what the character does or doesn't hold.
	 * Returns false only if the skill name doesn't exist. Returns true immediately (no-op)
	 * if the creature already has the skill.
	 */
	bool forceAwardSkill(const String& skillName, CreatureObject* creature, bool notifyClient = true);

	void awardDraftSchematics(Skill* skill, PlayerObject* ghost, bool notifyClient = true);

	bool surrenderSkill(const String& skillName, CreatureObject* creature, bool notifyClient = true, bool verifyFrs = true, bool allowPilot = false);
	void surrenderAllSkills(CreatureObject* creature, bool notifyClient = true, bool removeForceProgression = true, bool removePilot = false);

	/**
	 * Checks if the player can learn the skill (fulfills skill prerequisites, enough skill points and enough XP).
	 * @param skillName the name of the skill to check if the player can learn.
	 * @param creature the player creature.
	 * @param noXpRequired XP check is skipped if this is set to true (used for character builder terminals and
	 * grant skill command).
	 * @return true if the player fulfills the requirements.
	 */
	bool canLearnSkill(const String& skillName, CreatureObject* creature, bool noXpRequired);

	/**
	 * Checks if the player fulfills the skill prerequisites and has enough XP for the skill.
	 * @param skillName the name of the skill to check.
	 * @param creature the player creature.
	 * @return true if the player fulfills the requirements.
	 */
	bool fulfillsSkillPrerequisitesAndXp(const String& skillName, CreatureObject* creature);

	/**
	 * Checks if the player fulfills the skill prerequisites.
	 * @param skillName the name of the skill to check.
	 * @param creature the player creature.
	 * @return true if the player fulfills the requirements.
	 */
	bool fulfillsSkillPrerequisites(const String& skillName, CreatureObject* creature);

	bool villageKnightPrereqsMet(CreatureObject* creature, const String& skillToDrop);

	int getForceSensitiveSkillCount(CreatureObject* creature, bool includeNoviceMasterBoxes);

	void updateXpLimits(PlayerObject* ghost);

	Skill* getSkill(const String& skillName) const {
		return skillMap.get(skillName.hashCode()).get();
	}

	Skill* getSkill(uint32 hashCode) const {
		return skillMap.get(hashCode).get();
	}

	Ability* getAbility(const String& abilityName) const {
		return abilityMap.get(abilityName).get();
	}

	PerformanceManager* getPerformanceManager() {
		return performanceManager;
	}

	inline bool isApprenticeshipEnabled() const {
		return apprenticeshipEnabled;
	}

	void removeSkillRelatedMissions(CreatureObject* creature, Skill* skill);

	int getDroidProgramSize(uint32 programHash) {
		return droidProgramSizes.get(programHash);
	}

	void getPlayerDroidCommands(PlayerObject* ghost, Vector<String>& playerDroidCommands);
};

}
}
}
}

using namespace server::zone::managers::skill;

#endif // SKILLMANAGER_H_
