--[[
  bridge/war_hook.lua  (deployed into
  core3/MMOCoreORB/bin/scripts/custom_scripts/screenplays/war_hook.lua by
  bridge/sync_to_core3.sh)

  The spawn hook that makes the war sim's per-region control visible in
  Core3's GCW city mobs and patrols, without touching core3/ or C++.

  HOW THIS RUNS AT ALL WITHOUT EDITING city.lua
  ----------------------------------------------
  core3/MMOCoreORB/bin/scripts/screenplays/screenplays.lua includes every
  city_*.lua file (which define CityScreenPlay and every CityXyzScreenPlay
  subclass as globals), and only THEN, near the end of the file, includes
  custom_scripts/screenplays/screenplays.lua (the tracked customization
  seam Core3 ships for exactly this purpose) -- which in turn includes this
  file. By the time this file runs, CityScreenPlay is a live global table.

  Each CityXyzScreenPlay subclass was built via `CityScreenPlay:new{...}`
  (see object/object.lua's Object:new), which does
  `setmetatable(subclass, CityScreenPlay)` -- the SAME CityScreenPlay table
  object, not a copy. Lua method lookup on an instance falls through its
  metatable's __index chain at CALL time, not at :new() time. So
  reassigning `function CityScreenPlay:spawnGcwMobiles() ... end` here
  retroactively changes what every existing city subclass calls, the same
  way TatooineMosEisleyScreenPlay etc. already share CityScreenPlay's
  spawnMob/onDespawn/mobileDestinationReached/etc. This is monkey-patching,
  not a fork: city.lua's own copy of these functions is left byte-for-byte
  alone (git -C core3 status stays clean), and this file is the only place
  the override lives.

  WHAT IS OVERRIDDEN AND WHY
  ---------------------------
  - spawnGcwMobiles, respawn: swap city.lua's per-PLANET
    `getControllingFaction(self.planet)` for a per-REGION lookup through
    WAR_STATE (see WarBridge.resolveFaction below). spawnMob itself is NOT
    touched -- it already takes controllingFaction as a plain parameter and
    does the mobTable[1]/mobTable[2] selection; only what value gets fed
    into that existing parameter changes.
  - spawnPatrolMobiles, spawnPatrol: extended, backward compatibly, to (a)
    faction-swap a patrol entry when its template field is a two-element
    table {imperial_template, rebel_template} instead of a bare string (old
    entries, all currently bare strings, are completely unaffected), and
    (b) spawn a war-state-driven SUBSET of the patrol list, using TWO
    independent fractions (see "TWO SEPARATE DIALS" below) instead of one.
  - spawnStationaryMobiles: extended the same way as (b) above, using the
    civilian-flight fraction only (stationary rows are always civilians --
    city.lua has no combat/military stationary concept).

  TWO SEPARATE DIALS -- DO NOT CONFLATE THEM AGAIN
  --------------------------------------------------
  This file used to have exactly one fraction, WarBridge.patrolDensityFraction,
  driven by garrison strength (DESIGN-UNITS.md S:U7.2), and applied it to
  EVERY patrol row regardless of type. That was a bug: every patrol row that
  actually exists in this game's data is a CIVILIAN (patrol[9] == false --
  audited across all 13 war-mapped cities, 99/99 rows). So the "military
  garrison" dial was silently culling civilians, and because contested towns
  get the LOWEST garrison-based fraction, the closer a town was to the war
  the emptier its streets looked -- backwards from the intent, and it also
  did nothing to stationaryMobiles, so the town looked arbitrarily patchy.
  Ruling (owner, see docs/BACKLOG.md history): keep the thinning, but make it
  a deliberate, correctly-named FEATURE -- "civilians flee a war zone" -- and
  apply it consistently to every civilian-presence row, patrol and
  stationary alike. So there are now two independent fractions:

    WarBridge.militaryPatrolDensityFraction(sp) -- unchanged math, garrison
      strength driven, applies ONLY to patrol rows with patrol[9] == true
      (a "combatPatrol" row). There are none in the shipped data today, so
      this path is currently inert; it becomes live the day a combat patrol
      row is added, with no further code change needed.

    WarBridge.civilianFlightFraction(sp) -- NEW, driven by region.threat and
      region.supply_status (see WarBridge.CIVILIAN_FLIGHT below for the
      tunable coefficients and the reasoning behind each one). Applies to
      every patrol row with patrol[9] ~= true, AND to every row in
      stationaryMobiles (which has no patrol[9]-equivalent -- it's all
      civilians, always).

  Never let one fraction answer both questions again: "how hard does the
  garrison patrol" and "how many civilians are still on the street" are
  different questions with different inputs, and conflating them is exactly
  the bug this rewrite fixes.

  FAIL-SAFE CONTRACT
  -------------------
  Every WAR_STATE read in this file goes through WarBridge.resolveFaction /
  WarBridge.getRegionForScreenplay, which return nil on ANY of: the file
  missing, a Lua syntax error in it (includeFile/runFile already catches
  that at the C++ level via lua_pcall and just logs -- it does not throw
  into this chunk, so a broken war_state.lua cannot stop the REST of this
  file, including these very override functions, from loading), a
  malformed table shape, an unmapped screenplay, or an unrecognised faction
  string. Every call site treats nil as "use stock Core3 behaviour" and
  falls through to literally the same call city.lua itself would have made
  (getControllingFaction(self.planet), or the full unfiltered patrol /
  stationary list). WarBridge.militaryPatrolDensityFraction and
  WarBridge.civilianFlightFraction both follow the identical rule: any
  failure to read a valid number out of WAR_STATE returns 1.0 (spawn
  everything, i.e. stock behaviour), never an error and never a partial
  crowd. bridge/tests/t_failsafe.lua exercises the pure decision logic; the
  live server test in the task report exercises the real file.
]]

