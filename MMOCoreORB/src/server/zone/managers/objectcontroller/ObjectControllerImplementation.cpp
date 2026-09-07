/*
 * ObjectControllerImplementation.cpp
 *
 *  Created on: 11/08/2009
 *      Author: victor
 */

#include "server/zone/managers/objectcontroller/ObjectController.h"
#include "server/zone/managers/objectcontroller/command/CommandConfigManager.h"
#include "server/zone/managers/objectcontroller/command/CommandList.h"
#include "server/zone/managers/skill/SkillModManager.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/creature/variables/CooldownTimerMap.h"

void ObjectControllerImplementation::loadCommands() {
	configManager = new CommandConfigManager(server);
	queueCommands = new CommandList();

	info(true) << "Loading Queue Commands...";

	configManager->registerSpecialCommands(queueCommands);
	configManager->loadSlashCommandsFile();

	info(true) << "Loaded " << queueCommands->size() << " total commands";

	adminLog.setLoggingName("AdminCommands");

	StringBuffer fileName;
	fileName << "log/admin/admin.log";
	adminLog.setFileLogger(fileName.toString(), true);
	adminLog.setLogging(true);

	// LUA
	/*init();
	Luna<LuaCreatureObject>::Register(L);

	runFile("scripts/testscript.lua");*/
}

void ObjectControllerImplementation::finalize() {
	configManager = nullptr;
	queueCommands = nullptr;
}

bool ObjectControllerImplementation::transferObject(SceneObject* objectToTransfer, SceneObject* destinationObject, int containmentType, bool notifyClient, bool allowOverflow) {
	ManagedReference<SceneObject*> parent = objectToTransfer->getParent().get();

	if (parent == nullptr) {
		error("objectToTransfer parent is nullptr in ObjectManager::transferObject");
		return false;
	}

	uint32 oldContainmentType = objectToTransfer->getContainmentType();

	if (!destinationObject->transferObject(objectToTransfer, containmentType, notifyClient, allowOverflow)) {
		StringBuffer msg;
		msg << "could not add " << objectToTransfer->getLoggingName() << " to this object in ObjectManager::transferObject ";
		msg << "with containmentType: " << containmentType << " allowOverflow: " << allowOverflow << " destination container size:";
		msg << destinationObject->getContainerObjectsSize() << " slotted container size:" << destinationObject->getSlottedObjectsSize();

		destinationObject->error(msg.toString());

		parent->transferObject(objectToTransfer, oldContainmentType);

		return false;
	}

	return true;
}

