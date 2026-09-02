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
    (b) spawn only a war-state-driven PREFIX of the patrol list, sized by
    DESIGN-UNITS.md S:U7.2's density_fraction, so a contested/frontier
    region visibly patrols heavier than a quiet interior one.

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
  (getControllingFaction(self.planet), or the full unfiltered patrol list).
  bridge/tests/t_failsafe.lua exercises the pure decision logic; the live
  server test in the task report exercises the real file.
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

--- Fraction (0..1) of the stock patrol list this region should spawn right
-- now, per DESIGN-UNITS.md S:U7.2 (already computed server-side by
-- bridge/war_state_writer.lua -- this file only reads the number). Returns
-- 1.0 (spawn everything, i.e. stock behaviour) whenever the war state
-- doesn't have an opinion, so an unmapped city or a missing file patrols
-- exactly as it always did.
function WarBridge.patrolDensityFraction(screenplayInstance)
	local ok, region = pcall(WarBridge.getRegionForScreenplay, screenplayInstance.screenplayName)

	if not ok or region == nil or type(region.density_fraction) ~= "number" then
		return 1.0
	end

	local f = region.density_fraction
	if f < 0 then f = 0 end
	if f > 1 then f = 1 end

	return f
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

function CityScreenPlay:spawnPatrolMobiles()
	if not isZoneEnabled(self.planet) then
		return
	end

	local total = #self.patrolMobiles
	local spawnCount = total

	local ok, fraction = pcall(WarBridge.patrolDensityFraction, self)
	if ok and type(fraction) == "number" then
		spawnCount = math.ceil(total * fraction)
		if spawnCount < 1 and total > 0 then
			spawnCount = 1 -- never a fully empty patrol list -- U7.2's own
			               -- worked example bottoms out at 0.4/16, not 0
		end
		if spawnCount > total then
			spawnCount = total
		end
	end

	for i = 1, spawnCount do
		self:spawnPatrol(i)
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

	return "region=" .. tostring(regionId)
		.. " faction=" .. tostring(region.faction)
		.. " contest=" .. tostring(region.contest)
		.. " garrison=" .. tostring(region.garrison_strength)
		.. " density=" .. tostring(region.patrol_density)
		.. " density_fraction=" .. tostring(region.density_fraction)
		.. " checkpoint_level=" .. tostring(region.checkpoint_level)
end