-- ========================================================== WarBridge ====

WarBridge = WarBridge or {}

--- (Re)load WAR_STATE and WAR_REGION_MAP from the generated files under
-- custom_scripts/war/. Safe to call repeatedly (reloadscreenplays calls
-- this file fresh each time). Never throws: any failure leaves WAR_STATE
-- (and/or WAR_REGION_MAP) nil, which every reader below treats as "fall
-- back to stock".
function WarBridge.load()
	WAR_STATE = nil
	WAR_REGION_MAP = nil

	-- includeFile paths are always resolved relative to scripts/screenplays/
	-- (DirectorManager::includeFile), regardless of which file calls it --
	-- confirmed by reading city.lua's own
	-- includeFile("../custom_scripts/screenplays/screenplays.lua").
	includeFile("../custom_scripts/war/region_map.lua")
	includeFile("../custom_scripts/war/war_state.lua")

	if type(WAR_REGION_MAP) ~= "table" then
		if WAR_REGION_MAP ~= nil then
			printf("WarBridge: custom_scripts/war/region_map.lua loaded but is not a table -- war-state spawn hook disabled, falling back to stock GCW behaviour.\n")
		end
		WAR_REGION_MAP = nil
	end

	if type(WAR_STATE) ~= "table" or type(WAR_STATE.regions) ~= "table" then
		if WAR_STATE ~= nil then
			printf("WarBridge: custom_scripts/war/war_state.lua loaded but malformed (missing .regions table) -- falling back to stock GCW behaviour.\n")
		end
		WAR_STATE = nil
	end
end

-- Loaded once per reloadscreenplays / boot, at the point this file itself
-- is included -- i.e. after every city_*.lua has already defined its
-- screenplay class.
WarBridge.load()

--- Look up the war-state region entry for a CityScreenPlay's
-- screenplayName. Returns nil (never throws) if WAR_STATE/WAR_REGION_MAP
-- failed to load, or this screenplay has no war region mapped to it.
function WarBridge.getRegionForScreenplay(screenplayName)
	if WAR_STATE == nil or WAR_REGION_MAP == nil then
		return nil
	end

	local regionId = WAR_REGION_MAP[screenplayName]
	if regionId == nil then
		return nil
	end

	local region = WAR_STATE.regions[regionId]
	if type(region) ~= "table" then
		return nil
	end

	return region, regionId
