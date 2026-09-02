--[[
  custom_scripts/screenplays/warreport/war_battle.lua

  Live skirmishes at the front: two squads of opposing GCW NPCs spawned in the
  field near a contested region, set on each other, that a player can walk into
  and join.

  WHY THIS EXISTS
  ---------------
  Until now the war was legible but not fightable. Region control changed which
  faction garrisons a town and how thick its patrols are, and flips were
  broadcast -- but there was nowhere to actually SEE the war being fought.
  Stock Core3 does not help: screenplays/battlefields/battlefield_spawner.lua
  places battlefield MARKERS (no-build radius objects) and spawns no
  combatants at all, so there is no existing NPC-vs-NPC fighting anywhere in
  the game to join.

  HOW THE FIGHTING ACTUALLY WORKS
  -------------------------------
  AiAgent:setDefender(target) is the documented-by-example mechanism -- it is
  what screenplays/events/syren/syren.lua uses to set NPCs on a player. It
  takes any SceneObject, so pointing two AI agents at each other makes them
  engage. Each combatant is given one opposing defender on spawn; Core3's own
  aggro then keeps the melee going as they retaliate.

  WHERE BATTLES HAPPEN
  --------------------
  At the most-contested region, offset from the town centre by BATTLE_OFFSET_M
  so the fight is in open ground rather than inside a starport. Contest is the
  sim's own measure of where the fighting is, so the battles land wherever the
  simulation says the war is hottest -- they are an expression of the war, not
  decoration sprinkled at random.

  A player can join simply by attacking: these are ordinary faction NPCs, so a
  faction-aligned player is free to engage the opposing side.

  LIFECYCLE AND WHY IT IS BOUNDED
  -------------------------------
  A battle despawns after BATTLE_LIFETIME_MS whether or not anyone won, and
  only one battle exists at a time. That is deliberate: NPCs that fight to the
  death and are never cleaned up accumulate corpses, hold references, and would
  eventually be indistinguishable from a leak. The despawn is unconditional so
  a battle can never outlive its own bookkeeping.
]]

WarBattle = WarBattle or {}

WarBattle.screenplayName = "WarBattle"

-- Squad size per side. Small on purpose: this is a skirmish a solo player or
-- a pair can meaningfully affect, not a set piece that ignores them.
WarBattle.SQUAD_SIZE = 4

-- Metres from the town centre. Far enough to be open ground, close enough to
-- be found by someone who just read "fighting is heaviest at X".
WarBattle.BATTLE_OFFSET_M = 180

-- Spacing between the two lines, and between troopers within a line.
WarBattle.LINE_GAP_M = 18
WarBattle.TROOPER_GAP_M = 5

-- How long a battle lives before it is cleaned up regardless of outcome.
WarBattle.BATTLE_LIFETIME_MS = 10 * 60 * 1000

-- How often a new battle is considered.
WarBattle.BATTLE_INTERVAL_MS = 12 * 60 * 1000

-- Contest at or above which a region is considered worth fighting over. Below
-- this the sim says nothing is happening there, and staging a battle would be
-- inventing a war the simulation does not have.
WarBattle.MIN_CONTEST = 1.0

-- Combatant templates. Verified present in the running server by the
-- warBridgeCheck probe, which listed them among templates the cities spawn.
WarBattle.TROOPS = {
	imperial = { "stormtrooper", "stormtrooper_rifleman", "sand_trooper" },
	rebel    = { "rebel_trooper", "rebel_commando", "rebel_scout" },
}

WarBattle.OIDS_KEY = "warbattle:oids"
WarBattle.REGION_KEY = "warbattle:region"

registerScreenPlay("WarBattle", true)

function WarBattle:start()
	if not isZoneEnabled("tatooine") then
		return
	end
	-- First battle on a delay, for the same reason WarOfficer spawns late:
	-- the war state may not be readable on this thread at start() time.
	createEvent(45000, "WarBattle", "cycle", nil, "")
end

-- ================================================================ helpers ==

local function trackOid(oid)
	local raw = readStringData(WarBattle.OIDS_KEY)
	if raw == nil or raw == "" then
		writeStringData(WarBattle.OIDS_KEY, tostring(oid))
	else
		writeStringData(WarBattle.OIDS_KEY, raw .. "," .. tostring(oid))
	end
end

local function trackedOids()
	local out = {}
	local raw = readStringData(WarBattle.OIDS_KEY)
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

