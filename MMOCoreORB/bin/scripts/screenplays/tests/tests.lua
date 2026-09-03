Tests = {}

function Tests:stop()
	writeSharedMemory("runTests", 0)
end

function Tests:start()
	writeSharedMemory("runTests", 1)
end

function Tests:addPlayer(spawnPoint)
	if readSharedMemory("testPlayer") ~= 0 then
		local player = getSceneObject(readSharedMemory("testPlayer"))
		SceneObject(player):destroyObjectFromWorld()
		deleteSharedMemory("testPlayer")
	end

	local player = spawnSceneObject("creature_test", "object/creature/player/human_male.iff", spawnPoint[1], spawnPoint[2], spawnPoint[3], 0, 0)

	if player == nil then
		AiAgent(agent):info("Error creating player (return nil) in Tests:aiMoveTest.")
		return
	end

	if not SceneObject(player):isPlayerCreature() then
		AiAgent(agent):info("Did not create a PlayerCreature in Tests:aiMoveTest.")
		SceneObject(player):destroyObjectFromWorld()
		return
	end

	writeSharedMemory("testPlayer", SceneObject(player):getObjectID())
end

function Tests:aiMoveTest()
	-- in a test zone, create a creature at a point, and have it move to another
	-- point. Do this outside (we can try to create an inside test later).
	local spawnPoint = getSpawnPoint("creature_test", 0, 0, 0, 100)
	local agent = spawnEventMobile("creature_test", "bark_mite", 0, spawnPoint[1], spawnPoint[2], spawnPoint[3], 0, 0)

	if agent == nil then
		AiAgent(agent):info("Error creating agent (return nil) in Tests:aiMoveTest.")
		return
	end

	if not SceneObject(agent):isAiAgent() then
		AiAgent(agent):info("Did not create an AiAgent in Tests:aiMoveTest.")
		SceneObject(agent):destroyObjectFromWorld()
		return
	end

	if AiAgent(agent):getNumberOfPlayersInRange() == 0 then
		Tests:addPlayer(spawnPoint)
	end

	AiAgent(agent):setAIDebug()

	AiAgent(agent):setAITemplate()
	AiAgent(agent):stopWaiting()
	AiAgent(agent):setFollowState(4) -- Patrolling

	local moveTarget = getSpawnPoint("creature_test", 10, 0, 0, 100)
	AiAgent(agent):setNextPosition(moveTarget[1],moveTarget[2],moveTarget[3], 0)
	AiAgent(agent):executeBehavior()
	AiAgent(agent):info("Pathing to: (" .. moveTarget[1] .. ", " .. moveTarget[2] .. ", " .. moveTarget[3] .. ")")
	
	local args = moveTarget[1] .. "," .. moveTarget[2] .. "," .. moveTarget[3]
	createEvent(2000, "Tests", "aiMoveEvent", agent, args)
end

function Tests:aiMoveEvent(agent, coords)
	if agent == nil then
		AiAgent(agent):info("nil AiAgent in Tests:aiMoveEvent().")
		return
	end

	if not SceneObject(agent):isAiAgent() then
		AiAgent(agent):info("agent is not an AiAgent in Tests:aiMoveEvent().");
		return
	end

	AiAgent(agent):info("Agent location: (" .. SceneObject(agent):getPositionX() .. ", " .. SceneObject(agent):getPositionZ() .. ", " .. SceneObject(agent):getPositionY() .. ")")

	if AiAgent(agent):getNumberOfPlayersInRange() == 0 then
		Tests:addPlayer(spawnPoint)
	end

	x, z, y = coords:match("([^,]+),([^,]+),([^,]+)")
	if SceneObject(agent):getDistanceToPosition(x, z, y) > 0.15 and readSharedMemory("runTests") == 1 then
		createEvent(2000, "Tests", "aiMoveEvent", agent, coords)
		AiAgent(agent):executeBehavior()
	else
		AiAgent(agent):info("Destination Reached.")
		SceneObject(agent):destroyObjectFromWorld()
	end
end

