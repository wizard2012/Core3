--[[
  custom_scripts/screenplays/population/street_probe.lua

  Console-callable proof for street_life.lua, following
  warreport/war_probe.lua's own pattern of attaching to the global Tests
  table from a tracked custom_scripts file (screenplays/tests/tests.lua is
  gitignored -- see war_probe.lua's header for why that matters).

  Trap 21 (docs/AGENTS.md): `test <fn>` does not reliably pick up edits to
  tests.lua after a reload -- this is exactly why these probes live here
  instead.

  Run any of these via:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test <name>\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep <MARKER> ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -40"
]]

--- Spawn the boot set and start each configured city's tick loop -- but only
-- if the shared-memory heartbeat is absent or stale, so re-running this
-- probe (or a reloadscreenplays picking it up again) can never double the
-- loop for a city that is already ticking.
function Tests:populationStreetNow()
	printf("POPULATIONSTREETNOW: begin\n")

	if StreetLife == nil or STREET_CONFIG == nil then
		printf("POPULATIONSTREETNOW: FAIL -- StreetLife or STREET_CONFIG not loaded\n")
		return
	end

	local now = getTimestampMilli()
	local last = readSharedMemory("streetlife:heartbeat")
	local staleAfterMs = STREET_CONFIG.TICK_MAX_MS * 4

	local stale = (last == nil or last == 0) or ((now - last) > staleAfterMs)

	if not stale then
		printf("POPULATIONSTREETNOW: heartbeat is fresh (age=" .. tostring(now - last)
			.. "ms, staleAfter=" .. tostring(staleAfterMs) .. "ms) -- refusing to double-start\n")
		return
	end

	printf("POPULATIONSTREETNOW: heartbeat absent/stale (last=" .. tostring(last) .. ") -- starting\n")
	StreetLife:bootAll()

	printf("POPULATIONSTREETNOW: started, heartbeat now=" .. tostring(readSharedMemory("streetlife:heartbeat")) .. "\n")
	printf("POPULATIONSTREETNOW: end\n")
end

--- Per-city tracked counts by kind, heartbeat age, config flags, and for
-- every tracked actor its faction string and pvp bitmask -- the faction-rule
-- proof (every actor must show non-imperial, non-rebel, pvpBitmask=0).
function Tests:populationStreetDump()
	printf("POPULATIONSTREETDUMP: begin\n")

	if StreetLife == nil or STREET_CONFIG == nil then
		printf("POPULATIONSTREETDUMP: FAIL -- StreetLife or STREET_CONFIG not loaded\n")
		return
	end

	local now = getTimestampMilli()
	local hb = readSharedMemory("streetlife:heartbeat")
	local hbAge = (hb == nil or hb == 0) and -1 or (now - hb)

	printf("POPULATIONSTREETDUMP: enabled=" .. tostring(STREET_CONFIG.ENABLED)
		.. " heartbeatAgeMs=" .. tostring(hbAge) .. "\n")

	local regionIds = {}
	for regionId, _ in pairs(STREET_CONFIG.CITIES) do
		regionIds[#regionIds + 1] = regionId
	end
	table.sort(regionIds)

	for i = 1, #regionIds do
		local regionId = regionIds[i]
		local records = StreetLife:parseRecords(regionId)

		local counts = { anchor = 0, stationary = 0, cantina = 0, traveler = 0 }
		for j = 1, #records do
			local k = records[j].kind
			counts[k] = (counts[k] or 0) + 1
		end

		printf(string.format(
			"POPULATIONSTREETDUMP: %s enabled=%s total=%d anchor=%d stationary=%d cantina=%d traveler=%d\n",
			regionId, tostring(STREET_CONFIG.CITIES[regionId]), #records,
			counts.anchor, counts.stationary, counts.cantina, counts.traveler))

		for j = 1, #records do
			local r = records[j]
			local pObj = getSceneObject(r.oid)

			if pObj == nil then
				printf("POPULATIONSTREETDUMP:   oid=" .. tostring(r.oid) .. " kind=" .. tostring(r.kind) .. " MISSING (dead, awaiting sweep)\n")
			else
				local faction = StreetLife:factionLabel(pObj)
				local pvp = "?"
				local okPvp, bitmask = pcall(function() return TangibleObject(pObj):getPvpStatusBitmask() end)
				if okPvp then
					pvp = tostring(bitmask)
				end

				printf("POPULATIONSTREETDUMP:   oid=" .. tostring(r.oid) .. " kind=" .. tostring(r.kind)
					.. " faction=" .. faction .. " pvpBitmask=" .. pvp .. "\n")
			end
		end
	end

	printf("POPULATIONSTREETDUMP: end\n")
end

--- Despawn everything tracked across every configured city, then assert the
-- tracked count is 0.
function Tests:populationStreetOff()
	printf("POPULATIONSTREETOFF: begin\n")

	if StreetLife == nil or STREET_CONFIG == nil then
		printf("POPULATIONSTREETOFF: FAIL -- StreetLife or STREET_CONFIG not loaded\n")
		return
	end

	local removed = 0

	for regionId, _ in pairs(STREET_CONFIG.CITIES) do
		local records = StreetLife:parseRecords(regionId)
		for i = 1, #records do
			local pObj = getSceneObject(records[i].oid)
			if pObj ~= nil then
				pcall(function() SceneObject(pObj):destroyObjectFromWorld(false) end)
				removed = removed + 1
			end
		end
		StreetLife:clearCity(regionId)
	end

	local remaining = 0
	for regionId, _ in pairs(STREET_CONFIG.CITIES) do
		remaining = remaining + #StreetLife:parseRecords(regionId)
	end

	printf("POPULATIONSTREETOFF: removed=" .. tostring(removed) .. " remainingTracked=" .. tostring(remaining) .. "\n")
	if remaining == 0 then
		printf("POPULATIONSTREETOFF: PASS -- 0 tracked\n")
	else
		printf("POPULATIONSTREETOFF: FAIL -- expected 0 tracked, got " .. tostring(remaining) .. "\n")
	end

	printf("POPULATIONSTREETOFF: end\n")
end

-- ======================================================= targeted proofs ==

-- Fixed subject city for the two proofs below: tat_mos_eisley, chosen because
-- it is one of the 13 configured cities and its stationaryMobiles row 1
-- (the anchor spot) is a known, always-loaded outdoor point (matches the
-- Tests:populationPhase1 test's own reasoning for using this town).
local PROOF_REGION = "tat_mos_eisley"

--- Proves the presence gate is actually gating, rather than merely asserting
-- it: with nobody near the anchor, two forced ticks must not move the
-- chatter ring; spawning a fake player at the anchor's own coordinates and
-- ticking twice more must move it; destroying that player and ticking twice
-- more again must not move it further.
function Tests:populationStreetPresenceProof()
	printf("POPULATIONSTREETPRESENCE: begin\n")

	if StreetLife == nil or STREET_CONFIG == nil then
		printf("POPULATIONSTREETPRESENCE: FAIL -- StreetLife or STREET_CONFIG not loaded\n")
		return
	end

	local screenplayName = STREET_CONFIG.screenplayNameFor(PROOF_REGION)
	local sp = screenplayName ~= nil and _G[screenplayName] or nil
	if sp == nil or type(sp.stationaryMobiles) ~= "table" or #sp.stationaryMobiles == 0 then
		printf("POPULATIONSTREETPRESENCE: FAIL -- screenplay/stationaryMobiles missing for " .. PROOF_REGION .. "\n")
		return
	end

	-- Make sure the boot set (and anchor) exists for this city.
	local anchorOid = readSharedMemory("streetlife:anchor:" .. PROOF_REGION)
	if anchorOid == nil or anchorOid == 0 or getSceneObject(anchorOid) == nil then
		StreetLife:bootCity(PROOF_REGION)
		anchorOid = readSharedMemory("streetlife:anchor:" .. PROOF_REGION)
	end
	if anchorOid == nil or anchorOid == 0 or getSceneObject(anchorOid) == nil then
		printf("POPULATIONSTREETPRESENCE: FAIL -- no live anchor for " .. PROOF_REGION .. " after bootCity\n")
		return
	end

	local anchorRow = sp.stationaryMobiles[1]

	local function ringSnapshot()
		return readStringSharedMemory("streetlife:ring:" .. PROOF_REGION)
	end

	local before = ringSnapshot()

	-- No player nearby: two forced ticks, ring must not move.
	StreetLife:tickOnce(PROOF_REGION)
	StreetLife:tickOnce(PROOF_REGION)
	local afterNoPlayer = ringSnapshot()
	local noPlayerHeld = (afterNoPlayer == before)

	-- Spawn a fake player AT the anchor's own coordinates (same mechanism as
	-- Tests:populationPhase1).
	local subject = spawnSceneObject(sp.planet, "object/creature/player/human_male.iff",
		anchorRow[2], anchorRow[3], anchorRow[4], 0, 0)
	local spawnedOk = subject ~= nil and SceneObject(subject):isPlayerCreature()

	StreetLife:tickOnce(PROOF_REGION)
	StreetLife:tickOnce(PROOF_REGION)
	local afterPlayer = ringSnapshot()
	local ringAdvanced = spawnedOk and (afterPlayer ~= before)

	if subject ~= nil then
		SceneObject(subject):destroyObjectFromWorld()
	end

	local ringAfterDestroy = afterPlayer

	StreetLife:tickOnce(PROOF_REGION)
	StreetLife:tickOnce(PROOF_REGION)
	local afterDestroyTicks = ringSnapshot()
	local heldAfterDestroy = (afterDestroyTicks == ringAfterDestroy)

	printf("POPULATIONSTREETPRESENCE: ringBefore=" .. tostring(before) .. "\n")
	printf("POPULATIONSTREETPRESENCE: noPlayerRingUnchanged=" .. tostring(noPlayerHeld)
		.. " ringAfterNoPlayerTicks=" .. tostring(afterNoPlayer) .. "\n")
	printf("POPULATIONSTREETPRESENCE: spawnedFakePlayer=" .. tostring(spawnedOk)
		.. " ringAdvancedWithPlayerPresent=" .. tostring(ringAdvanced)
		.. " ringAfterPlayerTicks=" .. tostring(afterPlayer) .. "\n")
	printf("POPULATIONSTREETPRESENCE: ringUnchangedAfterDestroy=" .. tostring(heldAfterDestroy)
		.. " ringAfterDestroyTicks=" .. tostring(afterDestroyTicks) .. "\n")

	if noPlayerHeld and ringAdvanced and heldAfterDestroy then
		printf("POPULATIONSTREETPRESENCE: PASS\n")
	else
		printf("POPULATIONSTREETPRESENCE: FAIL\n")
	end

	printf("POPULATIONSTREETPRESENCE: end\n")
end

--- Proves the sweep actually removes an expired record: track a fake
-- traveller oid with an already-past TTL, sweep, show the object is
-- destroyed and no longer tracked.
function Tests:populationStreetSweepProof()
	printf("POPULATIONSTREETSWEEP: begin\n")

	if StreetLife == nil then
		printf("POPULATIONSTREETSWEEP: FAIL -- StreetLife not loaded\n")
		return
	end

	-- Spawn the fake traveller EXACTLY the way a real traveller is spawned --
	-- spawnMobile, respawnTimer 0, at the Mos Eisley shuttleport coordinate
	-- from population_config.lua's POPULATION_AID_POSTS. An earlier version
	-- of this probe used spawnSceneObject with a player template instead;
	-- that subject reported no zone even BEFORE the sweep, which made the
	-- "was it removed" half of the assertion vacuous. A real AiAgent is both
	-- the honest subject and a checkable one.
	local subject = spawnMobile("tatooine", "commoner", 0, 3614.894, 5, -4780.4487, 0, 0)
	if subject == nil then
		printf("POPULATIONSTREETSWEEP: FAIL -- spawnMobile returned nil\n")
		return
	end

	local oid = SceneObject(subject):getObjectID()

	-- TTL already past (expiresAt = now - 1) -- "spawn a traveller with TTL 0".
	StreetLife:trackRecord(PROOF_REGION, oid, "traveler", getTimestampMilli() - 1)

	-- "In the world" test, grounded in LuaSceneObject::getPlayersInRange:
	-- it returns nil, and only nil, when the object's getZone() is null.
	-- getSceneObject(oid) is NOT a usable signal here -- ram-side deletion
	-- happens on ObjectManager's later GC pass (its periodic "deleted from
	-- ram N objects" log lines), so a just-destroyed object still resolves
	-- by oid for a while. VERIFIED LIVE: goneAfterSweep came back false for
	-- both a spawnSceneObject player and a spawnMobile AiAgent immediately
	-- after a destroy that had definitely run.
	local function inWorld(pObj)
		if pObj == nil then
			return false
		end
		local ok, players = pcall(function() return SceneObject(pObj):getPlayersInRange(1) end)
		return ok and players ~= nil
	end

	local existedBefore = getSceneObject(oid) ~= nil
	local inWorldBefore = inWorld(subject)
	local okZoneBefore, zoneNameBefore = pcall(function() return SceneObject(subject):getZoneName() end)

	StreetLife:sweepCity(PROOF_REGION)

	local pAfter = getSceneObject(oid)
	local inWorldAfter = inWorld(pAfter)
	local zoneNameAfter = ""
	if pAfter ~= nil then
		local okZoneAfter, z = pcall(function() return SceneObject(pAfter):getZoneName() end)
		if okZoneAfter then
			zoneNameAfter = tostring(z)
		end
	end

	local removedFromWorld = (not inWorldAfter)

	local stillTracked = false
	local records = StreetLife:parseRecords(PROOF_REGION)
	for i = 1, #records do
		if records[i].oid == oid then
			stillTracked = true
		end
	end

	printf("POPULATIONSTREETSWEEP: oid=" .. tostring(oid)
		.. " existedBeforeSweep=" .. tostring(existedBefore)
		.. " inWorldBefore=" .. tostring(inWorldBefore)
		.. " zoneBefore=" .. tostring(okZoneBefore and zoneNameBefore or "?")
		.. " inWorldAfter=" .. tostring(inWorldAfter)
		.. " zoneAfter=" .. tostring(zoneNameAfter)
		.. " stillTrackedAfterSweep=" .. tostring(stillTracked) .. "\n")

	if existedBefore and inWorldBefore and removedFromWorld and not stillTracked then
		printf("POPULATIONSTREETSWEEP: PASS\n")
	else
		printf("POPULATIONSTREETSWEEP: FAIL\n")
	end

	printf("POPULATIONSTREETSWEEP: end\n")
end