end

--- "imperial"/"rebel" -> the FACTIONIMPERIAL/FACTIONREBEL engine constants.
-- Anything else (missing, "neutral", garbage) returns nil -- deliberately:
-- callers treat nil the same as "no war-state opinion", not as "neutral",
-- so a genuinely neutral war region still falls through to Core3's own
-- getControllingFaction() rather than this file guessing.
function WarBridge.factionConstant(factionString)
	if factionString == "imperial" then
		return FACTIONIMPERIAL
	elseif factionString == "rebel" then
		return FACTIONREBEL
	end
	return nil
end

--- The single decision point both spawnGcwMobiles and respawn use: what
-- faction controls the city `screenplayInstance` belongs to, right now.
-- War-state-driven when available and mapped; stock per-planet Core3
-- behaviour otherwise. This is the fail-safe seam.
function WarBridge.resolveFaction(screenplayInstance)
	local ok, region = pcall(WarBridge.getRegionForScreenplay, screenplayInstance.screenplayName)

	local controllingFaction = nil
	if ok and region ~= nil then
		controllingFaction = WarBridge.factionConstant(region.faction)
	end

	if controllingFaction == nil then
		-- FAIL SAFE: missing file, malformed file, unmapped city, or an
		-- unrecognised faction string all land here, identically to how
		-- city.lua behaves with no war-state hook installed at all.
		controllingFaction = getControllingFaction(screenplayInstance.planet)
	end

	if controllingFaction == FACTIONNEUTRAL then
		controllingFaction = FACTIONIMPERIAL
	end

	return controllingFaction
end

--- Fraction (0..1) of the stock COMBAT patrol rows (patrol[9] == true) this
-- region's garrison should actually put on the street right now, per
-- DESIGN-UNITS.md S:U7.2 (already computed server-side by
-- bridge/war_state_writer.lua as region.density_fraction -- this file only
-- reads the number). Returns 1.0 (spawn everything, i.e. stock behaviour)
-- whenever the war state doesn't have an opinion, so an unmapped city or a
-- missing file patrols exactly as it always did.
--
-- Renamed from patrolDensityFraction: it used to be applied to every patrol
-- row, civilian and combat alike, which was the bug this file's header now
-- documents at length. This function's MATH is unchanged -- only its scope
-- (combat rows only) and its name changed.
function WarBridge.militaryPatrolDensityFraction(screenplayInstance)
	local ok, region = pcall(WarBridge.getRegionForScreenplay, screenplayInstance.screenplayName)

	if not ok or region == nil or type(region.density_fraction) ~= "number" then
		return 1.0
	end

	local f = region.density_fraction
	if f < 0 then f = 0 end
	if f > 1 then f = 1 end

	return f
end

