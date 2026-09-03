/*
				Copyright <SWGEmu>
		See file COPYING for copying conditions.*/

// SWGWar addition (faction-commands branch). See FactionOnLeaveTaskRegistry.h for
// the cancel/no-restack bookkeeping this task participates in.

#ifndef FACTIONONLEAVETASK_H_
#define FACTIONONLEAVETASK_H_

#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/FactionStatus.h"
#include "server/zone/objects/player/events/FactionOnLeaveTaskRegistry.h"
#include "templates/faction/Factions.h"

namespace server {
namespace zone {
namespace objects {
namespace player {
namespace events {

class FactionOnLeaveTask : public Task {
	ManagedWeakReference<CreatureObject*> creature;
	uint64 playerID;

public:
	FactionOnLeaveTask(CreatureObject* creo) {
		creature = creo;
		playerID = creo->getObjectID();
	}

	void run() {
		// Whatever happens below, this timer is done -- clear our own bookkeeping
		// entry so a future /declareovert leave can schedule a fresh one.
		FactionOnLeaveTaskRegistry::clear(playerID);

		ManagedReference<CreatureObject*> player = creature.get();

		if (player == nullptr)
			return;

		Locker locker(player);

		// Player dropped their faction entirely (or was GM-reset) while the timer
		// was running -- nothing to apply.
		if (player->getFaction() == Factions::FACTIONNEUTRAL)
			return;

		// Already on leave by some other path -- nothing to do. (DeclareOvertCommand
		// cancels this task outright on /declareovert, so this is a defensive
		// check, not the primary guard against a stacked/duplicate timer -- that
		// guard is FactionOnLeaveTaskRegistry::trySet at schedule time.)
		if (player->getFactionStatus() == FactionStatus::ONLEAVE)
			return;

		player->setFactionStatus(FactionStatus::ONLEAVE);

		player->sendSystemMessage("Your faction leave has begun. You are now ONLEAVE.");
	}
};

}
}
}
}
}

using namespace server::zone::objects::player::events;

#endif // FACTIONONLEAVETASK_H_
