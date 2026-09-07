/*
 * CooldownTimerMap.h
 *
 *  Created on: 26/05/2010
 *      Author: victor
 */

#ifndef COOLDOWNTIMERMAP_H_
#define COOLDOWNTIMERMAP_H_

#include "engine/engine.h"

#include "engine/util/json_utils.h"

class CooldownTimer : public Variable {
	Time timeStamp;

public:
	CooldownTimer() : Variable() {
		//timeStamp = nullptr;
	}

	CooldownTimer(const Time& timestamp) : Variable() {
		timeStamp = timestamp;
	}

	CooldownTimer(const CooldownTimer& obj) : Variable() {
		timeStamp = obj.timeStamp;
	}

	CooldownTimer& operator=(const CooldownTimer& tim) {
		timeStamp = tim.timeStamp;

		return *this;
	}

	void operator=(Time obj) {
		timeStamp = obj;
	}

	bool toString(String& str) {
		timeStamp.toString(str);

		return true;
	}

	bool parseFromString(const String& str, int version = 0) {
		Time parsed;

		parsed.parseFromString(str);

		if (parsed.isPast())
			return false;

		timeStamp = parsed;

		return true;
	}

	bool toBinaryStream(ObjectOutputStream* stream) {
		timeStamp.toBinaryStream(stream);

		return true;
	}

	friend void to_json(nlohmann::json& j, const CooldownTimer& t) {
		j["timeStamp"] = t.timeStamp;
	}

	bool parseFromBinaryStream(ObjectInputStream* stream) {
		Time parsed;

		parsed.parseFromBinaryStream(stream);

		if (parsed.isPast())
			return false;

		timeStamp = parsed;

		return true;
	}

	bool isPast() const {
		return timeStamp.isPast();
	}

	void addMiliTime(uint64 mtime) {
		timeStamp.addMiliTime(mtime);
	}

	/*Time& get() {
		return timeStamp;
	}

	operator Time*() const {
		return &timeStamp;
	}*/

	Time* getTime() {
		return &timeStamp;
	}

	const Time* getTime() const {
		return &timeStamp;
	}
};

class CooldownTimerMap : public Object {
	HashTable<String, CooldownTimer> timers;
	mutable Mutex cooldownMutex;

public:
	CooldownTimerMap() : timers(1, 1) {
	}

	CooldownTimerMap(const CooldownTimerMap& map) : Object(), cooldownMutex() {
		timers = map.timers;
	}

	~CooldownTimerMap() {
	}

	CooldownTimerMap& operator=(const CooldownTimerMap& map) {
		if (this == &map)
			return *this;

		timers = map.timers;
		cooldownMutex = map.cooldownMutex;

		return *this;
	}

	bool isPast(const String& cooldownName) const {
		Locker locker(&cooldownMutex);

		auto entry = timers.getEntry(cooldownName);

		if (entry == nullptr)
			return true;

		return entry->getValue().isPast();
	}

	void updateToCurrentAndAddMili(const String& cooldownName, uint64 mili) {
		Locker locker(&cooldownMutex);

		Time* cooldown = updateToCurrentTime(cooldownName);

		cooldown->addMiliTime(mili);
	}

	Time* updateToCurrentTime(const String& cooldownName) {
		Locker locker(&cooldownMutex);

		if (!timers.containsKey(cooldownName)) {
			timers.put(cooldownName, Time());
		}

		Time* cooldown = timers.get(cooldownName).getTime();
		cooldown->updateToCurrentTime();

		return cooldown;
	}

	void addMiliTime(const String& cooldownName, uint64 mili) {
		Locker locker(&cooldownMutex);

		if (!timers.containsKey(cooldownName)) {
			timers.put(cooldownName, Time());
		}

		Time* cooldown = timers.get(cooldownName).getTime();
		cooldown->addMiliTime(mili);
	}

	const Time* getTime(const String& cooldownName) const {
		Locker locker(&cooldownMutex);

		auto entry = timers.getEntry(cooldownName);

		if (entry == nullptr)
			return nullptr;

		const Time* cooldown = entry->getValue().getTime();

		return cooldown;
	}

	/**
	 * Every timer still in the future, as name -> expiry in milliseconds.
	 * Cooldown visibility (SWGWar, 2026-09-07): the object controller takes
	 * one of these before a command runs and asks longestStartedSince()
	 * afterwards, so the cooldown the command started can be sent to the
	 * client as the command's timer (the toolbar icon's recharge sweep).
	 */
	void snapshotFuture(VectorMap<String, uint64>& out) const {
		Locker locker(&cooldownMutex);
		HashTableIterator<String, CooldownTimer> iterator = timers.iterator();
		String key;
		CooldownTimer value;
		for (int i = 0; i < timers.size(); ++i) {
			iterator.getNextKeyAndValue(key, value);
			Time* stamp = value.getTime();
			if (stamp != nullptr && !stamp->isPast())
				out.put(key, stamp->getMiliTime());
		}
	}

	/**
	 * The longest remaining time, in milliseconds, among the timers that
	 * were added or pushed further out since `before` (a snapshotFuture()
	 * result); 0 when the command started nothing.
	 */
	uint64 longestStartedSince(const VectorMap<String, uint64>& before) const {
		VectorMap<String, uint64> now;
		snapshotFuture(now);
		Time current;
		uint64 nowMs = current.getMiliTime();
		uint64 best = 0;
		for (int i = 0; i < now.size(); ++i) {
			const String& key = now.elementAt(i).getKey();
			uint64 expiry = now.elementAt(i).getValue();
			uint64 previous = before.contains(key) ? before.get(key) : 0;
			if (expiry > previous && expiry > nowMs) {
				uint64 remaining = expiry - nowMs;
				if (remaining > best)
					best = remaining;
			}
		}
		return best;
	}

	Object* clone() {
		return ObjectCloner<CooldownTimerMap>::clone(this);
	}

	Object* clone(void* object) {
		return TransactionalObjectCloner<CooldownTimerMap>::clone(this);
	}


};


#endif /* COOLDOWNTIMERMAP_H_ */
