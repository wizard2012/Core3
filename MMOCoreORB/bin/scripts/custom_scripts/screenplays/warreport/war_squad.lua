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
WarSquad.SQUAD_SECONDS   = 900     -- 15 min. In practice the battle cycle expires first.
WarSquad.TICK_MS         = 10000   -- How often presence is re-evaluated into attachment.

-- commanderOid -> { troops = { npcOid, ... }, expiresAt = <ms> }
WarSquad.squads = {}
-- npcOid -> commanderOid, so a trooper is never claimed twice.
WarSquad.claimed = {}
-- commanderOid -> pPlayer, populated by ENTEREDAREA, cleared by EXITEDAREA.
WarSquad.present = {}

local function now()
	return os.time() * 1000
end

--- Spawn the proximity area for one staged battle site.
-- Called by war_battle.lua as it stages each site. Safe on bad input.
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
		WarSquad.present[SceneObject(pCreature):getObjectID()] = pCreature
	end)
	return 0
end

--- Left the radius. Site-local means exactly this: the squad is released.
function WarSquad:onExitedArea(pArea, pCreature)
	pcall(function()
		if pCreature == nil or not SceneObject(pCreature):isPlayerCreature() then
			return
		end
		local oid = SceneObject(pCreature):getObjectID()
		WarSquad.present[oid] = nil
		WarSquad.release(oid)
	end)
	return 0
end

--- Is this player entitled to a squad right now?
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

	local squad = WarSquad.squads[commanderOid]
	if squad == nil then
		squad = { troops = {}, expiresAt = now() + (WarSquad.SQUAD_SECONDS * 1000) }
		WarSquad.squads[commanderOid] = squad
	end

	for _, oid in ipairs(stagedOids()) do
		if #squad.troops >= WarSquad.MAX_TROOPS then
			break
		end
		if WarSquad.claimed[oid] == nil then
			local pNpc = getSceneObject(oid)
			if pNpc ~= nil and CreatureObject(pNpc):getFaction() == faction then
				local ok = pcall(function()
					local agent = AiAgent(pNpc)
					-- Store first, so release can put the trooper back on
					-- whatever it was doing rather than leaving it oblivious
					-- in the middle of a firefight.
					agent:storeFollowObject()
					agent:setFollowObject(pPlayer)
				end)
				if ok then
					WarSquad.claimed[oid] = commanderOid
					squad.troops[#squad.troops + 1] = oid
				end
			end
		end
	end

	return #squad.troops
end

--- Release a commander's whole squad and put each trooper back.
function WarSquad.release(commanderOid)
	local squad = WarSquad.squads[commanderOid]
	if squad == nil then
		return
	end

	for _, oid in ipairs(squad.troops) do
		WarSquad.claimed[oid] = nil
		local pNpc = getSceneObject(oid)
		if pNpc ~= nil then
			-- Best effort: the trooper may already have been despawned by
			-- war_battle.lua's cleanup, which still owns it in this slice.
			pcall(function()
				AiAgent(pNpc):restoreFollowObject()
			end)
		end
	end

	WarSquad.squads[commanderOid] = nil
end

--- Recurring: turn presence into attachment, and expire what is stale.
function WarSquad:tick()
	pcall(function()
		-- Expire first, so a released trooper can be re-claimed this same pass.
		for commanderOid, squad in pairs(WarSquad.squads) do
			local pCommander = getSceneObject(commanderOid)
			if pCommander == nil or now() >= squad.expiresAt then
				WarSquad.release(commanderOid)
			end
		end

		for commanderOid, pPlayer in pairs(WarSquad.present) do
			if qualifies(pPlayer) then
				local n = WarSquad.claimFor(pPlayer)
				if n > 0 then
					printf("WarSquad: commander " .. tostring(commanderOid)
						.. " has " .. tostring(n) .. " troop(s)\n")
				end
			end
		end
	end)

	createEvent(WarSquad.TICK_MS, "WarSquad", "tick", nil, "")
	return 0
end

--- Started from war_battle.lua's own start path so there is one owner of the
-- war screenplays' lifecycle, not two competing ones.
function WarSquad:start()
	createEvent(WarSquad.TICK_MS, "WarSquad", "tick", nil, "")
end
