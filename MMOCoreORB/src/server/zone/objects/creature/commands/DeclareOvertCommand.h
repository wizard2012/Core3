/*
				Copyright <SWGEmu>
		See file COPYING for copying conditions.*/

#ifndef DECLAREOVERTCOMMAND_H_
#define DECLAREOVERTCOMMAND_H_

#include "server/zone/objects/player/events/FactionOnLeaveTask.h"
#include "server/zone/objects/player/events/FactionOnLeaveTaskRegistry.h"

// SWGWar addition (faction-commands branch), 2026-09.
//
// REMOVED VANILLA/STOCK CORE3 BEHAVIOUR -- read before assuming this is a bug:
// this command used to require `Core3.GCWManager.useCovertOvertSystem` to be
// enabled, require the player to currently be COVERT, and restrict use to
// within 50m of a friendly player-placed GCW base/HQ (walked the player's
// close-objects list, or a 50m getInRangeObjects scan, looking for a
// same-faction structure with isGCWBase()). None of that is a bug in this
// deployment's history -- it is intentionally gone, per an explicit owner
// ruling, because this is a private server that wants overt/covert flipped on
// demand. If another emulator's docs or a vanilla-behaviour comparison says
// this command should be gated, that gate was here and was deliberately
// removed here, not missed.
//
// This command now also carries the owner's requested "/onleave" behaviour,
// because it can't ship as its own command -- see below.
//
//   /declareovert         -- go OVERT immediately. No HQ proximity, no
//                            useCovertOvertSystem() gate, no cooldown. Cancels
//                            a pending "/declareovert leave" timer if one is
//                            running.
//   /declareovert leave   -- start a (config-tunable, default 2 minute) timer
//                            after which FactionStatus::ONLEAVE is applied. A
//                            second "/declareovert leave" issued while one is
//                            already pending is a no-op (does not restart or
//                            stack the timer). See FactionOnLeaveTask.h /
//                            FactionOnLeaveTaskRegistry.h for the mechanics.
//
// WHY NOT LITERAL "/overt" AND "/onleave": a stock SWG client only transmits a
// typed slash command to the server if that exact name already has a row in
// the client's own command_tables_shared.iff (client .tre data this project
// does not control or ship). Server-side, CommandConfigManager::createCommand
// is only ever invoked either (a) once per row while iterating that same
// datatable in loadCommandData, or (b) via a short, explicit, hardcoded list of
// manual createCommand(...) calls in registerSpecialCommands (e.g. "logout",
// which the comment there notes the client already sends as a hardcoded part
// of its logout sequence -- not evidence that an arbitrary new name works).
// "declareovert" reaches neither path manually; it is only ever created via
// the IFF-row loop, meaning it has a real client-side row and is safely
// typeable today. A brand new "overt"/"onleave" factory registration with no
// corresponding client-side row would silently never reach the server -- the
// client errors locally on an unrecognised command and nothing is even sent.
// Per owner ruling, both behaviours are folded into this pre-existing,
// proven-reachable command instead, distinguished by an optional argument.
class DeclareOvertCommand : public QueueCommand {
public:

	DeclareOvertCommand(const String& name, ZoneProcessServer* server)
		: QueueCommand(name, server) {

	}

	int doQueueCommand(CreatureObject* creature, const uint64& target, const UnicodeString& arguments) const {
		if (!checkStateMask(creature))
			return INVALIDSTATE;

		if (!checkInvalidLocomotions(creature))
			return INVALIDLOCOMOTION;

		uint32 creatureFaction = creature->getFaction();

		if (creatureFaction == Factions::FACTIONNEUTRAL) {
			creature->sendSystemMessage("You must belong to a faction to use this command.");
			return GENERALERROR;
		}

		String argStr = arguments.toString().trim().toLowerCase();

		if (argStr == "leave")
			return doDeclareOnLeave(creature);

		return doDeclareOvert(creature);
	}

private:
	int doDeclareOvert(CreatureObject* creature) const {
		// /declareovert (no args) always wins over a pending on-leave timer --
		// owner ruling: going overt cancels a countdown to going on leave.
		FactionOnLeaveTaskRegistry::cancel(creature->getObjectID());

		Locker lock(creature);

		if (creature->getFactionStatus() == FactionStatus::OVERT) {
			creature->sendSystemMessage("You are already OVERT.");
			return SUCCESS;
		}

		creature->setFactionStatus(FactionStatus::OVERT);
		creature->sendSystemMessage("You have declared OVERT faction status.");

		return SUCCESS;
	}

	int doDeclareOnLeave(CreatureObject* creature) const {
		uint64 playerID = creature->getObjectID();

		if (creature->getFactionStatus() == FactionStatus::ONLEAVE) {
			creature->sendSystemMessage("You are already ONLEAVE.");
			return SUCCESS;
		}

		if (FactionOnLeaveTaskRegistry::isPending(playerID)) {
			creature->sendSystemMessage("You already have a faction leave timer running.");
			return SUCCESS;
		}

		Reference<Task*> task = new FactionOnLeaveTask(creature);

		// trySet can lose a race against another thread issuing the same command
		// at the same instant -- treat that identically to "already pending"
		// rather than scheduling a second timer.
		if (!FactionOnLeaveTaskRegistry::trySet(playerID, task)) {
			creature->sendSystemMessage("You already have a faction leave timer running.");
			return SUCCESS;
		}

		int delayMs = ConfigManager::instance()->getFactionOnLeaveDelayMs();

		task->schedule(delayMs);

		creature->sendSystemMessage("You will go ONLEAVE in " + String::valueOf(delayMs / 1000) + " seconds.");

		return SUCCESS;
	}
};

#endif //DECLAREOVERTCOMMAND_H_
