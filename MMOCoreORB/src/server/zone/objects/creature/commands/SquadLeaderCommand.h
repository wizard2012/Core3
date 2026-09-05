/*
 * SquadLeaderCommand.h
 *
 *  Created on: Aug 21, 2010
 *      Author: swgemu
 */

#ifndef SQUADLEADERCOMMAND_H_
#define SQUADLEADERCOMMAND_H_

#include "CombatQueueCommand.h"
#include "server/zone/objects/group/GroupObject.h"

class SquadLeaderCommand : public CombatQueueCommand {
protected:
	String action;
	uint32 actionCRC;

public:

	SquadLeaderCommand(const String& name, ZoneProcessServer* server) : CombatQueueCommand(name, server) {
		combatSpam = "";
		action = "";
		actionCRC = 0;
	}

	int doQueueCommand(CreatureObject* creature, const uint64& target, const UnicodeString& arguments) const {
		if (!checkStateMask(creature))
			return INVALIDSTATE;

		if (!checkInvalidLocomotions(creature))
			return INVALIDLOCOMOTION;

		return SUCCESS;
	}

	/**
	 * Is `target` a faction NPC that war_squad.lua has attached to `leader`?
	 *
	 * B27 slice 1 (custom_scripts/screenplays/warreport/war_squad.lua) hands a
	 * player up to 6 battle NPCs by calling AiAgent::setFollowObject(player) on
	 * each. That follow pointer is the ONLY marker of squad membership -- the
	 * troops are deliberately not adopted, not pets, and not group members, so
	 * that war_battle.lua's cleanup still owns their lifetime. Reading the same
	 * pointer here keeps a single source of truth instead of a second roster
	 * that could drift from it.
	 */
	static bool isFollowingTrooper(CreatureObject* leader, CreatureObject* target) {
		if (leader == nullptr || target == nullptr)
			return false;

		// Players and pets already have their own handling in
		// isValidGroupAbilityTarget; this predicate is only about war NPCs.
		if (target->isPlayerCreature() || target->isPet())
			return false;

		if (!target->isAiAgent())
			return false;

		AiAgent* agent = target->asAiAgent();

		if (agent == nullptr)
			return false;

		ManagedReference<SceneObject*> followCopy = agent->getFollowObject().get();

		if (followCopy == nullptr || followCopy != leader)
			return false;

		// Same faction only. Without this a leader would buff the very NPCs
		// they are fighting, since enemy troops at a contested site are also
		// AiAgents and can legitimately be following someone. Faction 0 is
		// neutral wildlife and never joins a squad.
		uint32 leaderFaction = leader->getFaction();

		if (leaderFaction == 0 || target->getFaction() != leaderFaction)
			return false;

		return true;
	}

	/**
	 * Every creature one Squad Leader ability should affect: the leader, their
	 * player group when they have one, and every faction NPC currently
	 * following them.
	 *
	 * WHY A COLLECTED LIST RATHER THAN group->getGroupMember(i) IN EACH
	 * COMMAND: the stock loops are bounded by getGroupSize(), so with no group
	 * the loop body never runs at all and followers could never be reached --
	 * relaxing the target predicate alone would have changed nothing.
	 */
	void collectSquadMembers(CreatureObject* leader, GroupObject* group, Vector<ManagedReference<CreatureObject*> >& members) const {
		if (leader == nullptr)
			return;

		members.add(leader);

		if (group != nullptr) {
			for (int i = 0; i < group->getGroupSize(); i++) {
				ManagedReference<CreatureObject*> member = group->getGroupMember(i);

				if (member == nullptr || member == leader)
					continue;

				members.add(member);
			}
		}

		if (leader->getZone() == nullptr)
			return;

		CloseObjectsVector* closeVector = (CloseObjectsVector*) leader->getCloseObjects();

		if (closeVector == nullptr)
			return;

		SortedVector<TreeEntry*> closeObjects;
		closeVector->safeCopyReceiversTo(closeObjects, CloseObjectsVector::CREOTYPE);

		for (int i = 0; i < closeObjects.size(); i++) {
			SceneObject* object = static_cast<SceneObject*>(closeObjects.get(i));

			if (object == nullptr || !object->isCreatureObject())
				continue;

			CreatureObject* creo = object->asCreatureObject();

			if (!isFollowingTrooper(leader, creo))
				continue;

			members.add(creo);
		}
	}

	/**
	 * Permissive replacement for checkGroupLeader: being ungrouped is now
	 * VALID. Owner's ruling -- a lone player at a front commands NPC troops,
	 * and requiring a player group to use the profession everyone now has
	 * would make the grant pointless. Still refuses a player who is in a group
	 * they do not lead, which is the one case the stock message is right about.
	 */
	bool checkSquadLeader(CreatureObject* player, GroupObject* group) const {
		if (player == nullptr)
			return false;

		if (group == nullptr)
			return true;

		if (group->getLeader() == nullptr || group->getLeader() != player) {
			player->sendSystemMessage("@error_message:not_group_leader");
			return false;
		}

		return true;
	}