--- Tunable coefficients for WarBridge.civilianFlightFraction. Every constant
-- here is game-side Lua (not warsim/), so there is no determinism
-- constraint on it -- but it still gets named, commented, single-sourced
-- constants instead of bare numbers buried in the formula below.
WarBridge.CIVILIAN_FLIGHT = {
	-- How much of the civilian population leaves purely because of danger
	-- (region.threat, 0..1, already contest/100 -- see
	-- bridge/war_state_writer.lua). At the maximum threat=1.0, this
	-- coefficient alone removes up to this fraction of civilians. Turning
	-- it up makes contested/frontline towns empty out faster as the fight
	-- gets hotter; turning it down makes civilians more stubborn.
	THREAT_COEFF = 0.60,

	-- Additional flat fraction of civilians who leave because supply is
	-- degraded or cut -- people leave when the shelves are empty, not just
	-- when there's shooting. Keyed by region.supply_status (see
	-- bridge/war_state_writer.lua's supply_status_for()). A status this
	-- table doesn't recognise (including a missing/malformed field) is
	-- treated as no additional penalty -- threat is still applied, so this
	-- is graceful degradation, not a fail-safe trigger (that only fires
	-- when region.threat itself isn't a usable number).
	SUPPLY_PENALTY = {
		connected = 0.00,
		degraded  = 0.15,
		cut       = 0.30,
	},

	-- Absolute floor on the fraction, regardless of how bad threat/supply
	-- get. The owner's ruling was explicit: a contested town must still
	-- read as inhabited, not abandoned -- this is what keeps that true even
	-- at threat=1.0 with supply cut. 0.35 means a town never loses more
	-- than roughly two-thirds of its civilian presence to the war.
	FLOOR = 0.35,
}

--- Fraction (0..1) of civilian presence (patrol rows with patrol[9] ~= true,
-- and every stationaryMobiles row) that should still be spawned in this
-- region right now -- "civilians flee a war zone" per the owner's ruling.
-- Driven by region.threat and region.supply_status, NOT by garrison
-- strength (see this file's header for why the old shared-fraction design
-- was wrong). Returns 1.0 (spawn everyone, i.e. stock behaviour) whenever
-- the war state doesn't have a usable region.threat number for this
-- screenplay, so an unmapped city or a missing file keeps its full civilian
-- crowd exactly as it always did -- the same fail-safe contract every other
-- WarBridge fraction in this file follows.
function WarBridge.civilianFlightFraction(screenplayInstance)
	local ok, region = pcall(WarBridge.getRegionForScreenplay, screenplayInstance.screenplayName)

	if not ok or region == nil or type(region.threat) ~= "number" then
		return 1.0
	end

	local cfg = WarBridge.CIVILIAN_FLIGHT
	local threat = region.threat
	if threat < 0 then threat = 0 end
	if threat > 1 then threat = 1 end

	local supplyPenalty = cfg.SUPPLY_PENALTY[region.supply_status] or 0.00

	local f = 1.0 - (threat * cfg.THREAT_COEFF) - supplyPenalty

	if f < cfg.FLOOR then f = cfg.FLOOR end
	if f > 1.0 then f = 1.0 end

	return f
end

--- Shared "how many of N rows survive this fraction" arithmetic for both
-- the civilian and military dials. Always rounds UP (ceil), same as the
-- original density-gating code did, and never returns 0 for a nonempty
-- list when minCount >= 1 -- every call site here uses minCount = 1,
-- because "zero rows spawned" is the exact "looks abandoned" failure the
-- owner's ruling was written to avoid.
function WarBridge.computeSpawnCount(total, fraction, minCount)
	if total <= 0 then
		return 0
	end

	local count = math.ceil(total * fraction)

	if count < minCount then
		count = minCount
	end
	if count > total then
		count = total
	end

	return count
end

--- The faction-swap template for one patrol entry. `templateField` is
-- patrol[2] from a patrolMobiles row: either a bare string (stock -- passed
-- through unchanged) or a {imperial_template, rebel_template} table (new --
-- resolved by the same region.faction WarBridge.resolveFaction would use).
function WarBridge.resolvePatrolTemplate(screenplayInstance, templateField)
	if type(templateField) ~= "table" then
		return templateField
	end

	local ok, region = pcall(WarBridge.getRegionForScreenplay, screenplayInstance.screenplayName)
	local faction = (ok and region ~= nil) and region.faction or nil

	if faction == "rebel" and templateField[2] ~= nil then
		return templateField[2]
	end

	-- Imperial, neutral, or war-state unavailable: imperial slot, the same
	-- "neutral defaults to Imperial" convention city.lua's own
	-- spawnGcwMobiles already uses.
	return templateField[1]
end

-- ================================================ CityScreenPlay overrides ==

--- Key holding the CSV of oids this screenplay currently has spawned.
local function warSpawnedKey(screenplayName)
	return "warbridge:spawned:" .. tostring(screenplayName)
end

--- Remember one spawned NPC so a later flip can despawn it.
local function warTrackSpawn(screenplayName, oid)
	local key = warSpawnedKey(screenplayName)
	local existing = readStringData(key)
	if existing == nil or existing == "" then
		writeStringData(key, tostring(oid))
	else
		writeStringData(key, existing .. "," .. tostring(oid))
	end
end

--- Forget everything tracked for a screenplay.
local function warClearTracked(screenplayName)
	writeStringData(warSpawnedKey(screenplayName), "")
end

--- Iterate the tracked oids.
local function warTrackedOids(screenplayName)
	local out = {}
	local raw = readStringData(warSpawnedKey(screenplayName))
	if raw == nil or raw == "" then
		return out
	end
	for token in string.gmatch(raw, "([^,]+)") do
		local n = tonumber(token)
		if n ~= nil and n > 0 then
			out[#out + 1] = n
		end
	end
	return out
end

-- Capture the vanilla spawnMob once per VM incarnation, on a FIELD of the
-- table (same re-capture-on-reload mechanism this file's header documents).
if CityScreenPlay._warOriginalSpawnMob == nil then
	CityScreenPlay._warOriginalSpawnMob = CityScreenPlay.spawnMob
end

--- Replaces city.lua's spawnMob. Identical behaviour, plus: it returns the
-- spawned NPC and records its oid so WarBridge.reskin() can despawn it later.
--
-- The template selection below is city.lua's own, unchanged: a gcwMobs row
-- with fewer than 9 fields carries a single template, while a row with 9+
-- fields carries an IMPERIAL template at [1] and a REBEL one at [2]. That is
-- the mechanism the faction swap actually rides on.
function CityScreenPlay:spawnMob(num, controllingFaction, difficulty)
	local mobsTable = self.gcwMobs

	if num <= 0 or num > #mobsTable then
		return nil
	end

	local mobTable = mobsTable[num]
	local npcTemplate, x, y, z, heading, parentID
	local npcMood = ""
	local scanner = false

	if #mobTable < 9 then
		npcTemplate = mobTable[1]
		x = mobTable[2]
		z = mobTable[3]
		y = mobTable[4]
		heading = mobTable[5]
		parentID = mobTable[6]
		npcMood = mobTable[7]
		scanner = mobTable[8]
	else
		x = mobTable[3]
		z = mobTable[4]
		y = mobTable[5]
		heading = mobTable[6]
		parentID = mobTable[7]
		scanner = mobTable[10]
		if controllingFaction == FACTIONIMPERIAL then
			npcTemplate = mobTable[1]
			npcMood = mobTable[8]
		else
			npcTemplate = mobTable[2]
			npcMood = mobTable[9]
		end
	end

	local scaling = ""
	if difficulty > 1 and creatureTemplateExists(npcTemplate .. "_hard") then
		scaling = "_hard"
	end

	local pNpc = spawnMobile(self.planet, npcTemplate .. scaling, 0, x, z, y, heading, parentID)

	if pNpc ~= nil then
		if npcMood ~= "" then
			self:setMoodString(pNpc, npcMood)
		end
		if scanner then
			AiAgent(pNpc):addObjectFlag(SCANNING_FOR_CONTRABAND)
		end

		AiAgent(pNpc):addObjectFlag(AI_STATIC)
		createObserver(CREATUREDESPAWNED, self.screenplayName, "onDespawn", pNpc)

		local oid = SceneObject(pNpc):getObjectID()
		writeData(oid, num)
		warTrackSpawn(self.screenplayName, oid)
	end

	return pNpc
end

--- Despawn and re-spawn one city's GCW garrison so it reflects the CURRENT
-- controlling faction. Called when that city's region changes hands.
--
-- Destroys with destroyObjectFromWorld(false) -- no despawn event -- so
-- city.lua's onDespawn does NOT fire and does NOT queue its own 5-minute
-- respawn. Without that, every reskinned NPC would come back a second time
-- five minutes later and the town would end up double-garrisoned.
function WarBridge.reskin(screenplayName)
	local pScreenplay = _G[screenplayName]
	if pScreenplay == nil or type(pScreenplay) ~= "table" then
		printf("WarBridge.reskin: unknown screenplay " .. tostring(screenplayName) .. "\n")
		return 0, 0
	end

	local removed = 0
	local oids = warTrackedOids(screenplayName)
	for i = 1, #oids do
		local pNpc = getSceneObject(oids[i])
		if pNpc ~= nil then
			pcall(function()
				deleteData(oids[i])
				SceneObject(pNpc):destroyObjectFromWorld(false)
			end)
			removed = removed + 1
		end
	end
	warClearTracked(screenplayName)

	local spawned = 0
	pcall(function()
		pScreenplay:spawnGcwMobiles()
		spawned = #warTrackedOids(screenplayName)
	end)

	printf("WarBridge.reskin: " .. tostring(screenplayName)
		.. " despawned " .. removed .. ", respawned " .. spawned .. "\n")
	return removed, spawned
end

--- Reskin every city mapped to `regionId`. Returns how many screenplays were
-- reskinned, so callers can log a flip that mapped to no city at all.
function WarBridge.reskinRegion(regionId)
	if WAR_REGION_MAP == nil then
		return 0
	end

	local n = 0
	local names = {}
	for screenplayName, mapped in pairs(WAR_REGION_MAP) do
		if mapped == regionId then
			names[#names + 1] = screenplayName
		end
	end
	table.sort(names)  -- stable order

	for i = 1, #names do
		WarBridge.reskin(names[i])
		n = n + 1
	end

	if n == 0 then
		printf("WarBridge.reskinRegion: no city screenplay maps to " .. tostring(regionId) .. "\n")
	end
	return n
end

function CityScreenPlay:spawnGcwMobiles()
	if not isZoneEnabled(self.planet) then
		return
	end

	local difficulty = getWinningFactionDifficultyScaling(self.planet)
	local controllingFaction = WarBridge.resolveFaction(self)

	for i = 1, #self.gcwMobs do
		self:spawnMob(i, controllingFaction, difficulty)
	end
end

function CityScreenPlay:respawn(pAiAgent, args)
	local mobNumber = tonumber(args)
	local difficulty = getWinningFactionDifficultyScaling(self.planet)
	local controllingFaction = WarBridge.resolveFaction(self)

	self:spawnMob(mobNumber, controllingFaction, difficulty)
end

--- Spawns a subset of self.patrolMobiles, using TWO independent fractions:
-- combat rows (patrol[9] == true) are gated by
-- WarBridge.militaryPatrolDensityFraction (garrison strength), civilian
-- rows (patrol[9] ~= true) by WarBridge.civilianFlightFraction (threat +
-- supply). Each row's own field decides which dial applies to it -- a
-- mixed patrol list gets both dials applied, each to its own rows, then the
-- two selected subsets are merged back into ascending index order so
-- spawnPatrol's own per-row logic (mood, observers, patrol points) runs
-- exactly as it always has, just on a filtered set of indices.
--
-- Fail-safe: if the war state has no opinion on either fraction, both
-- fractions come back 1.0, every row's minCount-vs-total math resolves to
-- "spawn all", and the merged set is the full patrol list in original
-- order -- byte-identical to stock behaviour.
function CityScreenPlay:spawnPatrolMobiles()
	if not isZoneEnabled(self.planet) then
		return
	end

	local total = #self.patrolMobiles

	local civilianIndices, combatIndices = {}, {}
	for i = 1, total do
		if self.patrolMobiles[i][9] == true then
			combatIndices[#combatIndices + 1] = i
		else
			civilianIndices[#civilianIndices + 1] = i
		end
	end

	local militaryFraction = 1.0
	local okM, fM = pcall(WarBridge.militaryPatrolDensityFraction, self)
	if okM and type(fM) == "number" then
		militaryFraction = fM
	end

	local civilianFraction = 1.0
	local okC, fC = pcall(WarBridge.civilianFlightFraction, self)
	if okC and type(fC) == "number" then
		civilianFraction = fC
	end

	local combatSpawnCount = WarBridge.computeSpawnCount(#combatIndices, militaryFraction, 1)
	local civilianSpawnCount = WarBridge.computeSpawnCount(#civilianIndices, civilianFraction, 1)

	local toSpawn = {}
	for i = 1, civilianSpawnCount do
		toSpawn[#toSpawn + 1] = civilianIndices[i]
	end
	for i = 1, combatSpawnCount do
		toSpawn[#toSpawn + 1] = combatIndices[i]
	end
	table.sort(toSpawn)

	for i = 1, #toSpawn do
		self:spawnPatrol(toSpawn[i])
	end
end

--- Spawns a subset of self.stationaryMobiles, using ONLY the civilian-flight
-- fraction -- stationaryMobiles has no combat/military concept in city.lua,
-- every row is a civilian. Structured identically to the civilian half of
-- spawnPatrolMobiles above (same fraction function, same
-- computeSpawnCount floor of 1), just without the patrol[9] split since
-- there is nothing to split.
--
-- This is what makes the flight look deliberate instead of arbitrary (the
-- owner's own words): without it, a contested town's patrols thin out but
-- its stationary vendors/idlers stay at full stock count, which reads as a
-- bug, not a warzone.
function CityScreenPlay:spawnStationaryMobiles()
	if not isZoneEnabled(self.planet) then
		return
	end

	local total = #self.stationaryMobiles

	local civilianFraction = 1.0
	local ok, f = pcall(WarBridge.civilianFlightFraction, self)
	if ok and type(f) == "number" then
		civilianFraction = f
	end

	local spawnCount = WarBridge.computeSpawnCount(total, civilianFraction, 1)

	for i = 1, spawnCount do
		self:spawnStationaryMobile(i)
	end
end

function CityScreenPlay:spawnPatrol(num)
	local patrolsTable = self.patrolMobiles

	if num <= 0 or num > #patrolsTable then
		return
	end

	local patrol = patrolsTable[num]
	local points = patrol[1]
	local template = patrol[2]
	local pMobile = nil
	local mood = patrol[8]

	if type(template) == "table" then
		local ok, resolved = pcall(WarBridge.resolvePatrolTemplate, self, template)
		if ok and resolved ~= nil then
			template = resolved
		else
			template = template[1] -- fail safe: imperial slot
		end
	elseif (template == "patrolNpc") then
		local patrolNpcs = self.patrolNpcs
		local templateNum = getRandomNumber(#patrolNpcs)

		template = patrolNpcs[templateNum]
	elseif (template == "combatPatrol") then
		local combatPatrol = self.combatPatrol
		local templateNum = getRandomNumber(#combatPatrol)

		template = combatPatrol[templateNum]
	end

	-- Everything below this line is byte-for-byte city.lua's stock
	-- spawnPatrol body (spawn/mood/observer/event wiring) -- only the
	-- template resolution above it changed.
	--{patrolPoints, template, x, z, y, direction, cell, mood, combatPatrol}
	local pMobile = spawnMobile(self.planet, template, 0, patrol[3], patrol[4], patrol[5], patrol[6], patrol[7])

	if (pMobile ~= nil and points ~= nil) then
		if mood ~= "" then
			self:setMoodString(pMobile, mood)
		end

		local pOid = SceneObject(pMobile):getObjectID()
		local combatNpc = patrol[9]

		writeData(pOid .. ":patrolNumber", num)

		if combatNpc then
			createObserver(CREATUREDESPAWNED, self.screenplayName, "onDespawnPatrol", pMobile)
			return
		else
			CreatureObject(pMobile):setPvpStatusBitmask(0)
		end

		createEvent(10000, self.screenplayName, "setupMobilePatrol", pMobile, num)
		writeStringData(pOid .. ":patrolPoints", points)
		writeData(pOid .. ":currentLoc", 1)
	end
end

-- =============================================== live-server test helpers ==
--
-- Exposed for `runLuaFunction WarBridgeTest:<fn>:<arg1>:<arg2>` from the
-- server console (deploy/scripts/reload-lua.sh's companion for exercising
-- this file against the live server -- see the task report for the actual
-- transcript). Not called by anything else; safe to leave installed.

WarBridgeTest = WarBridgeTest or {}

--- Report, without spawning anything, which template each gcwMobs slot in
-- `screenplayName` WOULD resolve to right now via the real
-- WarBridge.resolveFaction path (same function spawnGcwMobiles uses).
function WarBridgeTest:describeGcwChoice(screenplayName)
	local sp = _G[screenplayName]
	if sp == nil or sp.gcwMobs == nil then
		return "ERROR: unknown or non-city screenplay " .. tostring(screenplayName)
	end

	local controllingFaction = WarBridge.resolveFaction(sp)
	local factionLabel = "imperial"
	if controllingFaction == FACTIONREBEL then
		factionLabel = "rebel"
	end

	local templates = {}
	for i = 1, #sp.gcwMobs do
		local mobTable = sp.gcwMobs[i]
		local t
		if #mobTable < 9 then
			t = mobTable[1]
		elseif controllingFaction == FACTIONIMPERIAL then
			t = mobTable[1]
		else
			t = mobTable[2]
		end
		templates[#templates + 1] = t
	end

	return "faction=" .. factionLabel .. " count=" .. #templates .. " templates=" .. table.concat(templates, ",")
end

--- Actually spawn one gcwMobs slot via the real production spawnMob path,
-- report what came out (template + object id), then immediately despawn
-- it again -- a real, reversible, in-world proof for a single NPC without
-- leaving the server in a different state than it started in.
function WarBridgeTest:spawnOneAndDestroy(screenplayName, mobIndexStr)
	local sp = _G[screenplayName]
	if sp == nil or sp.gcwMobs == nil then
		return "ERROR: unknown or non-city screenplay " .. tostring(screenplayName)
	end

	local mobIndex = tonumber(mobIndexStr)
	local mobTable = sp.gcwMobs[mobIndex]
	if mobTable == nil then
		return "ERROR: bad mob index " .. tostring(mobIndexStr)
	end

	local controllingFaction = WarBridge.resolveFaction(sp)
	local factionLabel = "imperial"
	if controllingFaction == FACTIONREBEL then
		factionLabel = "rebel"
	end

	local template, x, z, y, heading, parentID
	if #mobTable < 9 then
		template, x, z, y, heading, parentID = mobTable[1], mobTable[2], mobTable[3], mobTable[4], mobTable[5], mobTable[6]
	else
		x, z, y, heading, parentID = mobTable[3], mobTable[4], mobTable[5], mobTable[6], mobTable[7]
		if controllingFaction == FACTIONIMPERIAL then
			template = mobTable[1]
		else
			template = mobTable[2]
		end
	end

	local pNpc = spawnMobile(sp.planet, template, 0, x, z, y, heading, parentID)
	if pNpc == nil then
		return "ERROR: spawnMobile returned nil for template " .. tostring(template)
	end

	local oid = SceneObject(pNpc):getObjectID()
	SceneObject(pNpc):destroyObjectFromWorld()

	return "faction=" .. factionLabel .. " template=" .. template .. " oid=" .. tostring(oid) .. " (spawned via production spawnMob path, then destroyed for proof)"
end

--- Dump the resolved region/faction/density for one screenplay, straight
-- from WarBridge, for eyeballing during the demo.
function WarBridgeTest:describeRegion(screenplayName)
	local region, regionId = WarBridge.getRegionForScreenplay(screenplayName)
	if region == nil then
		return "unmapped or war-state unavailable for " .. tostring(screenplayName)
	end

	local sp = _G[screenplayName]
	local civilianFraction, militaryFraction = "n/a", "n/a"
	if sp ~= nil then
		local okC, fC = pcall(WarBridge.civilianFlightFraction, sp)
		if okC then civilianFraction = tostring(fC) end
		local okM, fM = pcall(WarBridge.militaryPatrolDensityFraction, sp)
		if okM then militaryFraction = tostring(fM) end
	end

	return "region=" .. tostring(regionId)
		.. " faction=" .. tostring(region.faction)
		.. " contest=" .. tostring(region.contest)
		.. " garrison=" .. tostring(region.garrison_strength)
		.. " threat=" .. tostring(region.threat)
		.. " supply_status=" .. tostring(region.supply_status)
		.. " density=" .. tostring(region.patrol_density)
		.. " density_fraction=" .. tostring(region.density_fraction)
		.. " militaryPatrolDensityFraction=" .. militaryFraction
		.. " civilianFlightFraction=" .. civilianFraction
		.. " checkpoint_level=" .. tostring(region.checkpoint_level)
end
