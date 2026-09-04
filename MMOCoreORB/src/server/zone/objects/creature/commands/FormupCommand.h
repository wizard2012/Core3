/*
				Copyright <SWGEmu>
		See file COPYING for copying conditions.*/

#ifndef FORMUPCOMMAND_H_
#define FORMUPCOMMAND_H_

#include "SquadLeaderCommand.h"

class FormupCommand : public SquadLeaderCommand {
public:

	FormupCommand(const String& name, ZoneProcessServer* server)
		: SquadLeaderCommand(name, server) {
	}

	int doQueueCommand(CreatureObject* creature, const uint64& target, const UnicodeString& arguments) const {

		if (!checkStateMask(creature))
			return INVALIDSTATE;

		if (!checkInvalidLocomotions(creature))
			return INVALIDLOCOMOTION;

		if (!creature->isPlayerCreature())
			return GENERALERROR;

		ManagedReference<CreatureObject*> player = cast<CreatureObject*>(creature);

		if (player == nullptr)
			return GENERALERROR;

		ManagedReference<PlayerObject*> ghost = player->getPlayerObject();

		if (ghost == nullptr)
			return GENERALERROR;

		ManagedReference<GroupObject*> group = player->getGroup();

		if (!checkSquadLeader(player, group))
			return GENERALERROR;

		// B27: the squad is the leader, their player group when they have one,
		// and every faction NPC following them. Collected ONCE and reused for
		// both cost and effect so the HAM charged matches who is buffed.
		Vector<ManagedReference<CreatureObject*> > squadMembers;
		collectSquadMembers(player, group, squadMembers);

		int hamCost = (int) (50.0f * calculateSquadModifier(squadMembers.size()));

		int healthCost = creature->calculateCostAdjustment(CreatureAttribute::STRENGTH, hamCost);
		int actionCost = creature->calculateCostAdjustment(CreatureAttribute::QUICKNESS, hamCost);
		int mindCost = creature->calculateCostAdjustment(CreatureAttribute::FOCUS, hamCost);

		if (!inflictHAM(player, healthCost, actionCost, mindCost))
			return GENERALERROR;

//		shoutCommand(player, group);

		if (!doFormUp(player, squadMembers))
			return GENERALERROR;

		if (!ghost->getCommandMessageString(STRING_HASHCODE("formup")).isEmpty() && creature->checkCooldownRecovery("command_message")) {
			UnicodeString shout(ghost->getCommandMessageString(STRING_HASHCODE("formup")));
 	 	 	server->getChatManager()->broadcastChatMessage(player, shout, 0, 80, player->getMoodID(), 0, ghost->getLanguageID());
 	 	 	creature->updateCooldownTimer("command_message", 30 * 1000);
		}

		return SUCCESS;
	}

	bool doFormUp(CreatureObject* leader, const Vector<ManagedReference<CreatureObject*> >& members) const {
		if (leader == nullptr)
			return false;

		for (int i = 0; i < members.size(); i++) {

			ManagedReference<CreatureObject*> member = members.get(i);

			if (member == nullptr)
				continue;

			if (!isValidGroupAbilityTarget(leader, member, false))
				continue;

			Locker clocker(member, leader);

			sendCombatSpam(member);

			if (member->isDizzied())
				member->removeStateBuff(CreatureState::DIZZY);
					
			if (member->isStunned())
				member->removeStateBuff(CreatureState::STUNNED);

			checkForTef(leader, member);
		}

		return true;
	}

};

#endif //FORMUPCOMMAND_H_
