--[[
  custom_scripts/screenplays/population/street_life.lua

  Ambient street life: a small persistent boot set of civilian figures per
  war-mapped city (an anchor NPC plus a few extras, plus cantina patrons
  where a cantina spot exists), and a presence-gated per-city tick that
  speaks a war-state-appropriate line of overheard dialogue
  (population/street_lines.lua's STREET_LINES) and occasionally walks a
  traveller across town. Reads street_config.lua for every tunable.

  WHY ALL 13 CITIES ARE AFFORDABLE (owner ruling, docs/BACKLOG.md)
  ------------------------------------------------------------------
  The boot set (anchor + a couple of extras + a couple of cantina patrons,
  respawnTimer=0, non-combat) is a small fixed footprint per city -- roughly
  5 NPCs x 13 cities, none of them ever auto-respawning. The recurring cost
  (chatter scanning, traveller spawning) is what the presence gate in
  tickOnce() actually protects: a city with nobody in getPlayersInRange of
  its anchor does nothing at all past the sweep, every tick, forever. Bodies
  exist; activity only happens where someone is looking.

  COORDINATE SOURCING (the one hard rule this file must never break)
  ----------------------------------------------------------------------
  Every coordinate spawned at is read, at runtime, from data that already
  shipped and was already reviewed:
    - anchor + extra stationary figures: that city's own
      screenplays/cities/*.lua stationaryMobiles rows (row 1 reserved for the
      anchor, the rest for extras) -- the exact rows CityScreenPlay's own
      spawnStationaryMobiles() spawns from, just a few additional rows spoken
      for by this file instead.
    - cantina patrons: population_config.lua's POPULATION_CANTINAS entry for
      the region (only 12 of 13 cities have one; tat_anchorhead gets 0).
    - travellers: spawned at population_config.lua's POPULATION_AID_POSTS
      entry ("each city's real starport/shuttleport", per that file's own
      comment) and walked along that city's own patrolPoints route (the
      SAME waypoint tables CityScreenPlay's patrol NPCs already walk).
  Nothing here invents a new x/y/z. Spawn placement is not terrain-aware
  (backlog B21, and war_battle.lua's own PLACEMENT note) -- reusing rows
  the game already spawns real NPCs at is the mitigation available without
  terrain data.

  FACTION RULE -- ENFORCED IN CODE, NOT BY TEMPLATE CHOICE
  ------------------------------------------------------------
  Every spawn here is verified post-spawn via
  TangibleObject(pNpc):getFaction() and destroyed immediately (never
  tracked) if it comes back FACTIONIMPERIAL or FACTIONREBEL -- see
  enforceFactionSafe(). This is deliberately not "trust the civilian
  template lists", because war_battle.lua's 48 combat NPCs must remain the
  only source of killable GCW combatants; a faction-flagged ambient body
  would let a player farm npc_kill_faction credit this feature was never
  meant to grant.

  RESPAWN RULE
  ------------
  Every spawnMobile call here passes respawnTimer=0.
  AiAgentImplementation.cpp's notifyDespawn only schedules a
  RespawnCreatureTask when respawnTimer > 0 -- 0 (or negative) means the
  agent simply stays dead when destroyed, which is what lets
  populationStreetOff (and the off-switch generally) actually mean off.

  LIFECYCLE SHAPE (copied from warreport/war_battle.lua)
  -----------------------------------------------------------
  Per city: one flat list of tracked oids (kind + expiry), swept
  unconditionally at the top of every tick before anything else runs; the
  whole per-tick body wrapped in one pcall; the next tick's createEvent
  scheduled UNCONDITIONALLY, outside that pcall, so a mid-tick error can
  never freeze a city's loop. tickOnce() is kept separate from cityTick()
  (which only adds the pcall + reschedule) so probes can call tickOnce()
  directly, as many times as needed, without ever creating a second parallel
  timer chain for that city -- calling the real cityTick() from a probe would
  do exactly that.

  PERSISTENCE
  -----------
  Per-city tracked-oid lists and the chatter ring live in STRING shared
  memory (writeStringSharedMemory/readStringSharedMemory) -- survives
  reloadscreenplays and is visible from every VM/thread, unlike readData/
  writeData which is per-key but was proven awkward for a growing list
  elsewhere in this codebase (see war_hook.lua's own CSV-in-a-string
  approach, same idea, just shared-memory-backed here). The anchor oid,
  last-speak timestamp, and heartbeat are plain (numeric)
  writeSharedMemory/readSharedMemory, matching population/
  standing_services.lua's own use of shared memory for a single npc oid.
]]

StreetLife = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "StreetLife",
}

registerScreenPlay("StreetLife", true)

-- ============================================================== keys ====

local function oidsKey(regionId)
	return "streetlife:oids:" .. regionId
end

local function ringKey(regionId)
	return "streetlife:ring:" .. regionId
end

local function lastSpeakKey(regionId)
	return "streetlife:lastspeak:" .. regionId
end

local function anchorKey(regionId)
	return "streetlife:anchor:" .. regionId
end

local HEARTBEAT_KEY = "streetlife:heartbeat"

-- Logs the content-floor refusal once per pool per city per VM incarnation,
-- not once per tick -- a small file-local upvalue, reset on every reload,
-- same idea as war_hook.lua's _warOriginalSpawnMob re-capture guard.
local contentFloorLogged = {}

-- ================================================== tracked-oid records ==
--
-- Serialized as "oid:kind:expiresAtMs" entries joined by ";". expiresAtMs
-- of 0 means "no TTL -- persists until explicitly removed" (the boot set:
-- anchor/stationary/cantina). A positive expiresAtMs is a hard sweep
-- deadline (travellers).

function StreetLife:parseRecords(regionId)
	local raw = readStringSharedMemory(oidsKey(regionId))
	local out = {}
	if raw == nil or raw == "" then
		return out
	end
	for token in string.gmatch(raw, "([^;]+)") do
		local oidStr, kind, expiresStr = token:match("^(%d+):(%a+):(%d+)$")
		if oidStr ~= nil then
			out[#out + 1] = { oid = tonumber(oidStr), kind = kind, expiresAt = tonumber(expiresStr) }
		end
	end
	return out
end

function StreetLife:serializeRecords(regionId, records)
	local parts = {}
	for i = 1, #records do
		local r = records[i]
		parts[#parts + 1] = tostring(r.oid) .. ":" .. r.kind .. ":" .. tostring(r.expiresAt)
	end
	writeStringSharedMemory(oidsKey(regionId), table.concat(parts, ";"))
end

function StreetLife:trackRecord(regionId, oid, kind, expiresAt)
	local records = self:parseRecords(regionId)
	records[#records + 1] = { oid = oid, kind = kind, expiresAt = expiresAt or 0 }
	self:serializeRecords(regionId, records)
end

function StreetLife:removeRecord(regionId, oid)
	local records = self:parseRecords(regionId)
	local kept = {}
	for i = 1, #records do
		if records[i].oid ~= oid then
			kept[#kept + 1] = records[i]
		end
	end
	self:serializeRecords(regionId, kept)
end

function StreetLife:clearCity(regionId)
	writeStringSharedMemory(oidsKey(regionId), "")
end

--- Despawn anything past its TTL, drop dead oids (object already gone by
-- some other means -- killed by a player, zone unload, etc). Runs before
-- anything else in every tick. Returns the surviving record list.
function StreetLife:sweepCity(regionId)
	local records = self:parseRecords(regionId)
	local kept = {}
	local now = getTimestampMilli()

	for i = 1, #records do
		local r = records[i]
		local pObj = getSceneObject(r.oid)

		if pObj == nil then
			-- already gone; drop silently
		elseif r.expiresAt > 0 and now >= r.expiresAt then
			pcall(function() SceneObject(pObj):destroyObjectFromWorld(false) end)
		else
			kept[#kept + 1] = r
		end
	end

	self:serializeRecords(regionId, kept)
	return kept
end

-- ===================================================== faction safety ===

--- "imperial" / "rebel" / "neutral" / "none" for logging and the dump probe.
function StreetLife:factionLabel(pNpc)
	local ok, faction = pcall(function() return TangibleObject(pNpc):getFaction() end)
	if not ok then
		return "unknown"
	end
	if faction == FACTIONIMPERIAL then
		return "imperial"
	elseif faction == FACTIONREBEL then
		return "rebel"
	elseif faction == FACTIONNEUTRAL then
		return "neutral"
	end
	return "none"
end

--- Enforced here, not by picking templates carefully (see file header).
-- Returns true and leaves pNpc alone if it is safe to keep; returns false
-- and destroys pNpc (never tracked) if it came back faction-flagged.
function StreetLife:enforceFactionSafe(pNpc)
	local ok, faction = pcall(function() return TangibleObject(pNpc):getFaction() end)

	if ok and (faction == FACTIONIMPERIAL or faction == FACTIONREBEL) then
		printf("StreetLife: REFUSED faction-flagged spawn oid=" .. tostring(SceneObject(pNpc):getObjectID())
			.. " faction=" .. tostring(faction) .. " -- destroying, not tracking\n")
		pcall(function() SceneObject(pNpc):destroyObjectFromWorld(false) end)
		return false
	end

	return true
end

-- =========================================================== templates ==

--- Same 80/20 stationaryNpcs/stationaryCommoners split CityScreenPlay's own
-- spawnStationaryMobile uses -- these are the lists stock Core3 already
-- spawns unattended civilians from for this exact city.
function StreetLife:pickCivilianTemplate(sp)
	local pool = nil

	if getRandomNumber(100) < 20 and type(sp.stationaryNpcs) == "table" and #sp.stationaryNpcs > 0 then
		pool = sp.stationaryNpcs
	elseif type(sp.stationaryCommoners) == "table" and #sp.stationaryCommoners > 0 then
		pool = sp.stationaryCommoners
	elseif type(sp.stationaryNpcs) == "table" and #sp.stationaryNpcs > 0 then
		pool = sp.stationaryNpcs
	end

	if pool == nil then
		return nil
	end

	return pool[getRandomNumber(#pool)]
end

--- Pedestrian templates used for the city's own patrol NPCs -- reused for
-- travellers so a traveller looks like the same kind of person already
-- walking this town.
function StreetLife:pickPatrolTemplate(sp)
	local pool = sp.patrolNpcs
	if type(pool) ~= "table" or #pool == 0 then
		pool = sp.stationaryCommoners
	end
	if type(pool) ~= "table" or #pool == 0 then
		return nil
	end
	return pool[getRandomNumber(#pool)]
end

--- The alphabetically-first patrolPoints route in this city's own table --
-- deterministic (no RNG needed) and always an existing, already-walked
-- route. Returns nil, nil if the city has no patrolPoints at all.
function StreetLife:firstRoute(sp)
	if type(sp.patrolPoints) ~= "table" then
		return nil, nil
	end

	local names = {}
	for name, _ in pairs(sp.patrolPoints) do
		names[#names + 1] = name
	end
	if #names == 0 then
		return nil, nil
	end
	table.sort(names)

	local routeName = names[1]
	return routeName, sp.patrolPoints[routeName]
end

-- ================================================== civilian-flight tie-in ==

--- baseCount scaled by WarBridge.civilianFlightFraction for this city, via
-- WarBridge.computeSpawnCount (the SAME rounding/floor arithmetic
-- war_hook.lua's own civilian rows use) -- never a second opinion about how
-- thin a contested town's crowd should be. WarBridge.civilianFlightFraction
-- only reads screenplayInstance.screenplayName (see war_hook.lua), so a
-- plain { screenplayName = ... } table is a valid argument.
function StreetLife:scaledCount(screenplayName, baseCount)
	if baseCount <= 0 then
		return 0
	end

	local fraction = 1.0
	if WarBridge ~= nil and WarBridge.civilianFlightFraction ~= nil then
		local ok, f = pcall(WarBridge.civilianFlightFraction, { screenplayName = screenplayName })
		if ok and type(f) == "number" then
			fraction = f
		end
	end

	if WarBridge ~= nil and WarBridge.computeSpawnCount ~= nil then
		local ok, count = pcall(WarBridge.computeSpawnCount, baseCount, fraction, 1)
		if ok and type(count) == "number" then
			return count
		end
	end

	return baseCount
end

-- ==================================================================== spawn ==

--- Spawn one civilian figure at an already-vetted coordinate. respawnTimer
-- is always 0, pvp bitmask always 0, and the spawn is destroyed (never
-- tracked) if enforceFactionSafe refuses it. Returns the AiAgent or nil.
function StreetLife:spawnCivilianAt(sp, zone, x, z, y, heading, cell)
	local template = self:pickCivilianTemplate(sp)
	if template == nil then
		return nil
	end

	local pNpc = spawnMobile(zone, template, 0, x, z, y, heading or 0, cell or 0)
	if pNpc == nil then
		return nil
	end

	if not self:enforceFactionSafe(pNpc) then
		return nil
	end

	CreatureObject(pNpc):setPvpStatusBitmask(0)
	AiAgent(pNpc):addObjectFlag(AI_STATIONARY)

	return pNpc
end

-- Small, fixed nudge so 2+ cantina patrons at one certified point don't
-- perfectly overlap -- the same idea as war_battle.lua's TROOPER_GAP_M, not
-- a new coordinate.
StreetLife.CANTINA_PATRON_SPACING_M = 1.5

--- Boot set for one city: anchor + extras (from stationaryMobiles) and
-- cantina patrons (from POPULATION_CANTINAS), then start that city's timer.
-- Safe to call more than once (e.g. from the populationStreetNow probe) --
-- it does not check for an existing boot set itself, so callers that care
-- about double-booting (the probe) gate on the heartbeat first.
function StreetLife:bootCity(regionId)
	local screenplayName = STREET_CONFIG.screenplayNameFor(regionId)
	if screenplayName == nil then
		return
	end

	local sp = _G[screenplayName]
	if sp == nil or type(sp.stationaryMobiles) ~= "table" or #sp.stationaryMobiles == 0 then
		return
	end

	if not isZoneEnabled(sp.planet) then
		return
	end

	-- Anchor: reserve stationaryMobiles row 1.
	local anchorRow = sp.stationaryMobiles[1]
	local pAnchor = self:spawnCivilianAt(sp, sp.planet, anchorRow[2], anchorRow[3], anchorRow[4], anchorRow[5], anchorRow[6])
	if pAnchor ~= nil then
		local anchorOid = SceneObject(pAnchor):getObjectID()
		writeSharedMemory(anchorKey(regionId), anchorOid)
		self:trackRecord(regionId, anchorOid, "anchor", 0)
	end

	-- Extra stationary figures: rows 2..N, scaled by civilian flight.
	local available = #sp.stationaryMobiles - 1
	local wanted = self:scaledCount(screenplayName, STREET_CONFIG.EXTRA_STATIONARY_PER_CITY)
	local extraCount = math.min(wanted, available)
	for i = 1, extraCount do
		local row = sp.stationaryMobiles[1 + i]
		local pNpc = self:spawnCivilianAt(sp, sp.planet, row[2], row[3], row[4], row[5], row[6])
		if pNpc ~= nil then
			self:trackRecord(regionId, SceneObject(pNpc):getObjectID(), "stationary", 0)
		end
	end

	-- Cantina patrons, only where population_config.lua has a spot.
	local cantina = POPULATION_CANTINAS and POPULATION_CANTINAS[regionId]
	if cantina ~= nil then
		local wantedCantina = self:scaledCount(screenplayName, STREET_CONFIG.CANTINA_PATRONS_PER_CITY)
		for i = 1, wantedCantina do
			local offset = (i - 1) * self.CANTINA_PATRON_SPACING_M
			local pNpc = self:spawnCivilianAt(sp, cantina.zone, cantina.x + offset, cantina.z, cantina.y, cantina.heading or 0, cantina.cell or 0)
			if pNpc ~= nil then
				self:trackRecord(regionId, SceneObject(pNpc):getObjectID(), "cantina", 0)
			end
		end
	end

	createEvent(self:jitterMs(), "StreetLife", "cityTick", nil, regionId)
end

function StreetLife:jitterMs()
	return getRandomNumber(STREET_CONFIG.TICK_MIN_MS, STREET_CONFIG.TICK_MAX_MS)
end

-- =============================================================== presence ==

--- Players within STREET_CONFIG.PRESENCE_RADIUS_M of this city's anchor.
-- getPlayersInRange returns nil when there is no zone -- treated as zero,
-- never as an error.
function StreetLife:playersNear(regionId)
	local anchorOid = readSharedMemory(anchorKey(regionId))
	if anchorOid == nil or anchorOid == 0 then
		return 0
	end

	local pAnchor = getSceneObject(anchorOid)
	if pAnchor == nil then
		return 0
	end

	local ok, players = pcall(function() return SceneObject(pAnchor):getPlayersInRange(STREET_CONFIG.PRESENCE_RADIUS_M) end)
	if not ok or players == nil then
		return 0
	end

	return #players
end

-- ================================================================ chatter ==

--- plaza_quiet / plaza_frontier / plaza_contested (by region.threat and
-- region.frontier) for an outdoor talker, or cantina for an indoor one.
function StreetLife:poolFor(regionId, kind)
	if kind == "cantina" then
		return "cantina"
	end

	local threat, frontier = 0, false
	if WarReport ~= nil then
		local st = WarReport.state()
		if st ~= nil and st.regions[regionId] ~= nil then
			local region = st.regions[regionId]
			if type(region.threat) == "number" then
				threat = region.threat
			end
			frontier = region.frontier == true
		end
	end

	if threat >= STREET_CONFIG.CONTESTED_THREAT then
		return "plaza_contested"
	elseif threat > 0 or frontier then
		return "plaza_frontier"
	end

	return "plaza_quiet"
end

function StreetLife:pushRing(regionId, key)
	local raw = readStringSharedMemory(ringKey(regionId)) or ""
	local items = {}
	for token in string.gmatch(raw, "([^,]+)") do
		items[#items + 1] = token
	end
	items[#items + 1] = key
	while #items > STREET_CONFIG.CHATTER_RING_SIZE do
		table.remove(items, 1)
	end
	writeStringSharedMemory(ringKey(regionId), table.concat(items, ","))
end

--- A line index from `pool` not present in this city's recent-line ring,
-- tried up to 30 times before giving up and allowing a repeat (the ring is
-- always much smaller than a >=60-line pool, so a repeat should be rare).
-- Returns the index and the ring key ("poolName:idx") to push on success.
function StreetLife:pickLineIndexAndKey(regionId, poolName, pool)
	local raw = readStringSharedMemory(ringKey(regionId)) or ""
	local used = {}
	for token in string.gmatch(raw, "([^,]+)") do
		used[token] = true
	end

	for attempt = 1, 30 do
		local idx = getRandomNumber(#pool)
		local key = poolName .. ":" .. idx
		if not used[key] then
			return idx, key
		end
	end

	local idx = getRandomNumber(#pool)
	return idx, poolName .. ":" .. idx
end

--- Pick a talker within CHATTER_RANGE_M of a player and speak one line,
-- honouring the per-city minimum gap and recent-line ring. No-ops (silently)
-- if the gap hasn't elapsed, no talker is in range, or the chosen pool is
-- under the content floor.
function StreetLife:speakIfEligible(regionId, sp)
	local now = getTimestampMilli()
	local lastSpeak = readSharedMemory(lastSpeakKey(regionId))
	if lastSpeak ~= nil and lastSpeak ~= 0 and (now - lastSpeak) < STREET_CONFIG.CHATTER_MIN_GAP_MS then
		return
	end

	local records = self:parseRecords(regionId)
	local eligible = {}
	for i = 1, #records do
		local r = records[i]
		if r.kind ~= "traveler" then
			local pObj = getSceneObject(r.oid)
			if pObj ~= nil then
				local ok, players = pcall(function() return SceneObject(pObj):getPlayersInRange(STREET_CONFIG.CHATTER_RANGE_M) end)
				if ok and players ~= nil and #players > 0 then
					eligible[#eligible + 1] = { pObj = pObj, kind = r.kind }
				end
			end
		end
	end

	if #eligible == 0 then
		return
	end

	local pick = eligible[getRandomNumber(#eligible)]
	local poolName = self:poolFor(regionId, pick.kind)
	local pool = STREET_LINES and STREET_LINES[poolName]

	if type(pool) ~= "table" or #pool < 60 then
		local logKey = regionId .. ":" .. tostring(poolName)
		if not contentFloorLogged[logKey] then
			contentFloorLogged[logKey] = true
			printf("StreetLife: pool '" .. tostring(poolName) .. "' has fewer than 60 lines (or is missing) -- chatter disabled for " .. regionId .. " in this context\n")
		end
		return
	end

	local idx, key = self:pickLineIndexAndKey(regionId, poolName, pool)
	spatialChat(pick.pObj, pool[idx])

	self:pushRing(regionId, key)
	writeSharedMemory(lastSpeakKey(regionId), now)
end

-- ============================================================== travellers ==

function StreetLife:globalTravelerCount()
	local total = 0
	for regionId, enabled in pairs(STREET_CONFIG.CITIES) do
		if enabled then
			local records = self:parseRecords(regionId)
			for i = 1, #records do
				if records[i].kind == "traveler" then
					total = total + 1
				end
			end
		end
	end
	return total
end

--- Spawns at most one traveller this tick, gated by chance, per-city cap,
-- and the global cap -- under STREET_CONFIG.TRAVELLER_SPAWN_CHANCE_PCT so
-- a busy plaza doesn't get a new traveller literally every tick.
function StreetLife:maybeSpawnTraveler(regionId, sp)
	if getRandomNumber(100) > STREET_CONFIG.TRAVELLER_SPAWN_CHANCE_PCT then
		return
	end

	local records = self:parseRecords(regionId)
	local cityTravelers = 0
	for i = 1, #records do
		if records[i].kind == "traveler" then
			cityTravelers = cityTravelers + 1
		end
	end
	if cityTravelers >= STREET_CONFIG.TRAVELLER_PER_CITY_CAP then
		return
	end
	if self:globalTravelerCount() >= STREET_CONFIG.TRAVELLER_GLOBAL_CAP then
		return
	end

	local shuttle = POPULATION_AID_POSTS and POPULATION_AID_POSTS[regionId]
	if shuttle == nil then
		return
	end

	local routeName, points = self:firstRoute(sp)
	if routeName == nil or points == nil or #points == 0 then
		return
	end

	local template = self:pickPatrolTemplate(sp)
	if template == nil then
		return
	end

	local pMobile = spawnMobile(shuttle.zone, template, 0, shuttle.x, shuttle.z, shuttle.y, shuttle.heading or 0, shuttle.cell or 0)
	if pMobile == nil then
		return
	end

	if not self:enforceFactionSafe(pMobile) then
		return
	end

	CreatureObject(pMobile):setPvpStatusBitmask(0)

	local oid = SceneObject(pMobile):getObjectID()
	writeData(oid .. ":streetlife:loc", 1)
	writeStringData(oid .. ":streetlife:region", regionId)
	writeStringData(oid .. ":streetlife:route", routeName)

	local firstPoint = points[1]
	AiAgent(pMobile):setNextPosition(firstPoint[1], firstPoint[2], firstPoint[3], firstPoint[4])
	createObserver(DESTINATIONREACHED, "StreetLife", "travelerDestinationReached", pMobile)

	self:trackRecord(regionId, oid, "traveler", getTimestampMilli() + STREET_CONFIG.TRAVELLER_TTL_MS)
end

--- One-way route walk: advance to the next patrolPoints entry, or despawn
-- (route finished) when there is none left. Never loops back to point 1 the
-- way CityScreenPlay's own patrol NPCs do -- a traveller's whole point is to
-- arrive somewhere and disappear, not patrol forever.
function StreetLife:travelerDestinationReached(pMobile)
	if pMobile == nil then
		return 0
	end

	local oid = SceneObject(pMobile):getObjectID()
	local regionId = readStringData(oid .. ":streetlife:region")
	local routeName = readStringData(oid .. ":streetlife:route")

	local screenplayName = regionId ~= nil and regionId ~= "" and STREET_CONFIG.screenplayNameFor(regionId) or nil
	local sp = screenplayName ~= nil and _G[screenplayName] or nil

	if sp == nil or type(sp.patrolPoints) ~= "table" or sp.patrolPoints[routeName] == nil then
		self:despawnTraveler(regionId, oid, pMobile)
		return 0
	end

	local points = sp.patrolPoints[routeName]
	local loc = readData(oid .. ":streetlife:loc") or 0

	if loc >= #points then
		self:despawnTraveler(regionId, oid, pMobile)
		return 0
	end

	loc = loc + 1
	writeData(oid .. ":streetlife:loc", loc)

	local p = points[loc]
	AiAgent(pMobile):setNextPosition(p[1], p[2], p[3], p[4])

	return 0
end

function StreetLife:despawnTraveler(regionId, oid, pMobile)
	if pMobile ~= nil then
		pcall(function() SceneObject(pMobile):destroyObjectFromWorld(false) end)
	end
	if regionId ~= nil and regionId ~= "" and oid ~= nil then
		self:removeRecord(regionId, oid)
	end
end

-- ================================================================== tick ==

--- The actual per-tick work, with NO reschedule of its own -- so probes can
-- call this directly, repeatably, without ever creating a second parallel
-- timer chain for a city (see file header, LIFECYCLE SHAPE).
function StreetLife:tickOnce(regionId)
	writeSharedMemory(HEARTBEAT_KEY, getTimestampMilli())

	-- 1. Sweep first, always, before anything else this tick.
	self:sweepCity(regionId)

	if not STREET_CONFIG.ENABLED then
		return
	end

	local screenplayName = STREET_CONFIG.screenplayNameFor(regionId)
	if screenplayName == nil then
		return
	end

	local sp = _G[screenplayName]
	if sp == nil or not isZoneEnabled(sp.planet) then
		return
	end

	-- 2. Presence gate. No players near the anchor -> nothing else this tick.
	local nearby = self:playersNear(regionId)
	if nearby <= 0 then
		return
	end

	-- 3. Chatter.
	self:speakIfEligible(regionId, sp)

	-- 4. Travellers.
	self:maybeSpawnTraveler(regionId, sp)
end

--- Self-rescheduling timer entry point. Whole tick body in pcall; the
-- reschedule below is OUTSIDE that pcall and unconditional, so a mid-tick
-- error can never stop this city's loop (copied from war_battle.lua's
-- WarBattle:cycle()).
function StreetLife:cityTick(pObj, regionId)
	pcall(function() self:tickOnce(regionId) end)

	createEvent(self:jitterMs(), "StreetLife", "cityTick", nil, regionId)
end

-- ================================================================= start ==

-- Delay before the boot set actually spawns, same reason and same value as
-- warreport/war_battle.lua's WarBattle:start() and warreport/war_officer.lua:
-- at true start() time (DirectorManager's global-screenplay startup pass,
-- which the boot log shows finishing BEFORE "[ZoneServer] Managers Started")
-- isZoneEnabled(planet) is not yet true, so bootCity()'s own zone check would
-- silently skip every city if run synchronously here. Confirmed live: a
-- first pass of this file called bootCity directly from start() and every
-- one of the 13 cities came back with 0 tracked oids after a real restart.
StreetLife.BOOT_DELAY_MS = 45000

function StreetLife:start()
	if not STREET_CONFIG.ENABLED then
		return
	end

	createEvent(self.BOOT_DELAY_MS, "StreetLife", "bootAll", nil, "")
end

--- The actual boot-set spawn, separated from start() so both the real
-- delayed boot and the populationStreetNow probe (which wants this to run
-- immediately, not 45s from now) can call it directly.
function StreetLife:bootAll()
	writeSharedMemory(HEARTBEAT_KEY, getTimestampMilli())

	for regionId, enabled in pairs(STREET_CONFIG.CITIES) do
		if enabled then
			pcall(function() self:bootCity(regionId) end)
		end
	end
end
