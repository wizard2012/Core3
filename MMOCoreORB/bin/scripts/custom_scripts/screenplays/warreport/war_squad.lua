--[[
  war_squad.lua -- SLICE 1 of B27: troops fall in behind an overt player.

  WHAT THIS SLICE IS, AND WHAT IT DELIBERATELY IS NOT. docs/DESIGN-SQUAD.md
  section 10 defines the first slice as Formup only: overt, 6 troops,
  site-local, fixed lifetime, NO war credit, NO adoption, NO restocking, and no
  change to the NPC budget. It exists to answer the one question that cannot be
  answered from a log -- whether commanding troops is any fun -- before any of
  the tuning on top of it is built. Everything in D23/D24/D25 beyond that is
  intentionally absent. Do not add it here without reading those first.

  THE CONSEQUENCE THAT MAKES THIS SLICE SAFE: because troops are NOT adopted,
  war_battle.lua's cleanup still owns every one of them. Its cycle reaps its
  tracked OIDs as it always did, so this file can leak nothing, needs no reaper
  of its own, and does not move the hard-48 budget. A squad's real lifetime is
  therefore min(SQUAD_SECONDS, whatever the battle cycle has left) -- usually
  the cycle. That is expected, not a bug.

  NO C++ WAS NEEDED. An earlier reading of this claimed AiAgent's follow
  machinery was not exposed to Lua. That was wrong -- LuaAiAgent.cpp:33
  registers setFollowObject, along with storeFollowObject/restoreFollowObject
  (:38-39) and setOblivious (:34). So the whole slice is screenplay Lua and
  lands in the RELOAD bucket, not the restart bucket.

  WHY AN ACTIVE AREA. There is no "players in range" helper exposed to Lua --
  the registered-function list in DirectorManager.cpp has no range query at
  all. spawnActiveArea plus an ENTEREDAREA/EXITEDAREA observer is the idiomatic
  proximity mechanism in this codebase and is what quest screenplays use. One
  area per staged site, destroyed with the site.

  GATING, and every one of these is a real Lua binding, checked before writing:
  isPlayerCreature (SceneObject), isOvert and getFactionStatus
  (LuaTangibleObject, exposed via LuaCreatureObject :121/:152), isInCombat
  (:143) and getFaction (:90). The OVERT constant is a Lua global
  (DirectorManager.cpp:781).
]]

WarSquad = ScreenPlay:new {}

WarSquad.MAX_TROOPS      = 6       -- D23. Reads as a squad; leaves troops for a second player.
WarSquad.AREA_RADIUS_M   = 48      -- Proximity for "nearby". Roughly one battle site.
WarSquad.CLAIM_RADIUS_M  = 150     -- How far from the commander a troop may be claimed: the
                                   -- site itself (defenders at its origin, attackers advancing
                                   -- from APPROACH_DISTANCE_M = 120 out), and nothing beyond.
WarSquad.SQUAD_SECONDS   = 900     -- 15 min. In practice the battle cycle expires first.
WarSquad.TICK_MS         = 10000   -- How often presence is re-evaluated into attachment.