--- Deterministic pick, so a given region/slot always fields the same trooper
-- type. Avoids needing an RNG and keeps repeat visits visually stable.
local function pickTemplate(faction, index, salt)
	local pool = WarBattle.TROOPS[faction]
	if pool == nil or #pool == 0 then
		return nil
	end
	local h = index
	for i = 1, #salt do
		h = (h * 31 + salt:byte(i)) % 100003
	end
	return pool[(h % #pool) + 1]
end

-- ================================================================ cleanup ==

function WarBattle:clear()
	local oids = trackedOids()
	local removed = 0
	for i = 1, #oids do
		local pObj = getSceneObject(oids[i])
		if pObj ~= nil then
			pcall(function() SceneObject(pObj):destroyObjectFromWorld(false) end)
			removed = removed + 1
		end
	end
	writeStringData(WarBattle.OIDS_KEY, "")
	return removed
end

--- Timed teardown. Unconditional: a battle never outlives its bookkeeping.
function WarBattle:endBattle()
	local removed = WarBattle:clear()
	local region = readStringData(WarBattle.REGION_KEY)
	printf("WarBattle: ended battle at " .. tostring(region) .. ", despawned " .. removed .. "\n")
	writeStringData(WarBattle.REGION_KEY, "")
end

-- ================================================================== spawn ==

--- Choose where to fight: the most contested region that has coordinates.
function WarBattle:pickRegion()
	if WarReport == nil or WarReport.state() == nil then
		return nil
	end

	local front = WarReport.frontRegions(WarBattle.MIN_CONTEST)
	for i = 1, #front do
		local id = front[i].id
		if WarReport.COORDS[id] ~= nil then
			return id, front[i].faction, front[i].contest
		end
	end
	return nil
end

function WarBattle:spawnBattle()
	local regionId, holder, contest = WarBattle:pickRegion()
	if regionId == nil then
		printf("WarBattle: no contested region with coordinates -- no battle staged\n")
		return false
	end

	local coords = WarReport.COORDS[regionId]
	local zone = WarReport.PLANET_OF[regionId]
	if coords == nil or zone == nil or not isZoneEnabled(zone) then
		return false
	end

	-- The holder defends; the other faction attacks.
	local defender = holder
	local attacker = (holder == "rebel") and "imperial" or "rebel"

	local baseX = coords[1] + WarBattle.BATTLE_OFFSET_M
	local baseY = coords[2] + WarBattle.BATTLE_OFFSET_M

	local defenders, attackers = {}, {}

	for i = 1, WarBattle.SQUAD_SIZE do
		local dTemplate = pickTemplate(defender, i, regionId .. "d")
		local aTemplate = pickTemplate(attacker, i, regionId .. "a")

		local dx = baseX + (i - 1) * WarBattle.TROOPER_GAP_M
		local dy = baseY
		local ax = baseX + (i - 1) * WarBattle.TROOPER_GAP_M
		local ay = baseY + WarBattle.LINE_GAP_M

		local pD = dTemplate and spawnMobile(zone, dTemplate, 0, dx, 0, dy, 0, 0) or nil
		local pA = aTemplate and spawnMobile(zone, aTemplate, 0, ax, 0, ay, 180, 0) or nil

		if pD ~= nil then
			defenders[#defenders + 1] = pD
			trackOid(SceneObject(pD):getObjectID())
		end
		if pA ~= nil then
			attackers[#attackers + 1] = pA
			trackOid(SceneObject(pA):getObjectID())
		end
	end

	if #defenders == 0 or #attackers == 0 then
		printf("WarBattle: failed to field both sides at " .. regionId .. " -- clearing\n")
		WarBattle:clear()
		return false
	end

	-- Set them on each other. setDefender is the mechanism syren.lua uses to
	-- put an AI into combat with a target; pointing both sides at each other
	-- starts the fight, and Core3's own retaliation keeps it going.
	local pairs_n = math.min(#defenders, #attackers)
	for i = 1, pairs_n do
		pcall(function() AiAgent(defenders[i]):setDefender(attackers[i]) end)
		pcall(function() AiAgent(attackers[i]):setDefender(defenders[i]) end)
	end

	writeStringData(WarBattle.REGION_KEY, regionId)

	printf(string.format("WarBattle: %d %s vs %d %s at %s (%s) contest=%.2f -- (%d, %d)\n",
		#defenders, tostring(defender), #attackers, tostring(attacker),
		tostring(regionId), tostring(zone), contest or 0, baseX, baseY))

	createEvent(WarBattle.BATTLE_LIFETIME_MS, "WarBattle", "endBattle", nil, "")
	return true
end

--- One turn of the loop: tear down any previous battle, stage a new one,
-- schedule the next turn.
function WarBattle:cycle()
	pcall(function() WarBattle:clear() end)
	pcall(function() WarBattle:spawnBattle() end)
	createEvent(WarBattle.BATTLE_INTERVAL_MS, "WarBattle", "cycle", nil, "")
end