float ObjectControllerImplementation::activateCommand(CreatureObject* object, unsigned int actionCRC, unsigned int actionCount, uint64 targetID, const UnicodeString& arguments) const {
	// Pre: object is wlocked
	// Post: object is wlocked

	const QueueCommand* queueCommand = getQueueCommand(actionCRC);

	float durationTime = 0.f;

	if (queueCommand == nullptr) {
		object->error() << "unregistered queue command 0x" << hex << actionCRC << " arguments: " << arguments.toString();

		return 0.f;
	}

	float commandTime = queueCommand->getCommandDuration(object, arguments);
	const String& characterAbility = queueCommand->getCharacterAbility();

	if (characterAbility.length() > 1) {
		object->debug() << "activating characterAbility " << characterAbility;

		if (object->isPlayerCreature()) {
			Reference<PlayerObject*> playerObject =  object->getSlottedObject("ghost").castTo<PlayerObject*>();

			if (!playerObject->hasAbility(characterAbility)) {
				object->clearQueueAction(actionCount, 0, 2);

				return 0.f;
			}
		}
	}

	uint32 commandGroup = queueCommand->getCommandGroup();

	if (commandGroup != 0) {
		if (commandGroup == 0xe1c9a54a && queueCommand->getQueueCommandName() != "attack") {
			if (!object->isAiAgent()) {
				object->clearQueueAction(actionCount, 0, 2);

				return 0.f;
			}
		}
	}

	if (queueCommand->requiresAdmin()) {
		try {
			if (object->isPlayerCreature()) {
				Reference<PlayerObject*> ghost = object->getSlottedObject("ghost").castTo<PlayerObject*>();

				if (ghost == nullptr || !ghost->hasGodMode() || !ghost->hasAbility(queueCommand->getQueueCommandName())) {
					adminLog.warning() << object->getDisplayedName() << " attempted to use the '/" << queueCommand->getQueueCommandName() << "' command without permissions";

					object->sendSystemMessage("@error_message:insufficient_permissions");
					object->clearQueueAction(actionCount, 0, 2);

					return 0.f;
				}
			} else {
				return 0.f;
			}

			logAdminCommand(object, queueCommand, targetID, arguments);
		} catch (const Exception& e) {
			Logger::error("Unhandled Exception logging admin commands" + e.getMessage());
		}
	}

	/// Add Skillmods if any
	for (int i = 0; i < queueCommand->getSkillModSize(); ++i) {
		String skillMod;
		int value = queueCommand->getSkillMod(i, skillMod);
		object->addSkillMod(SkillModManager::ABILITYBONUS, skillMod, value, false);
	}

	// Cooldown visibility (SWGWar, 2026-09-07). The named cooldowns a command
	// starts (rally, retreat, force of will, the innate abilities, gallop...)
	// were enforced and never reported, so the toolbar could only ever show
	// the attack-speed sweep. The creature's timers are snapshotted here and,
	// after a successful command, the longest one it started or extended is
	// sent as the client timer -- the icon's recharge. Core3.ShowCooldowns = 0
	// in the config turns it off; Core3.ShowCooldownsMaxSeconds caps it.
	bool showCooldowns = ConfigManager::instance()->getInt("Core3.ShowCooldowns", 1) != 0 && object->isPlayerCreature();
	VectorMap<String, uint64> cooldownsBefore;
	if (showCooldowns) {
		CooldownTimerMap* timers = object->getCooldownTimerMap();
		if (timers != nullptr)
			timers->snapshotFuture(cooldownsBefore);
	}

	int errorNumber = queueCommand->doQueueCommand(object, targetID, arguments);

#ifdef WITH_DEV_MODE
	if(object->isPlayerCreature()) {
		String name = "unknown";

		Reference<SceneObject*> targetObject = Core::getObjectBroker()->lookUp(targetID).castTo<SceneObject*>();

		if (targetObject != nullptr) {
			name = targetObject->getDisplayedName();

			if(targetObject->isPlayerCreature())
				name += "(Player)";
			else
				name += "(NPC)";
		} else {
			name = "(null)";
		}

		info(true) << "\033[32;40m" << object->getDisplayedName() << "(" << object->getObjectID() << ") /" << queueCommand->getQueueCommandName() << ": target=" << name << "; arguments=[" << arguments.toString() << "]; actionCount=" << actionCount << "; addToQueue= " << queueCommand->addToCombatQueue() << "\033[0m";
	}
#endif // WITH_DEV_MODE

	/// Remove Skillmods if any
	for (int i = 0; i < queueCommand->getSkillModSize(); ++i) {
		String skillMod;
		int value = queueCommand->getSkillMod(i, skillMod);
		object->addSkillMod(SkillModManager::ABILITYBONUS, skillMod, -value, false);
	}

	//onFail onComplete must clear the action from client queue
	if (errorNumber != QueueCommand::SUCCESS) {
		queueCommand->onFail(actionCount, object, errorNumber);
		return 0;
	} else {
		if (queueCommand->getDefaultPriority() != QueueCommand::IMMEDIATE) {
			durationTime = commandTime;
		}

		// The cooldown rides ONLY the packet the client draws. durationTime
		// itself is this function's return value, and CommandQueue pushes
		// the player's nextActionTime by it (CommandQueue.cpp, the "time > 0"
		// branch after activateCommand): inflating it would have locked the
		// player out of every command for the cooldown (verifier, 2026-09-07).
		float reportedTime = durationTime;
		if (showCooldowns) {
			CooldownTimerMap* timers = object->getCooldownTimerMap();
			if (timers != nullptr) {
				// Timers that are not an ability's recharge: the chat-shout
				// throttle (warcry, intimidate, form up... set it for 30 s
				// while the ability itself is usable at once) and the swing.
				Vector<String> ignore;
				ignore.add("command_message");
				ignore.add("autoAttackDelay");
				// The group MFD refresh timer (2 s) starts on a position update; a
				// command that moves the player synchronously (dismount, teleport)
				// would otherwise report a 2 s sweep that is nobody's recharge.
				ignore.add("groupMFDUpdate");
				float startedSeconds = timers->longestStartedSince(cooldownsBefore, ignore) / 1000.f;
				float cap = (float) ConfigManager::instance()->getInt("Core3.ShowCooldownsMaxSeconds", 600);
				// Only what outlasts the command itself, and never more than the cap.
				if (startedSeconds > reportedTime && startedSeconds <= cap) {
					reportedTime = startedSeconds;

					if (ConfigManager::instance()->getInt("Core3.ShowCooldownsLog", 0) != 0)
						object->info(true) << "cooldown shown: /" << queueCommand->getQueueCommandName() << " " << startedSeconds << " s";
				}
			}
		}

		queueCommand->onComplete(actionCount, object, reportedTime);
	}


	return durationTime;
}

void ObjectControllerImplementation::addQueueCommand(QueueCommand* command) {
	queueCommands->put(command);
}

const QueueCommand* ObjectControllerImplementation::getQueueCommand(const String& name) const {
	return queueCommands->getSlashCommand(name);
}

const QueueCommand* ObjectControllerImplementation::getQueueCommand(uint32 crc) const {
	return queueCommands->getSlashCommand(crc);
}

void ObjectControllerImplementation::logAdminCommand(SceneObject* object, const QueueCommand* queueCommand, uint64 targetID, const UnicodeString& arguments) const {
	String name = "unknown";

	Reference<SceneObject*> targetObject = Core::getObjectBroker()->lookUp(targetID).castTo<SceneObject*>();

	if (targetObject != nullptr) {
		name = targetObject->getDisplayedName();

		if(targetObject->isPlayerCreature())
			name += "(Player)";
		else
			name += "(NPC)";
	} else {
		name = "(null)";
	}

	adminLog.info() << object->getDisplayedName() << " used '/" << queueCommand->getQueueCommandName() << "' on " << name << " with params '" << arguments.toString() << "'";
}
