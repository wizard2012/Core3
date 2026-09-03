--[[
  custom_scripts/screenplays/population/population_probe.lua

  Console-callable proof for the two npc-doctors-fix changes:

  1. populationMedicWoundHeal -- the medic now actually heals (real HAM
     damage AND a lifted wound ceiling), not just the enhanceCharacter()
     buff it always called. Mirrors screenplays/tests/tests.lua's own
     populationPhase1 style (a synthetic spawnSceneObject subject, no
     player or client needed, nothing written to swgwar/swgemu) but
     targets the HEALTH pool specifically, since populationPhase1 only
     ever asserted the medic's BUFF delta and the performer's MIND-wound
     clear -- it never checked the medic against a wound at all, which is
     exactly how this bug shipped unnoticed.

  2. populationFrontCoverage -- dumps, per CURRENT front region
     (WarReport.frontRegions(), the same signal war_battle.lua stages
     fights at), whether a medic and a performer are placed AND settled
     (npc object alive at its shared-memory oid, applied region ==
     that front region) right now. This is the direct proof for the
     owner's "both an NPC entertainer and medic/doctor" coverage
     guarantee added in standing_services.lua/population_config.lua.
     Read-only: never spawns, despawns, or moves anything -- just reports
     what PopulationServices already did on its own ticks.

  Run:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test populationMedicWoundHeal\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep POPULATIONMEDICWOUNDHEAL ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -20"

    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test populationFrontCoverage\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep POPULATIONFRONTCOVERAGE ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -40"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports "No Sockets found" even on a healthy
  server (docs/AGENTS.md).
]]

function Tests:populationMedicWoundHeal()
	printf("POPULATIONMEDICWOUNDHEAL: begin\n")

	local subject = spawnSceneObject("tatooine", "object/creature/player/human_male.iff", 3614.894, 5, -4780.4487, 0, 0)
	if subject == nil then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- spawnSceneObject returned nil\n")
		return
	end
	if not SceneObject(subject):isPlayerCreature() then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- spawned object is not a PlayerCreature\n")
		SceneObject(subject):destroyObjectFromWorld()
		return
	end

	local pass = true
	CreatureObject(subject):addCashCredits(1000000, false)

	-- Wound HEALTH (confirm the heal ceiling actually drops), inflict real
	-- current damage independent of that ceiling, then confirm deliverMedic
	-- both heals the current damage AND lifts the wound ceiling back --
	-- the exact effect that never existed before this fix (it only ever
	-- called enhanceCharacter(), a buff that touches neither).
	local unwoundedMaxHealth = CreatureObject(subject):getMaxHAM(HEALTH)
	CreatureObject(subject):healDamage(999999, HEALTH) -- ensure full before wounding

	CreatureObject(subject):setWounds(HEALTH, 300)
	CreatureObject(subject):healDamage(999999, HEALTH) -- try to heal past the (now lower) ceiling
	local ceilingWhileWounded = CreatureObject(subject):getHAM(HEALTH)

	if ceilingWhileWounded >= unwoundedMaxHealth then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- setWounds(HEALTH,300) did not lower the heal ceiling (unwounded=" .. unwoundedMaxHealth .. " whileWounded=" .. ceilingWhileWounded .. ")\n")
		pass = false
	end

	CreatureObject(subject):inflictDamage(subject, HEALTH, 200, 1)
	local hamBeforeMedic = CreatureObject(subject):getHAM(HEALTH)

	local medicFee = POPULATION_FEES.medic.base
	local creditsBeforeMedic = CreatureObject(subject):getCashCredits()

	local delivered = PopulationServices:deliverMedic(subject, nil)

	local medicCharged = creditsBeforeMedic - CreatureObject(subject):getCashCredits()
	local hamAfterMedic = CreatureObject(subject):getHAM(HEALTH)
	CreatureObject(subject):healDamage(999999, HEALTH) -- probe whether the ceiling itself was lifted
	local ceilingAfterMedic = CreatureObject(subject):getHAM(HEALTH)

	if not delivered then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- deliverMedic refused on a funded, cooled-down subject\n")
		pass = false
	end
	if medicCharged ~= medicFee then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- medic fee charged = " .. medicCharged .. ", expected " .. medicFee .. "\n")
		pass = false
	end
	if hamAfterMedic <= hamBeforeMedic then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- current HEALTH damage was not healed (before=" .. hamBeforeMedic .. " after=" .. hamAfterMedic .. ")\n")
		pass = false
	end
	if ceilingAfterMedic ~= unwoundedMaxHealth then
		printf("POPULATIONMEDICWOUNDHEAL: FAIL -- medic did not lift the HEALTH wound ceiling back to the unwounded max (unwounded=" .. unwoundedMaxHealth .. " afterMedic=" .. ceilingAfterMedic .. ")\n")
		pass = false
	end

	SceneObject(subject):destroyObjectFromWorld()

	if pass then
		printf("POPULATIONMEDICWOUNDHEAL: PASS\n")
	else
		printf("POPULATIONMEDICWOUNDHEAL: FAIL (see above)\n")
	end
