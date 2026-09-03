/*
				Copyright <SWGEmu>
		See file COPYING for copying conditions.*/

// SWGWar addition (faction-commands branch).
//
// Tracks at most one pending "/declareovert leave" countdown per player, keyed by
// CreatureObject objectID. This lets DeclareOvertCommand (a single, header-only,
// process-wide QueueCommand instance -- see CommandConfigManager::createCommand)
// and FactionOnLeaveTask (the delayed callback that actually applies
// FactionStatus::ONLEAVE) agree on whether a timer is already running for a given
// player, without adding any new persisted field to CreatureObject/PlayerObject or
// touching their .idl files.
//
// Semantics (owner-specified):
//   - A second "/declareovert leave" while one is already pending is a no-op --
//     it does not restart or stack the timer.
//   - "/declareovert" (go overt) cancels a pending on-leave timer outright.
//   - When the timer fires naturally, FactionOnLeaveTask removes its own entry.

#ifndef FACTIONONLEAVETASKREGISTRY_H_
#define FACTIONONLEAVETASKREGISTRY_H_

#include "engine/engine.h"

class FactionOnLeaveTaskRegistry {
public:
	// Registers task as the pending timer for playerID. Returns false (and leaves
	// the existing entry untouched) if a timer is already pending for that player.
	static bool trySet(uint64 playerID, Task* task) {
		Locker locker(&getMutex());

		VectorMap<uint64, Reference<Task*> >& map = getMap();

		if (map.find(playerID) != -1)
			return false;

		map.put(playerID, task);

		return true;
	}

	// Cancels and removes the pending timer for playerID, if any. Returns true if
	// there was one to cancel.
	static bool cancel(uint64 playerID) {
		Locker locker(&getMutex());

		VectorMap<uint64, Reference<Task*> >& map = getMap();

		int idx = map.find(playerID);

		if (idx == -1)
			return false;

		Reference<Task*> task = map.get(idx);

		map.drop(playerID);

		if (task != nullptr)
			task->cancel();

		return true;
	}

	// Removes playerID's entry without cancelling the task -- used by the task
	// itself once it has already run.
	static void clear(uint64 playerID) {
		Locker locker(&getMutex());

		getMap().drop(playerID);
	}

	static bool isPending(uint64 playerID) {
		Locker locker(&getMutex());

		return getMap().find(playerID) != -1;
	}

private:
	static Mutex& getMutex() {
		static Mutex mutex;

		return mutex;
	}

	static VectorMap<uint64, Reference<Task*> >& getMap() {
		static VectorMap<uint64, Reference<Task*> > map;

		return map;
	}
};

#endif // FACTIONONLEAVETASKREGISTRY_H_
