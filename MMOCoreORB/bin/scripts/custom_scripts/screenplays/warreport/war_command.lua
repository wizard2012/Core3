--[[
  custom_scripts/screenplays/warreport/war_command.lua

  GRAND BATTLES slice D (docs/DESIGN-BATTLES.md section 4.1, owner ruling
  2026-09-05: "able to take command from the sergeant, then full Squad
  Leader profession integration"): a radial on a line's SERGEANT offers
  "Take command"; the whole line then follows the player, and the radial on
  any body of that line offers the orders -- Attack my target, Hold here,
  Fall back to me, Dismiss squad. One squad per player; taking a second
  releases the first. Any overt member of the squad's faction, no profession.

  THE SQUAD STAYS THE WAR'S. Nothing here adopts a body: every troop stays
  in war_battle.lua's roster, so reconcile still counts it, waves still
  reinforce its line, its death is still a casualty row, and the cycle's
  cleanup still owns it. What this file changes is only whom a body FOLLOWS
  and whom it is set on. war_battle.lua asks WarCommand.isCommanded(oid)
  before it re-points a body (waves, retreats, the stuck rule), and
  war_squad.lua (B27 slice 1, the automatic fall-in) skips commanded bodies.

  STATE IS SHARED, NOT A LUA TABLE. The radial handler, the tend pass and
  the probes run on whichever thread picks them up, and each thread has its
  own Lua VM; a table filled on one thread is empty on the next. So the
  command record lives in the same shared string data war_battle.lua uses:
    warcommand:<commanderOid>          "slotKey|faction|oid,oid,..."
    warcommand:troop:<troopOid>        commanderOid (readData; 0 = free)
    warcommand:commanders              "oid,oid" (for the tick)
  and survives reload-lua.sh as well.

  THE WAKE-UP APPLIES HERE TOO (DESIGN-BATTLES 3.4): every order ends in
  AiAgent:executeBehavior(). "Attack my target" is WarBattle.engage(), the
  one place a body is set on a target.

  RADIAL: SceneObject:setObjectMenuComponent("WarCommandMenuComponent") on
  every line body at spawn (war_battle.lua), the same runtime mechanism as
  war_officer_report.lua. A Lua menu component REPLACES the server-side
  radial for that object; the client still draws its own attack/examine
  entries, and an enemy body shows nothing extra (fillObjectMenuResponse
  gates on faction), so the war's NPCs lose nothing a player used before.

  RELOAD BUCKET: screenplay Lua. The tick rides on war_battle.lua's tend
  pass (WarCommand.tickOnce from WarBattle.tendOnce, every 75 s) so no new
  event chain and no restart is needed; a dead, absent, off-planet or
  no-longer-overt commander loses the squad within one tend pass.

  PROBE: test warCommandCheck -- spawns a stock stormtrooper as a stand-in
  commander (ALLOW_NPC_COMMANDER is set for the probe only), takes command
  of the first live Imperial line, issues hold / fall back / dismiss, and
  prints the squad size and each troop's follow state. The radial itself
  needs a client: docs/IN-GAME-TESTS.md section 8.

  D2 (the Squad Leader abilities, C++, 2026-09-05): SquadLeaderCommand.h
  treats a troop on the command record (warcommand:troop:<oid> == the
  commander) as a squad member for rally, boostmorale, steadyaim,
  volleyfire, formup and retreat whatever it is following -- so the orders,
  which move the follow pointer (attack follows the enemy, hold clears it),
  no longer drop the line out of the abilities. PROBE: test
  warSquadAbilityCheck walks a commanded line through taken, hold, fall
  back, attack and dismiss against the commands' own gate
  (CreatureObject:isSquadAbilityTarget / countSquadAbilityTargets).
]]

WarCommand = WarCommand or { screenplayName = "WarCommand" }

WarCommand.RADIAL = { TAKE = 20, ATTACK = 21, HOLD = 22, FALLBACK = 23, DISMISS = 24 }
WarCommand.MAX_SQUAD = 24            -- a line plus its waves; a walker is not a squad member
WarCommand.ALLOW_NPC_COMMANDER = false -- the probe flips this on and off around itself

WarCommand.COMMANDERS_KEY = "warcommand:commanders"

local function key(commanderOid)
	return "warcommand:" .. tostring(commanderOid)
end

local function troopKey(troopOid)
	return "warcommand:troop:" .. tostring(troopOid)
end

--- The war body's roster record: region, site, faction, kind ("w" for a
-- walker) -- or nil for a body the war does not track.
local function recordOf(oid)
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return nil
	end
	local want = tostring(oid)
	for rec in string.gmatch(raw, "([^;]+)") do
		local f = {}
		for field in string.gmatch(rec .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		if f[1] == want and f[2] ~= nil and f[3] ~= nil then
			return { oid = oid, region = f[2], site = f[3], faction = f[4], kind = f[7], slot = f[2] .. ":" .. f[3] }
		end
	end
	return nil
end

--- Every live, non-walker body of `faction` at `slotKey`, as pointers.
local function lineOf(slotKey, faction)
	local out = {}
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return out
	end
	for rec in string.gmatch(raw, "([^;]+)") do
		local f = {}
		for field in string.gmatch(rec .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		local oid = tonumber(f[1])
		if oid ~= nil and f[2] ~= nil and f[3] ~= nil and (f[2] .. ":" .. f[3]) == slotKey
				and f[4] == faction and f[7] ~= "w" then
			local p = getSceneObject(oid)
			if p ~= nil then
				local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
				if not (okd and dead) then
					out[#out + 1] = { oid = oid, p = p }
				end
			end
		end
	end
	return out
end

local function isSergeant(oid, rec)
	local sgt = readData("warbattle:sgt:" .. rec.slot .. ":" .. tostring(rec.faction))
	return sgt ~= nil and sgt == oid
end

local function factionName(n)
	if n == FACTIONIMPERIAL then return "imperial" end
	if n == FACTIONREBEL then return "rebel" end
	return nil
end

local function nameOf(pPlayer)
	local name = nil
	pcall(function() name = CreatureObject(pPlayer):getFirstName() end)
	if name == nil or name == "" then
		pcall(function() name = SceneObject(pPlayer):getDisplayedName() end)
	end
	return name or "commander"
end

local function tell(pPlayer, text)
	pcall(function() CreatureObject(pPlayer):sendSystemMessage(text) end)
end

local function say(pBody, kind, faction, who)
	if pBody == nil or WarVoice == nil or WarVoice.battle == nil then
		return
	end
	local line = WarVoice.battle(kind, faction, nil)
	if line ~= nil then
		if who ~= nil then
			line = string.gsub(line, "%%s", who)
		end
		pcall(function() spatialChat(pBody, line) end)
		printf("WarCommand: " .. tostring(faction) .. " says: " .. line .. "\n")
	end
end

--- May this creature command a line of `faction`? Returns ok, reason.
local function qualifies(pPlayer, faction)
	if pPlayer == nil then
		return false, "nobody"
	end
	local so = SceneObject(pPlayer)
	if not so:isPlayerCreature() and not WarCommand.ALLOW_NPC_COMMANDER then
		return false, "not a player"
	end
	local creo = CreatureObject(pPlayer)
	local mine = factionName(creo:getFaction())
	if mine == nil or mine ~= faction then
		return false, "wrong faction"
	end
	if so:isPlayerCreature() and not creo:isOvert() then
		return false, "not overt"
	end
	return true, nil
end

-- ------------------------------------------------------------- records --

function WarCommand.squadOf(commanderOid)
	local raw = readStringData(key(commanderOid))
	if raw == nil or raw == "" then
		return nil
	end
	local slot, faction, list = string.match(raw, "^([^|]+)|([^|]+)|(.*)$")
	if slot == nil then
		return nil
	end
	local troops = {}
	for tok in string.gmatch(list, "(%d+)") do
		troops[#troops + 1] = tonumber(tok)
	end
	return { slot = slot, faction = faction, troops = troops }
end

local function writeSquad(commanderOid, slot, faction, troops)
	local ids = {}
	for _, oid in ipairs(troops) do ids[#ids + 1] = tostring(oid) end
	writeStringData(key(commanderOid), slot .. "|" .. faction .. "|" .. table.concat(ids, ","))
end

local function commanders()
	local out = {}
	local raw = readStringData(WarCommand.COMMANDERS_KEY)
	if raw ~= nil and raw ~= "" then
		for tok in string.gmatch(raw, "(%d+)") do out[#out + 1] = tonumber(tok) end
	end
	return out
end

local function setCommanders(list)
	local ids = {}
	for _, oid in ipairs(list) do ids[#ids + 1] = tostring(oid) end
	writeStringData(WarCommand.COMMANDERS_KEY, table.concat(ids, ","))
end

local function addCommander(oid)
	local list = commanders()
	for _, o in ipairs(list) do
		if o == oid then return end
	end
	list[#list + 1] = oid
	setCommanders(list)
end

local function dropCommander(oid)
	local list, kept = commanders(), {}
	for _, o in ipairs(list) do
		if o ~= oid then kept[#kept + 1] = o end
	end
	setCommanders(kept)
end

--- war_battle.lua and war_squad.lua ask this before re-pointing a body.
function WarCommand.isCommanded(oid)
	local c = readData(troopKey(oid))
	return c ~= nil and c > 0
end

--- Live pointers of a commander's troops, pruning the dead and gone from
-- the record as a side effect. Returns the list (may be empty).
local function liveTroops(commanderOid, squad)
	local live, kept = {}, {}
	for _, oid in ipairs(squad.troops) do
		local p = getSceneObject(oid)
		local alive = false
		if p ~= nil then
			local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
			alive = not (okd and dead)
		end
		if alive then
			live[#live + 1] = { oid = oid, p = p }
			kept[#kept + 1] = oid
		else
			writeData(troopKey(oid), 0)
		end
	end
	if #kept ~= #squad.troops then
		squad.troops = kept
		writeSquad(commanderOid, squad.slot, squad.faction, kept)
	end
	return live
end

--- Attach the command radial to a war body. Called by war_battle.lua at
-- spawn; harmless to repeat.
function WarCommand.attach(pNpc)
	if pNpc == nil then
		return
	end
	pcall(function() SceneObject(pNpc):setObjectMenuComponent("WarCommandMenuComponent") end)
end

-- --------------------------------------------------------------- orders --

--- Take command of the line `pSgt` leads. Returns troops taken, or 0 and
-- a reason.
function WarCommand.take(pPlayer, pSgt)
	if pPlayer == nil or pSgt == nil then
		return 0, "nobody"
	end
	local sgtOid = SceneObject(pSgt):getObjectID()
	local rec = recordOf(sgtOid)
	if rec == nil or rec.faction == nil then
		return 0, "not a war body"
	end
	if not isSergeant(sgtOid, rec) then
		return 0, "not a sergeant"
	end
	local ok, why = qualifies(pPlayer, rec.faction)
	if not ok then
		return 0, why
	end
	local commanderOid = SceneObject(pPlayer):getObjectID()

	-- One squad per player: the old one goes back to the war first.
	if WarCommand.squadOf(commanderOid) ~= nil then
		WarCommand.release(commanderOid, "dismissed")
	end
	-- B27's automatic fall-in for this player yields to command.
	if WarSquad ~= nil and WarSquad.release ~= nil then
		pcall(WarSquad.release, commanderOid)
	end

	local taken = {}
	for _, u in ipairs(lineOf(rec.slot, rec.faction)) do
		if #taken >= WarCommand.MAX_SQUAD then
			break
		end
		if not WarCommand.isCommanded(u.oid) then
			local okf, errf = pcall(function()
				local a = AiAgent(u.p)
				a:storeFollowObject()
				a:setFollowObject(pPlayer)
				a:executeBehavior()
			end)
			if okf then
				writeData(troopKey(u.oid), commanderOid)
				taken[#taken + 1] = u.oid
			else
				printf("WarCommand: could not take " .. tostring(u.oid) .. ": " .. tostring(errf) .. "\n")
			end
		else
			printf("WarCommand: " .. tostring(u.oid) .. " is already commanded by " .. tostring(readData(troopKey(u.oid))) .. "\n")
		end
	end
	if #taken == 0 then
		return 0, "no troops"
	end
	writeSquad(commanderOid, rec.slot, rec.faction, taken)
	addCommander(commanderOid)
	say(pSgt, "command_taken", rec.faction, nameOf(pPlayer))
	tell(pPlayer, string.format("You take command of %d troops at %s. Right-click any of them for orders.", #taken, tostring(rec.region)))
	printf(string.format("WarCommand: %s took command of %d %s troop(s) at %s\n",
		nameOf(pPlayer), #taken, tostring(rec.faction), rec.slot))
	return #taken, nil
end

--- Give an order to the commander's squad: "attack", "hold", "fallback".
-- Returns bodies ordered, or 0 and a reason.
function WarCommand.order(pPlayer, kind)
	if pPlayer == nil then
		return 0, "nobody"
	end
	local commanderOid = SceneObject(pPlayer):getObjectID()
	local squad = WarCommand.squadOf(commanderOid)
	if squad == nil then
		return 0, "no squad"
	end
	local troops = liveTroops(commanderOid, squad)
	if #troops == 0 then
		WarCommand.release(commanderOid, nil)
		return 0, "no troops"
	end
	local sgt = nil
	pcall(function()
		local oid = readData("warbattle:sgt:" .. squad.slot .. ":" .. squad.faction)
		if oid ~= nil and oid > 0 then sgt = getSceneObject(oid) end
	end)
	local voice = sgt or troops[1].p

	if kind == "attack" then
		local targetId = 0
		pcall(function() targetId = CreatureObject(pPlayer):getTargetID() end)
		local pTarget = (targetId ~= nil and targetId > 0) and getSceneObject(targetId) or nil
		if pTarget == nil or not SceneObject(pTarget):isCreatureObject() then
			return 0, "no target"
		end
		local okd, dead = pcall(function() return CreatureObject(pTarget):isDead() end)
		if okd and dead then
			return 0, "target is dead"
		end
		local targetFaction = factionName(CreatureObject(pTarget):getFaction())
		if targetFaction == squad.faction then
			return 0, "that is one of ours"
		end
		if targetFaction == nil then
			return 0, "not the enemy"
		end
		for _, u in ipairs(troops) do
			WarBattle.engage(u.p, pTarget, true)
		end
		say(voice, "order_attack", squad.faction, nil)
		return #troops, nil
	end

	if kind == "hold" then
		for _, u in ipairs(troops) do
			pcall(function()
				local so, a = SceneObject(u.p), AiAgent(u.p)
				a:setHomeLocation(so:getWorldPositionX(), so:getWorldPositionZ(), so:getWorldPositionY(), nil)
				a:setFollowObject(nil)
				a:executeBehavior()
			end)
		end
		say(voice, "order_hold", squad.faction, nil)
		return #troops, nil
	end

	if kind == "fallback" then
		for _, u in ipairs(troops) do
			pcall(function()
				local a = AiAgent(u.p)
				a:removeDefenders()
				a:setFollowObject(pPlayer)
				a:executeBehavior()
			end)
		end
		say(voice, "order_fallback", squad.faction, nil)
		return #troops, nil
	end

	return 0, "unknown order"
end

--- Every live enemy body at a slot (walkers included: they shoot back).
local function enemiesAt(slotKey, faction)
	local out = {}
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return out
	end
	for rec in string.gmatch(raw, "([^;]+)") do
		local f = {}
		for field in string.gmatch(rec .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		local oid = tonumber(f[1])
		if oid ~= nil and f[2] ~= nil and f[3] ~= nil and (f[2] .. ":" .. f[3]) == slotKey and f[4] ~= faction then
			local p = getSceneObject(oid)
			if p ~= nil then
				local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
				if not (okd and dead) then
					out[#out + 1] = p
				end
			end
		end
	end
	return out
end

--- Hand the squad back to the war. `why` = "dismissed" (the player's
-- choice), "released" (the commander died, left or dropped overt), or nil
-- (nothing left to say). Each troop goes back on the enemy at its site
-- (WarBattle.engage -- verifier, 2026-09-05: "Fall back" strips a body's
-- targets, and a body handed back with none stood frozen for good, since
-- the stuck rule saw wounded survivors and never fired); attackers advance,
-- the holder's line stands.
function WarCommand.release(commanderOid, why)
	local squad = WarCommand.squadOf(commanderOid)
	if squad == nil then
		dropCommander(commanderOid)
		return 0
	end
	local region = string.match(squad.slot, "^([%w_]+):")
	local st = (WarReport ~= nil) and WarReport.state() or nil
	local holder = (st ~= nil and region ~= nil and st.regions[region] ~= nil) and st.regions[region].faction or nil
	local advance = true
	if holder ~= nil then
		advance = (holder ~= squad.faction)
	end
	local enemies = enemiesAt(squad.slot, squad.faction)
	local n = 0
	local voice = nil
	for i, oid in ipairs(squad.troops) do
		writeData(troopKey(oid), 0)
		local p = getSceneObject(oid)
		if p ~= nil then
			pcall(function() AiAgent(p):restoreFollowObject() end)
			if #enemies > 0 then
				WarBattle.engage(p, enemies[((i - 1) % #enemies) + 1], advance)
			else
				pcall(function() AiAgent(p):executeBehavior() end)
			end
			n = n + 1
			voice = voice or p
		end
	end
	pcall(function()
		local oid = readData("warbattle:sgt:" .. squad.slot .. ":" .. squad.faction)
		if oid ~= nil and oid > 0 then
			local s = getSceneObject(oid)
			if s ~= nil then voice = s end
		end
	end)
	pcall(function() deleteStringData(key(commanderOid)) end)
	dropCommander(commanderOid)
	if why ~= nil then
		say(voice, why, squad.faction, nil)
	end
	printf(string.format("WarCommand: squad of %s at %s released (%s), %d troop(s) back to the war\n",
		tostring(commanderOid), squad.slot, tostring(why), n))
	return n
end

--- One pass over every commander, from the tend pass: a dead, gone,
-- off-planet or no-longer-overt commander loses the squad; a squad with
-- nobody left is cleared.
function WarCommand.tickOnce()
	for _, commanderOid in ipairs(commanders()) do
		local squad = WarCommand.squadOf(commanderOid)
		if squad == nil then
			dropCommander(commanderOid)
		else
			local p = getSceneObject(commanderOid)
			local valid = p ~= nil
			if valid then
				local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
				if okd and dead then valid = false end
			end
			if valid and SceneObject(p):isPlayerCreature() then
				local oko, overt = pcall(function() return CreatureObject(p):isOvert() end)
				if oko and not overt then valid = false end
			end
			if valid then
				local troops = liveTroops(commanderOid, squad)
				if #troops == 0 then
					WarCommand.release(commanderOid, nil)
				else
					local zone = SceneObject(p):getZoneName()
					local okz, tz = pcall(function() return SceneObject(troops[1].p):getZoneName() end)
					if okz and tz ~= nil and tz ~= zone then
						valid = false
					end
				end
			end
			if not valid then
				WarCommand.release(commanderOid, "released")
			end
		end
	end
end

-- ------------------------------------------------------------- radial --

WarCommandMenuComponent = {}

function WarCommandMenuComponent:fillObjectMenuResponse(pNpc, pMenuResponse, pPlayer)
	if pNpc == nil or pPlayer == nil then
		return
	end
	local ok, err = pcall(function()
		local oid = SceneObject(pNpc):getObjectID()
		local rec = recordOf(oid)
		if rec == nil or rec.faction == nil then
			return
		end
		local allowed = qualifies(pPlayer, rec.faction)
		if not allowed then
			return
		end
		local menu = LuaObjectMenuResponse(pMenuResponse)
		local squad = WarCommand.squadOf(SceneObject(pPlayer):getObjectID())
		if squad ~= nil and squad.slot == rec.slot and squad.faction == rec.faction then
			menu:addRadialMenuItem(WarCommand.RADIAL.ATTACK, 3, "Attack my target")
			menu:addRadialMenuItem(WarCommand.RADIAL.HOLD, 3, "Hold here")
			menu:addRadialMenuItem(WarCommand.RADIAL.FALLBACK, 3, "Fall back to me")
			menu:addRadialMenuItem(WarCommand.RADIAL.DISMISS, 3, "Dismiss squad")
		elseif isSergeant(oid, rec) then
			menu:addRadialMenuItem(WarCommand.RADIAL.TAKE, 3, "Take command")
		end
	end)
	if not ok then
		printf("WarCommandMenuComponent:fillObjectMenuResponse failed: " .. tostring(err) .. "\n")
	end
end

function WarCommandMenuComponent:handleObjectMenuSelect(pNpc, pPlayer, selectedID)
	if pNpc == nil or pPlayer == nil then
		return 0
	end
	local ok, err = pcall(function()
		local R = WarCommand.RADIAL
		if selectedID == R.TAKE then
			local n, why = WarCommand.take(pPlayer, pNpc)
			if n == 0 then
				tell(pPlayer, "You cannot take command: " .. tostring(why) .. ".")
			end
		elseif selectedID == R.ATTACK or selectedID == R.HOLD or selectedID == R.FALLBACK then
			local kind = (selectedID == R.ATTACK) and "attack" or ((selectedID == R.HOLD) and "hold" or "fallback")
			local n, why = WarCommand.order(pPlayer, kind)
			if n == 0 then
				tell(pPlayer, "No order given: " .. tostring(why) .. ".")
			else
				tell(pPlayer, string.format("%d troops: %s.", n,
					(kind == "attack") and "attack your target" or ((kind == "hold") and "hold here" or "fall back to you")))
			end
		elseif selectedID == R.DISMISS then
			local n = WarCommand.release(SceneObject(pPlayer):getObjectID(), "dismissed")
			tell(pPlayer, string.format("Squad dismissed (%d troops back to the line).", n))
		end
	end)
	if not ok then
		printf("WarCommandMenuComponent:handleObjectMenuSelect failed: " .. tostring(err) .. "\n")
	end
	return 0
end

-- -------------------------------------------------------------- probe --

--- test warCommandCheck: a stock stormtrooper stands in for the player.
function Tests:warCommandCheck()
	printf("WARCOMMAND: begin\n")
	local ok, err = pcall(function()
		local slots = WarBattle.liveSlots()
		local keys = {}
		for k, _ in pairs(slots) do keys[#keys + 1] = k end
		table.sort(keys)
		local pSgt, slotKey, faction = nil, nil, nil
		for _, k in ipairs(keys) do
			local sl = slots[k]
			if sl.site ~= "0" and string.sub(tostring(sl.site), 1, 1) ~= "c" then
				for _, fac in ipairs({ "imperial", "rebel" }) do
					local oid = readData("warbattle:sgt:" .. k .. ":" .. fac)
					if pSgt == nil and oid ~= nil and oid > 0 then
						local p = getSceneObject(oid)
						if p ~= nil then
							local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
							if not (okd and dead) then pSgt, slotKey, faction = p, k, fac end
						end
					end
				end
			end
		end
		if pSgt == nil then
			printf("WARCOMMAND: no live sergeant at any site\n")
			return
		end
		-- Read everything off the sergeant BEFORE wrapping anything else:
		-- SceneObject(p) is a per-class singleton wrapper, so a wrapper kept
		-- across another SceneObject(...) call silently points at the new
		-- object (measured 2026-09-05 -- this probe once reported the
		-- commander's own OID as the sergeant's).
		local so = SceneObject(pSgt)
		local zone, x, y = so:getZoneName(), so:getWorldPositionX(), so:getWorldPositionY()
		local sgtOid = so:getObjectID()
		local tpl = (faction == "imperial") and "stormtrooper" or "rebel_trooper"
		local pCmdr = spawnMobile(zone, tpl, 0, x + 6, WarBattle.floorAt(zone, x + 6, y + 6), y + 6, 0, 0)
		if pCmdr == nil then
			printf("WARCOMMAND: stand-in commander did not spawn\n")
			return
		end
		WarCommand.ALLOW_NPC_COMMANDER = true
		local n, why = WarCommand.take(pCmdr, pSgt)
		printf(string.format("WARCOMMAND: take at %s (%s): %d troop(s) %s\n", slotKey, faction, n, tostring(why)))
		local cmdrOid = SceneObject(pCmdr):getObjectID()
		local squad = WarCommand.squadOf(cmdrOid)
		local following = 0
		if squad ~= nil then
			for _, oid in ipairs(squad.troops) do
				local p = getSceneObject(oid)
				if p ~= nil then
					local okf, f = pcall(function() return AiAgent(p):getFollowObject() end)
					if okf and f ~= nil and SceneObject(f):getObjectID() == cmdrOid then following = following + 1 end
				end
			end
		end
		local sgtIn = false
		if squad ~= nil then
			for _, oid in ipairs(squad.troops) do
				if oid == sgtOid then sgtIn = true end
			end
		end
		local rec = recordOf(sgtOid)
		printf(string.format("WARCOMMAND: record troops=%d following the commander=%d sgt=%s in-squad=%s commanded(sgt)=%s troopkey=%s rec=%s/%s/%s\n",
			squad and #squad.troops or 0, following, tostring(sgtOid), tostring(sgtIn),
			tostring(WarCommand.isCommanded(sgtOid)), tostring(readData(troopKey(sgtOid))),
			rec and rec.slot or "?", rec and rec.faction or "?", rec and tostring(rec.kind) or "?"))
		for _, kind in ipairs({ "hold", "fallback", "attack" }) do
			local m, w = WarCommand.order(pCmdr, kind)
			printf(string.format("WARCOMMAND: order %s: %d %s\n", kind, m, tostring(w)))
		end
		local r = WarCommand.release(cmdrOid, "dismissed")
		printf(string.format("WARCOMMAND: dismissed: %d back; commanded(sgt) now=%s; record=%s\n",
			r, tostring(WarCommand.isCommanded(sgtOid)), tostring(WarCommand.squadOf(cmdrOid) ~= nil)))
		WarCommand.ALLOW_NPC_COMMANDER = false
		pcall(function() SceneObject(pCmdr):destroyObjectFromWorld(false) end)
	end)
	WarCommand.ALLOW_NPC_COMMANDER = false
	if not ok then
		printf("WARCOMMAND: failed: " .. tostring(err) .. "\n")
	end
	printf("WARCOMMAND: end\n")
end

--- test warSquadAbilityCheck (B34 D2): do the Squad Leader abilities reach
-- a commanded line at every point of the order cycle? Asks the two C++
-- probe hooks the six commands themselves go through --
-- CreatureObject:isSquadAbilityTarget(pLeader) is the per-member gate and
-- CreatureObject:countSquadAbilityTargets() the collected list -- so the
-- answer is the commands' own without a client pressing a button. A stock
-- trooper stands in for the player; the gate counts a player leader but
-- not an NPC stand-in, so the expected count is the live squad, not +1.
-- "attack" is set the way the order sets it (WarBattle.engage on an enemy
-- body, following) because the stand-in has no client target.
function Tests:warSquadAbilityCheck()
	printf("WARSQUADABILITY: begin\n")
	local pCmdr = nil
	local ok, err = pcall(function()
		local slots = WarBattle.liveSlots()
		local keys = {}
		for k, _ in pairs(slots) do keys[#keys + 1] = k end
		table.sort(keys)
		local pSgt, slotKey, faction = nil, nil, nil
		for _, k in ipairs(keys) do
			local sl = slots[k]
			if sl.site ~= "0" and string.sub(tostring(sl.site), 1, 1) ~= "c" then
				for _, fac in ipairs({ "imperial", "rebel" }) do
					local oid = readData("warbattle:sgt:" .. k .. ":" .. fac)
					if pSgt == nil and oid ~= nil and oid > 0 then
						local p = getSceneObject(oid)
						if p ~= nil then
							local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
							if not (okd and dead) then pSgt, slotKey, faction = p, k, fac end
						end
					end
				end
			end
		end
		if pSgt == nil then
			printf("WARSQUADABILITY: no live sergeant at any site\n")
			return
		end
		-- Read the sergeant's values before wrapping anything else (the
		-- SceneObject wrapper is a per-class singleton).
		local so = SceneObject(pSgt)
		local zone, x, y = so:getZoneName(), so:getWorldPositionX(), so:getWorldPositionY()
		local tpl = (faction == "imperial") and "stormtrooper" or "rebel_trooper"
		pCmdr = spawnMobile(zone, tpl, 0, x + 6, WarBattle.floorAt(zone, x + 6, y + 6), y + 6, 0, 0)
		if pCmdr == nil then
			printf("WARSQUADABILITY: stand-in commander did not spawn\n")
			return
		end
		WarCommand.ALLOW_NPC_COMMANDER = true
		local n, why = WarCommand.take(pCmdr, pSgt)
		printf(string.format("WARSQUADABILITY: take at %s (%s): %d troop(s) %s\n", slotKey, faction, n, tostring(why)))
		if n == 0 then
			return
		end
		local cmdrOid = SceneObject(pCmdr):getObjectID()
		local squad = WarCommand.squadOf(cmdrOid)
		if squad == nil then
			printf("WARSQUADABILITY: no record after take\n")
			return
		end
		local troops = squad.troops
		local fails = 0
		local function measure(stage, expectAll)
			local live, reached = 0, 0
			for _, oid in ipairs(troops) do
				local p = getSceneObject(oid)
				if p ~= nil then
					local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
					if not (okd and dead) then
						live = live + 1
						local okr, r = pcall(function() return CreatureObject(p):isSquadAbilityTarget(pCmdr) end)
						if okr and r then reached = reached + 1 end
					end
				end
			end
			local okc, count = pcall(function() return CreatureObject(pCmdr):countSquadAbilityTargets() end)
			if not okc then
				printf("WARSQUADABILITY: countSquadAbilityTargets: " .. tostring(count) .. "\n")
				count = -1
			end
			local pass
			if expectAll then
				pass = live > 0 and reached == live and count == live
			else
				pass = reached == 0 and count == 0
			end
			if not pass then fails = fails + 1 end
			printf(string.format("WARSQUADABILITY: %-30s live=%d reached=%d collected=%d %s\n",
				stage, live, reached, count, pass and "OK" or "FAIL"))
		end
		measure("taken (following)", true)
		for _, kind in ipairs({ "hold", "fallback" }) do
			local m, w = WarCommand.order(pCmdr, kind)
			printf(string.format("WARSQUADABILITY: order %s: %d %s\n", kind, m, tostring(w)))
			measure(kind == "hold" and "hold (no follow)" or "fallback (following)", true)
		end
		local enemies = enemiesAt(squad.slot, squad.faction)
		if #enemies > 0 then
			for i, oid in ipairs(troops) do
				local p = getSceneObject(oid)
				if p ~= nil then WarBattle.engage(p, enemies[((i - 1) % #enemies) + 1], true) end
			end
			measure("attack (following the enemy)", true)
			local okn, neg = pcall(function() return CreatureObject(enemies[1]):isSquadAbilityTarget(pCmdr) end)
			local pass = okn and not neg
			if not pass then fails = fails + 1 end
			printf(string.format("WARSQUADABILITY: %-30s reached=%s %s\n", "enemy body", tostring(okn and neg), pass and "OK" or "FAIL"))
		else
			printf("WARSQUADABILITY: attack: no enemy line at the site, skipped\n")
		end
		WarCommand.release(cmdrOid, "dismissed")
		measure("dismissed", false)
		printf(string.format("WARSQUADABILITY: %d fail(s)\n", fails))
	end)
	WarCommand.ALLOW_NPC_COMMANDER = false
	if pCmdr ~= nil then
		pcall(function() SceneObject(pCmdr):destroyObjectFromWorld(false) end)
	end
	if not ok then
		printf("WARSQUADABILITY: failed: " .. tostring(err) .. "\n")
	end
	printf("WARSQUADABILITY: end\n")
end