end

--- Read-only: for each currently-ranked front region, report whether a
-- medic and a performer are placed there (applied region matches) AND
-- alive (the shared-memory npc oid resolves to a live scene object).
-- Walks every provider id of each kind (not just guaranteed slots) since
-- an ambient roamer landing on a front region by chance still counts as
-- coverage.
function Tests:populationFrontCoverage()
	printf("POPULATIONFRONTCOVERAGE: begin\n")

	if type(WarReport) ~= "table" or type(WarReport.frontRegions) ~= "function" then
		printf("POPULATIONFRONTCOVERAGE: FAIL -- WarReport.frontRegions not available in this Lua state\n")
		return
	end

	local ok, front = pcall(WarReport.frontRegions)
	if not ok or type(front) ~= "table" then
		printf("POPULATIONFRONTCOVERAGE: FAIL -- WarReport.frontRegions() call failed\n")
		return
	end

	if #front == 0 then
		printf("POPULATIONFRONTCOVERAGE: no region currently at/above the front threshold -- nothing to check\n")
		return
	end

	local function providerAt(kind, regionId)
		local providerCfg = POPULATION_PROVIDERS[kind]
		if providerCfg == nil or type(providerCfg.count) ~= "number" then
			return nil
		end

		for i = 1, providerCfg.count do
			local providerId = kind .. "_" .. i
			if PopulationPlacement.getAppliedRegion(providerId) == regionId then
				local npcOid = readSharedMemory("population:" .. providerId .. ":npcOid")
				if npcOid ~= nil and npcOid ~= 0 and getSceneObject(npcOid) ~= nil then
					return providerId
				end
			end
		end
		return nil
	end

	local allCovered = true
	for i = 1, #front do
		local regionId = front[i].id
		local medicProvider = providerAt("medic", regionId)
		local performerProvider = providerAt("performer", regionId)

		local hasMedicSite = POPULATION_AID_POSTS[regionId] ~= nil
		local hasCantinaSite = POPULATION_CANTINAS[regionId] ~= nil

		printf("POPULATIONFRONTCOVERAGE: rank=" .. i .. " region=" .. regionId ..
			" contest=" .. tostring(front[i].contest) .. " faction=" .. tostring(front[i].faction) ..
			" medic=" .. (medicProvider or "MISSING") ..
			" performer=" .. (performerProvider or "MISSING") ..
			" medicSiteExists=" .. tostring(hasMedicSite) ..
			" cantinaSiteExists=" .. tostring(hasCantinaSite) .. "\n")

		if medicProvider == nil and hasMedicSite then
			allCovered = false
		end
		if performerProvider == nil and hasCantinaSite then
			allCovered = false
		end
	end

	if allCovered then
		printf("POPULATIONFRONTCOVERAGE: PASS -- every front region with a configured site has both providers\n")
	else
		printf("POPULATIONFRONTCOVERAGE: FAIL -- see MISSING lines above (a region with no configured site for that kind, e.g. tat_anchorhead's missing cantina, is a known gap, not a placement bug)\n")
	end
end