function Tests:aiAggroTest()
	-- in a test zone, create a creature at a point, and have it move to another
	-- point. Do this outside (we can try to create an inside test later).
	-- TODO: use creature_test zone (won't load due to being version 0013)
	local spawnPoint = getSpawnPoint("creature_test", 0, 0, 0, 100)
	local agent = spawnEventMobile("creature_test", "acklay", 0, spawnPoint[1], spawnPoint[2], spawnPoint[3], 0, 0)

	if agent == nil then
		AiAgent(agent):info("Error creating agent (return nil) in Tests:aiMoveTest.")
		return
	end

	if not SceneObject(agent):isAiAgent() then
		AiAgent(agent):info("Did not create an AiAgent in Tests:aiMoveTest.")
		SceneObject(agent):destroyObjectFromWorld()
		return
	end

	Tests:addPlayer(spawnPoint)

	AiAgent(agent):setAIDebug()

	AiAgent(agent):setAITemplate()
	AiAgent(agent):stopWaiting()
	AiAgent(agent):executeBehavior()

	AiAgent(agent):info("Starting aggro test.")

	createEvent(2000, "Tests", "aiAggroEvent", agent, "")
end

function Tests:aiAggroEvent(agent, args)
	if agent == nil then
		AiAgent(agent):info("nil AiAgent in Tests:aiAggroEvent().")
		return
	end

	if not SceneObject(agent):isAiAgent() then
		AiAgent(agent):info("agent is not an AiAgent in Tests:aiAggroEvent().");
		return
	end
	
	if readSharedMemory("testPlayer") ~= 0 then
		local player = getSceneObject(readSharedMemory("testPlayer"))
		if CreatureObject(player):isDead() or CreatureObject(player):isIncapacitated() then
			SceneObject(player):info("I have been killed!")
			SceneObject(player):destroyObjectFromWorld()
			return
		end
	end

	AiAgent(agent):info("Target OID: " .. AiAgent(agent):getTargetID() .. " FollowState: " .. AiAgent(agent):getFollowState())

	if AiAgent(agent):getTargetID() == 0 and readSharedMemory("runTests") == 1 then
		createEvent(2000, "Tests", "aiAggroEvent", agent, "")
	else
		if AiAgent(agent):getTargetID() > 0 then AiAgent(agent):info("Acklay Aggroed.") end
		SceneObject(agent):destroyObjectFromWorld()
	end
end

--------------------------------------------------------------------------
-- Phase 1 synthetic population (D15 / docs/DESIGN-POPULATION.md S10) --
-- server-side acceptance, driven via `screen -X stuff 'test populationPhase1\n'`
-- and confirmed by grepping screenlog.0, per S10's own acceptance spec:
-- no client is needed or used. Everything below calls
-- PopulationServices:deliverMedic/deliverPerformer directly -- the same
-- functions the real conversation handlers call -- so this observes the
-- actual effect (a max-HAM delta, a wound clear, a credit charge, a
-- cooldown refusal), not just that a function returned without erroring.
--------------------------------------------------------------------------

-- MUST match managers/player_manager.lua's medicalBuff. That file is
-- boot-loaded into a SEPARATE Lua state (PlayerManagerImplementation's own
-- instance, not DirectorManager's screenplay state this test runs in), so
-- there is no live global this test can read instead -- see that file's
-- own comment block for the derivation of 555.
local POPULATION_TEST_EXPECTED_MEDICAL_BUFF = 555

function Tests:populationPhase1()
	-- getSpawnPoint("creature_test", ...) returns nil in this deployment
	-- (verified: stock Tests:aiMoveTest fails identically with "attempt to
	-- index a nil value (local 'spawnPoint')" -- the creature_test zone is
	-- not loaded here, matching that function's own "won't load due to
	-- being version 0013" comment -- a pre-existing environment gap, not
	-- something this change introduced). Spawn on a real, always-loaded
	-- zone at fixed coordinates instead (the Mos Eisley aid-post spot from
	-- population_config.lua -- an arbitrary safe outdoor point).
	local subject = spawnSceneObject("tatooine", "object/creature/player/human_male.iff", 3614.894, 5, -4780.4487, 0, 0)

	if subject == nil then
		printf("populationPhase1 FAIL: spawnSceneObject returned nil\n")
		return
	end

	if not SceneObject(subject):isPlayerCreature() then
		printf("populationPhase1 FAIL: spawned object is not a PlayerCreature\n")
		SceneObject(subject):destroyObjectFromWorld()
		return
	end

	local pass = true

	CreatureObject(subject):addCashCredits(1000000, false)

	-- 1. Medic: max HAM(HEALTH) delta equals medicalBuff exactly (buffs
	-- raise max HAM, so this observes the real effect, not the call).
	local baselineMaxHealth = CreatureObject(subject):getMaxHAM(HEALTH)
	local creditsBeforeMedic = CreatureObject(subject):getCashCredits()
	local medicFee = POPULATION_FEES.medic.base -- regionId=nil -> not frontier -> base fee

	local medicDelivered = PopulationServices:deliverMedic(subject, nil)

	local medicDelta = CreatureObject(subject):getMaxHAM(HEALTH) - baselineMaxHealth
	local medicCharged = creditsBeforeMedic - CreatureObject(subject):getCashCredits()

	if not medicDelivered then
		printf("populationPhase1 FAIL: deliverMedic refused on a funded, cooled-down subject\n")
		pass = false
	end
	if medicDelta ~= POPULATION_TEST_EXPECTED_MEDICAL_BUFF then
		printf("populationPhase1 FAIL: medic maxHAM(HEALTH) delta = " .. medicDelta .. ", expected " .. POPULATION_TEST_EXPECTED_MEDICAL_BUFF .. "\n")
		pass = false
	end
	if medicCharged ~= medicFee then
		printf("populationPhase1 FAIL: medic fee charged = " .. medicCharged .. ", expected " .. medicFee .. "\n")
		pass = false
	end

	-- 2. Medic cooldown: a second attempt inside the cooldown is refused
	-- and charges nothing.
	local creditsBeforeSecondMedic = CreatureObject(subject):getCashCredits()
	local secondMedicDelivered = PopulationServices:deliverMedic(subject, nil)
	local secondMedicCharged = creditsBeforeSecondMedic - CreatureObject(subject):getCashCredits()

	if secondMedicDelivered then
		printf("populationPhase1 FAIL: second deliverMedic call inside cooldown was NOT refused\n")
		pass = false
	end
	if secondMedicCharged ~= 0 then
		printf("populationPhase1 FAIL: refused medic attempt charged " .. secondMedicCharged .. " credits, expected 0\n")
		pass = false
	end

	-- 3. Performer: wound the subject, call the path, then confirm the
	-- WOUND CEILING was actually lifted.
	--
	-- VERIFIED LIVE (screenlog): setWounds() and healDamage() never touch
	-- maxHamList at all (CreatureObjectImplementation.cpp) -- getMaxHAM()
	-- is a separately-tracked value setWounds/setShockWounds do not write.
	-- What setWounds(type, N) actually changes is the CURRENT-HAM ceiling
	-- both setWounds and healDamage enforce as
	-- `maxHamList.get(type) - wounds.get(type)`. docs/DESIGN-POPULATION.md
	-- S10's "assert getMaxHAM == getBaseHAM" does not hold for this raw
	-- spawnSceneObject test subject (getBaseHAM(MIND) reads a template
	-- stub of 100 that never matched this subject's own getMaxHAM(MIND)
	-- of 1200, even before any wound -- confirmed by a first run of this
	-- test) and, per the C++ above, would not be the right observable
	-- for wound-clearing on ANY subject. The correct, verified observation
	-- is the ceiling healDamage respects: wound it, confirm healDamage
	-- cannot reach the unwounded max; clear via the performer; confirm
	-- healDamage now CAN reach the unwounded max again.
	local unwoundedMaxMind = CreatureObject(subject):getMaxHAM(MIND)
	CreatureObject(subject):healDamage(999999, MIND) -- ensure at full before wounding

	CreatureObject(subject):setWounds(MIND, 200)
	CreatureObject(subject):setShockWounds(300)
	CreatureObject(subject):healDamage(999999, MIND) -- try to heal past the wound ceiling
	local ceilingWhileWounded = CreatureObject(subject):getHAM(MIND)

	local performerFee = POPULATION_FEES.performer.base
	local creditsBeforePerformer = CreatureObject(subject):getCashCredits()

	local performerDelivered = PopulationServices:deliverPerformer(subject, nil, false)

	local performerCharged = creditsBeforePerformer - CreatureObject(subject):getCashCredits()
	CreatureObject(subject):healDamage(999999, MIND) -- the ceiling should be lifted now
	local ceilingAfterClear = CreatureObject(subject):getHAM(MIND)

	if not performerDelivered then
		printf("populationPhase1 FAIL: deliverPerformer refused on a funded, cooled-down subject\n")
		pass = false
	end
	if ceilingWhileWounded >= unwoundedMaxMind then
		printf("populationPhase1 FAIL: setWounds(MIND, 200) did not lower the heal ceiling (unwounded=" .. unwoundedMaxMind .. " whileWounded=" .. ceilingWhileWounded .. ")\n")
		pass = false
	end
	if ceilingAfterClear ~= unwoundedMaxMind then
		printf("populationPhase1 FAIL: performer did not lift the wound ceiling back to the unwounded max (unwounded=" .. unwoundedMaxMind .. " afterClear=" .. ceilingAfterClear .. ")\n")
		pass = false
	end
	if performerCharged ~= performerFee then
		printf("populationPhase1 FAIL: performer fee charged = " .. performerCharged .. ", expected " .. performerFee .. "\n")
		pass = false
	end

	-- 4. Performer cooldown: same refusal/no-charge check.
	local creditsBeforeSecondPerformer = CreatureObject(subject):getCashCredits()
	local secondPerformerDelivered = PopulationServices:deliverPerformer(subject, nil, false)
	local secondPerformerCharged = creditsBeforeSecondPerformer - CreatureObject(subject):getCashCredits()

	if secondPerformerDelivered then
		printf("populationPhase1 FAIL: second deliverPerformer call inside cooldown was NOT refused\n")
		pass = false
	end
	if secondPerformerCharged ~= 0 then
		printf("populationPhase1 FAIL: refused performer attempt charged " .. secondPerformerCharged .. " credits, expected 0\n")
		pass = false
	end

	SceneObject(subject):destroyObjectFromWorld()

	if pass then
		printf("populationPhase1 PASS\n")
	else
		printf("populationPhase1 FAIL (see above)\n")
	end
end

--- Diagnostic-only: prints what PopulationPlacement.computeSite() and
-- PopulationServices:spawnProvider() actually do for medic_1, so a
-- console operator can see WHY a provider is/isn't spawning without
-- guessing. Not part of the acceptance suite.
function Tests:populationDebug()
	local warState = PopulationPlacement.loadWarState()
	if warState == nil then
		printf("populationDebug: loadWarState() returned nil\n")
		return
	end

	printf("populationDebug: generated_at_tick=" .. warState.generated_at_tick .. "\n")

	local ok, regionId = pcall(PopulationPlacement.computeSite, "medic", "medic_1", warState, {})
	printf("populationDebug: computeSite medic_1 ok=" .. tostring(ok) .. " region=" .. tostring(regionId) .. "\n")

	if ok and regionId ~= nil then
		local site = POPULATION_AID_POSTS[regionId]
		if site == nil then
			printf("populationDebug: no POPULATION_AID_POSTS entry for " .. regionId .. "\n")
		else
			local pNpc = spawnMobile(site.zone, "medic", -1, site.x, site.z, site.y, site.heading, site.cell)
			printf("populationDebug: spawnMobile(" .. site.zone .. ", medic, ...) -> " .. tostring(pNpc) .. "\n")
			if pNpc ~= nil then
				SceneObject(pNpc):destroyObjectFromWorld()
			end
		end
	end
end

--- The POPULATION_SERVICES off-switch, proven live: toggling
-- POPULATION_SERVICES.medic off and calling PopulationServices:refreshAll()
-- (the same function the self-rescheduling circuit timer calls) actually
-- despawns medic_1 (its shared-memory npcOid goes to 0); toggling back on
-- respawns it. Mutates the in-memory config table directly (no file
-- write) so this is a clean, repeatable console proof.
function Tests:populationOffSwitch()
	PopulationServices:refreshAll()

	local before = readSharedMemory("population:medic_1:npcOid")
	if before == nil or before == 0 then
		printf("populationOffSwitch FAIL: medic_1 was not spawned before toggling off\n")
		return
	end

	local pass = true

	POPULATION_SERVICES.medic = false
	PopulationServices:refreshAll()

	local afterOff = readSharedMemory("population:medic_1:npcOid")
	if afterOff ~= 0 then
		printf("populationOffSwitch FAIL: medic_1 still has an npcOid after switching off (" .. tostring(afterOff) .. ")\n")
		pass = false
	end

	POPULATION_SERVICES.medic = true
	PopulationServices:refreshAll()

	local afterOn = readSharedMemory("population:medic_1:npcOid")
	if afterOn == nil or afterOn == 0 then
		printf("populationOffSwitch FAIL: medic_1 did not respawn after switching back on\n")
		pass = false
	end

	if pass then
		printf("populationOffSwitch PASS\n")
	else
		printf("populationOffSwitch FAIL (see above)\n")
	end
end

-- ============================================================== Backlog B14
-- Proves custom_scripts/screenplays/warreport/war_contrib.lua's include
-- actually loaded on THIS running server, without ever calling
-- WarContrib.record() -- calling record() here would append into the real
-- production log/warcontrib/ spool, which the real hourly
-- deploy/scripts/war-advance.sh would then flush into the LIVE
-- war_contribution_ledger. This function checks shape only: the global
-- table, the function, and the exact vocabulary size, all of which can only
-- be non-nil/correct if screenplays.lua's new includeFile line ran to
-- completion without error.
function Tests:warContribLoaded()
	if type(WarContrib) ~= "table" then
		printf("WARCONTRIBLOADED: FAIL -- WarContrib global is not a table (include did not run or errored)\n")
		return
	end
	if type(WarContrib.record) ~= "function" then
		printf("WARCONTRIBLOADED: FAIL -- WarContrib.record is not a function\n")
		return
	end
	local count = 0
	for _ in pairs(WarContrib.VALID_SOURCES or {}) do
		count = count + 1
	end
	printf("WARCONTRIBLOADED: PASS -- WarContrib table+record function present, VALID_SOURCES count="
		.. count .. " spool_dir=" .. tostring(WarContrib.SPOOL_DIR) .. "\n")
end

-- ============================================================== Backlog B?
-- Live verification aid for the multi-site WarBattle rewrite: dumps every
-- currently-tracked combatant's OID, zone and world position, so a change
-- to war_battle.lua's placement/budget logic can be checked server-side
-- (count, spread, zone) without a game client. Read-only: never spawns,
-- clears, or writes anything WarBattle itself does not already own.
function Tests:warBattleDump()
	if type(WarBattle) ~= "table" then
		printf("WARBATTLEDUMP: FAIL -- WarBattle table is nil\n")
		return
	end

	local raw = readStringData(WarBattle.OIDS_KEY)
	if raw == nil or raw == "" then
		printf("WARBATTLEDUMP: 0 tracked NPC(s)\n")
		return
	end

	local count = 0
	for token in string.gmatch(raw, "([^,]+)") do
		local oid = tonumber(token)
		if oid ~= nil and oid > 0 then
			local pObj = getSceneObject(oid)
			if pObj == nil then
				printf("WARBATTLEDUMP: oid=" .. oid .. " MISSING (tracked but not resolvable)\n")
			else
				local so = SceneObject(pObj)
				printf(string.format("WARBATTLEDUMP: oid=%d zone=%s pos=(%.1f, %.1f)\n",
					oid, tostring(so:getZoneName()), so:getWorldPositionX(), so:getWorldPositionY()))
			end
			count = count + 1
		end
	end
	printf("WARBATTLEDUMP: total tracked=" .. count
		.. " region=" .. tostring(readStringData(WarBattle.REGION_KEY)) .. "\n")
end

-- Live verification aid for the civilian-flight rewrite (war_hook.lua): for
-- each of the four cities the original density-fraction audit measured
-- (Anchorhead, Bestine, Coronet, Theed), prints the patrol/stationary row
-- counts, split civilian/combat, the fraction the currently-deployed war
-- state resolves for each, and the resulting spawn count -- the exact
-- decision CityScreenPlay:spawnPatrolMobiles/spawnStationaryMobiles already
-- made at boot (there is no randomness in the COUNT, only in which combat
-- row is picked when more than one is available, so this reproduces the
-- real boot-time numbers without needing a live in-world NPC count).
-- console: test warCivilianAudit
function Tests:warCivilianAudit()
	if type(WarBridge) ~= "table" then
		printf("WARCIVILIANAUDIT: FAIL -- WarBridge table is nil\n")
		return
	end

	local screenplayNames = {
		"TatooineAnchorheadScreenPlay",
		"TatooineBestineScreenPlay",
		"CorelliaCoronetScreenPlay",
		"NabooTheedScreenPlay",
	}

	for _, name in ipairs(screenplayNames) do
		local sp = _G[name]
		if sp == nil then
			printf("WARCIVILIANAUDIT: " .. name .. " -- SKIP (screenplay not found)\n")
		else
			local total = #sp.patrolMobiles
			local civTotal, milTotal = 0, 0
			for i = 1, total do
				if sp.patrolMobiles[i][9] == true then
					milTotal = milTotal + 1
				else
					civTotal = civTotal + 1
				end
			end

			local okC, civFraction = pcall(WarBridge.civilianFlightFraction, sp)
			local okM, milFraction = pcall(WarBridge.militaryPatrolDensityFraction, sp)
			if not okC then civFraction = -1 end
			if not okM then milFraction = -1 end

			local civSpawn = WarBridge.computeSpawnCount(civTotal, civFraction, 1)
			local milSpawn = WarBridge.computeSpawnCount(milTotal, milFraction, 1)

			local stationaryTotal = #sp.stationaryMobiles
			local stationarySpawn = WarBridge.computeSpawnCount(stationaryTotal, civFraction, 1)

			printf(string.format(
				"WARCIVILIANAUDIT: %s civFraction=%.4f milFraction=%.4f patrol=%d/%d (civ %d/%d + mil %d/%d) stationary=%d/%d\n",
				name, civFraction, milFraction,
				civSpawn + milSpawn, total,
				civSpawn, civTotal, milSpawn, milTotal,
				stationarySpawn, stationaryTotal))
		end
	end
end