-- Persistent registry of every proximity area attachSite() has spawned, so
-- they can be destroyed on the next cycle. A plain Lua table would NOT do:
-- reload-lua.sh throws every in-memory table away (see war_login.lua's header)
-- and an area whose OID we forgot is an area that can never be reaped. This
-- closes a real leak -- attachSite() was called once per site per 4-minute
-- cycle with its result discarded and nothing destroying it.
WarSquad.AREAS_KEY = "warsquad:areas"

-- commanderOid -> { troops = { npcOid, ... }, expiresAt = <ms> }
-- STATE IS SHARED, NOT A LUA TABLE (2026-09-06). Each thread has its own Lua
-- VM, so the tables this used to keep were empty on every thread but the
-- one that filled them: the area handlers, the tick and WarCommand.take's
-- release each saw a different squad list. The record lives in shared
-- string data now, the way war_command.lua keeps its record:
--   warsquad:squad:<commanderOid>   "<expiresAtMs>|oid,oid,..."
--   warsquad:claimed:<troopOid>     commanderOid (readData; 0 = free)
--   warsquad:commanders             "oid,oid"     (for the tick)
--   warsquad:present                "oid,oid"     (players inside a formup area)
WarSquad.COMMANDERS_KEY = "warsquad:commanders"
WarSquad.PRESENT_KEY = "warsquad:present"
-- npcOid -> commanderOid, so a trooper is never claimed twice.
-- commanderOid -> pPlayer, populated by ENTEREDAREA, cleared by EXITEDAREA.

local function now()
	return os.time() * 1000
end

--- Spawn the proximity area for one staged battle site.
-- Called by war_battle.lua as it stages each site. Safe on bad input.
local function squadKey(commanderOid)
	return "warsquad:squad:" .. tostring(commanderOid)
end

local function claimedKey(oid)
	return "warsquad:claimed:" .. tostring(oid)
end

local function readList(key)
	local out = {}
	local raw = readStringData(key)
	if raw ~= nil and raw ~= "" then
		for tok in string.gmatch(raw, "(%d+)") do out[#out + 1] = tonumber(tok) end
	end
	return out
end

local function writeList(key, list)
	local ids = {}
	for _, oid in ipairs(list) do ids[#ids + 1] = tostring(oid) end
	writeStringData(key, table.concat(ids, ","))
end

local function listAdd(key, oid)
	local list = readList(key)
	for _, o in ipairs(list) do
		if o == oid then return end
	end
	list[#list + 1] = oid
	writeList(key, list)
end

local function listDrop(key, oid)
	local list, kept = readList(key), {}
	for _, o in ipairs(list) do
		if o ~= oid then kept[#kept + 1] = o end
	end
	writeList(key, kept)
end

--- The squad record: { troops = {oid...}, expiresAt = ms } or nil.
function WarSquad.squadOf(commanderOid)
	local raw = readStringData(squadKey(commanderOid))
	if raw == nil or raw == "" then
		return nil
	end
	local expires, list = string.match(raw, "^(%d+)|(.*)$")
	if expires == nil then
		return nil
	end
	local troops = {}
	for tok in string.gmatch(list, "(%d+)") do troops[#troops + 1] = tonumber(tok) end
	return { troops = troops, expiresAt = tonumber(expires) or 0 }
end

local function writeSquad(commanderOid, squad)
	local ids = {}
	for _, oid in ipairs(squad.troops) do ids[#ids + 1] = tostring(oid) end
	writeStringData(squadKey(commanderOid), tostring(math.floor(squad.expiresAt)) .. "|" .. table.concat(ids, ","))
	listAdd(WarSquad.COMMANDERS_KEY, commanderOid)
end

--- Is this staged NPC in someone's automatic squad?
function WarSquad.isClaimed(oid)
	local c = readData(claimedKey(oid))
	return c ~= nil and c > 0
end

function WarSquad.attachSite(zoneName, x, y)
	if zoneName == nil or x == nil or y == nil then
		return nil
	end

	local pArea = nil
	local ok = pcall(function()
		-- Arg order is (zone, iff, x, z, y, radius, cell) -- C++ reads x at -5,
		-- z at -4 and y at -3 (DirectorManager.cpp:3157-3163). Ground plane is
		-- (x, y) with z the height, matching war_battle.lua's own spawnMobile
		-- calls, so z is 0 here.
		pArea = spawnActiveArea(zoneName, "object/active_area.iff", x, 0, y,
			WarSquad.AREA_RADIUS_M, 0)
		if pArea ~= nil then
			createObserver(ENTEREDAREA, "WarSquad", "onEnteredArea", pArea)
			createObserver(EXITEDAREA, "WarSquad", "onExitedArea", pArea)

			local oid = SceneObject(pArea):getObjectID()
			local raw = readStringData(WarSquad.AREAS_KEY)
			if raw == nil or raw == "" then
				writeStringData(WarSquad.AREAS_KEY, tostring(oid))
			else
				writeStringData(WarSquad.AREAS_KEY, raw .. "," .. tostring(oid))
			end
		end
	end)

	if not ok then
		return nil
	end
	return pArea
end

--- A creature entered a site's radius. Record presence only; attachment is
-- decided on the tick, because a player who walks in and only THEN draws a
-- weapon must still get their squad.
function WarSquad:onEnteredArea(pArea, pCreature)
	pcall(function()
		if pCreature == nil or not SceneObject(pCreature):isPlayerCreature() then
			return
		end
		listAdd(WarSquad.PRESENT_KEY, SceneObject(pCreature):getObjectID())
	end)
	return 0
end

function WarSquad:onExitedArea(pArea, pCreature)
	pcall(function()
		if pCreature == nil or not SceneObject(pCreature):isPlayerCreature() then
			return
		end
		local oid = SceneObject(pCreature):getObjectID()
		listDrop(WarSquad.PRESENT_KEY, oid)
		WarSquad.release(oid)
	end)
	return 0
end

local function qualifies(pPlayer)
	if pPlayer == nil then
		return false
	end
	if not SceneObject(pPlayer):isPlayerCreature() then
		return false
	end

	local creo = CreatureObject(pPlayer)

	-- D23: overt only. Cheap for the player to satisfy -- this project already
	-- stripped /declareovert of its gate, its COVERT precondition and its 50m
	-- friendly-HQ requirement (DeclareOvertCommand.h:11-24), so declaring can
	-- be done standing at the front.
	if not creo:isOvert() then
		return false
	end

	local faction = creo:getFaction()
	if faction ~= FACTIONIMPERIAL and faction ~= FACTIONREBEL then
		return false
	end

	-- D23: proximity ALONE was rejected. Requiring combat is what stops a
	-- player merely travelling past a front from collecting a squad.
	if not creo:isInCombat() then
		return false
	end

	return true
end

--- Currently-staged battle NPCs, read from war_battle.lua's own tracking key
-- rather than a second copy of the list.
local function stagedOids()
	local out = {}
	local ok = pcall(function()
		local raw = readStringData(WarBattle.OIDS_KEY)
		if raw == nil or raw == "" then
			return
		end
		for token in string.gmatch(raw, "([^,]+)") do
			local oid = tonumber(token)
			if oid ~= nil then
				out[#out + 1] = oid
			end
		end
	end)
	if not ok then
		return {}
	end
	return out
end

--- Give `pPlayer` up to MAX_TROOPS unclaimed, same-faction battle NPCs.
function WarSquad.claimFor(pPlayer)
	local commanderOid = SceneObject(pPlayer):getObjectID()
	local faction = CreatureObject(pPlayer):getFaction()
	local squad = WarSquad.squadOf(commanderOid)
	if squad == nil then
		squad = { troops = {}, expiresAt = now() + (WarSquad.SQUAD_SECONDS * 1000) }
	end
	local zoneName = SceneObject(pPlayer):getZoneName()
	local px, py = SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY()
	local reach2 = WarSquad.CLAIM_RADIUS_M * WarSquad.CLAIM_RADIUS_M
	local changed = false
	for _, oid in ipairs(stagedOids()) do
		if #squad.troops >= WarSquad.MAX_TROOPS then
			break
		end
		local commanded = (WarCommand ~= nil and WarCommand.isCommanded ~= nil) and WarCommand.isCommanded(oid) or false
		if (not WarSquad.isClaimed(oid)) and not commanded then
			local pNpc = getSceneObject(oid)
			local near = false
			if pNpc ~= nil and CreatureObject(pNpc):getFaction() == faction
				and SceneObject(pNpc):getZoneName() == zoneName then
				local dx = SceneObject(pNpc):getWorldPositionX() - px
				local dy = SceneObject(pNpc):getWorldPositionY() - py
				near = (dx * dx + dy * dy) <= reach2
			end
			if near then
				local ok = pcall(function()
					local agent = AiAgent(pNpc)
					agent:storeFollowObject()
					agent:setFollowObject(pPlayer)
					agent:executeBehavior()
				end)
				if ok then
					writeData(claimedKey(oid), commanderOid)
					squad.troops[#squad.troops + 1] = oid
					changed = true
				end
			end
		end
	end
	if changed or readStringData(squadKey(commanderOid)) == nil or readStringData(squadKey(commanderOid)) == "" then
		writeSquad(commanderOid, squad)
	end
	return #squad.troops
end

function WarSquad.clearAreas()
	pcall(function()
		local raw = readStringData(WarSquad.AREAS_KEY)
		if raw == nil or raw == "" then
			return
		end

		for token in string.gmatch(raw, "([^,]+)") do
			local oid = tonumber(token)
			if oid ~= nil then
				local pArea = getSceneObject(oid)
				if pArea ~= nil then
					pcall(function() SceneObject(pArea):destroyObjectFromWorld(false) end)
				end
			end
		end

		writeStringData(WarSquad.AREAS_KEY, "")
	end)
end

--- Release a commander's whole squad and put each trooper back.
function WarSquad.release(commanderOid)
	local squad = WarSquad.squadOf(commanderOid)
	if squad == nil then
		listDrop(WarSquad.COMMANDERS_KEY, commanderOid)
		return
	end
	for _, oid in ipairs(squad.troops) do
		writeData(claimedKey(oid), 0)
		local pNpc = getSceneObject(oid)
		if pNpc ~= nil then
			-- Best effort: the trooper may already have been despawned by
			-- war_battle.lua's cleanup, which still owns it.
			pcall(function()
				local a = AiAgent(pNpc)
				a:restoreFollowObject()
				-- restoreFollowObject with nothing stored only paths home and
				-- leaves the pointer on the player (the D2 verifier's finding,
				-- 2026-09-05; setFollowObject(nil) is a no-op). If it still
				-- names the commander, drop it.
				local f = a:getFollowObject()
				if f ~= nil and SceneObject(f):getObjectID() == commanderOid then
					a:clearFollowObject()
				end
				a:executeBehavior()
			end)
		end
	end
	pcall(function() deleteStringData(squadKey(commanderOid)) end)
	listDrop(WarSquad.COMMANDERS_KEY, commanderOid)
end

function WarSquad:tick()
	pcall(function()
		for _, commanderOid in ipairs(readList(WarSquad.COMMANDERS_KEY)) do
			local squad = WarSquad.squadOf(commanderOid)
			local pCommander = getSceneObject(commanderOid)
			if squad == nil or pCommander == nil or now() >= squad.expiresAt then
				WarSquad.release(commanderOid)
			end
		end
		for _, playerOid in ipairs(readList(WarSquad.PRESENT_KEY)) do
			local pPlayer = getSceneObject(playerOid)
			if pPlayer == nil then
				listDrop(WarSquad.PRESENT_KEY, playerOid)
			elseif qualifies(pPlayer) then
				local n = WarSquad.claimFor(pPlayer)
				if n > 0 then
					printf("WarSquad: commander " .. tostring(playerOid)
						.. " has " .. tostring(n) .. " troop(s)\n")
				end
			end
		end
	end)
	createEvent(WarSquad.TICK_MS, "WarSquad", "tick", nil, "")
	return 0
end

function WarSquad:start()
	createEvent(WarSquad.TICK_MS, "WarSquad", "tick", nil, "")
end