	/**
	 * HAM-cost scale for a squad of `memberCount`. Same 1 + n/20 curve the
	 * stock calculateGroupModifier used, but driven by the collected squad
	 * size so NPC troops cost their commander something, and floored at 1 so
	 * that using an ability while ungrouped is never FREE -- the stock
	 * function returned 0 for a null group, which combined with the relaxed
	 * leader check would have made every ungrouped Squad Leader ability cost
	 * no HAM at all. (The stock checkGroupLeader / calculateGroupModifier
	 * pair had no callers left once the six commands moved to
	 * checkSquadLeader / calculateSquadModifier, and was removed.)
	 */
	float calculateSquadModifier(int memberCount) const {
		if (memberCount < 1)
			memberCount = 1;

		return 1.0f + ((float) memberCount / 20.0f);
	}

	static bool isValidGroupAbilityTarget(CreatureObject* leader, CreatureObject* target, bool allowPet) {

		if (target == nullptr || target->isDead() || target->isIncapacitated()) {
			return false;
		}

		// A followed faction NPC is a squad member regardless of `allowPet`.
		// It returns early because every remaining check below is written for
		// players: isHealableBy() consults player-only faction/duel state, and
		// the building check would drop troops standing outside a structure
		// their commander happens to be in.
		if (isFollowingTrooper(leader, target)) {
			return leader->getZone() == target->getZone();
		}

		if (allowPet) {
			if (!target->isPlayerCreature() && !target->isPet()) {
				return false;
			}
		} else if (!target->isPlayerCreature()) {
			return false;
		}

		if (target == leader)
			return true;

		if (leader->getZone() != target->getZone())
			return false;

		CreatureObject* targetCreo = target;

		if (allowPet && target->isPet()) {
			targetCreo = target->getLinkedCreature().get();

			if (targetCreo == nullptr)
				return false;
		}

		// Use healing checks
		if (!targetCreo->isHealableBy(leader))
			return false;

		if (target->getParentRecursively(SceneObjectType::BUILDING) != leader->getParentRecursively(SceneObjectType::BUILDING))
			return false;

		return true;
	}

/*	bool shoutCommand(CreatureObject* player, GroupObject* group) {
		if (player == nullptr || group == nullptr)
			return false;

		ManagedReference<ChatManager*> chatManager = server->getChatManager();
		if (chatManager == nullptr)
			return false;

		if (!player->getPlayerObject()->hasCommandMessageString(actionCRC))
			return false;

		UnicodeString shout = player->getPlayerObject()->getCommandMessageString(actionCRC);
		chatManager->broadcastMessage(player, shout, 0, 0, 80);

		return true;
	}
*/

	bool inflictHAM(CreatureObject* player, int health, int action, int mind) const {
		if (player == nullptr)
			return false;

		if (health < 0 || action < 0 || mind < 0)
			return false;

		if (player->getHAM(CreatureAttribute::ACTION) <= action || player->getHAM(CreatureAttribute::HEALTH) <= health || player->getHAM(CreatureAttribute::MIND) <= mind)
			return false;

		if (health > 0)
			player->inflictDamage(player, CreatureAttribute::HEALTH, health, true);

		if (action > 0)
			player->inflictDamage(player, CreatureAttribute::ACTION, action, true);

		if (mind > 0)
			player->inflictDamage(player, CreatureAttribute::MIND, mind, true);

		return true;
	}

	void sendCombatSpam(CreatureObject* player) const {
		if (player == nullptr)
			return;

		if (combatSpam == "")
			return;

		player->sendSystemMessage("@cbt_spam:" + combatSpam);
	}

/*    bool setCommandMessage(CreatureObject* creature, String message){
        if(!creature->isPlayerCreature())
            return false;

        ManagedReference<CreatureObject*> player = (creature);
        ManagedReference<PlayerObject*> playerObject = player->getPlayerObject();

		if (message.length()>128){
			player->sendSystemMessage("Your message can only be up to 128 characters long.");
			return false;
		}
		if (NameManager::instance()->isProfane(message)){
			player->sendSystemMessage("Your message has failed the profanity filter.");
			return false;
		}

        if(message.isEmpty()) {
            playerObject->removeCommandMessageString(actionCRC);
			player->sendSystemMessage("Your message has been removed.");
		} else {
            playerObject->setCommandMessageString(actionCRC, message);
			player->sendSystemMessage("Your message was set to :-\n" + message);
		}

        return true;
    }
*/

	bool isSquadLeaderCommand() {
		return true;
	}

	float getCommandDuration(CreatureObject* object, const UnicodeString& arguments) const {
		return defaultTime;
	}

	const String& getAction() const {
		return action;
	}

	void setAction(String action) {
		this->action = action;
	}
};

#endif /* SQUADLEADERCOMMAND_H_ */
