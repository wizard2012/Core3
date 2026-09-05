--[[
  custom_scripts/screenplays/warreport/war_courier.lua

  Courier runs across supply lanes (owner ruling, 2026-09-04, strategic
  locations thread): the multi-planet supply booster.

  WHAT A RUN IS. A quartermaster stands at each major starport (Coronet,
  Theed, Mos Eisley) and at the Rebel capital, Anchorhead. Its faction follows
  whoever holds that town, exactly as the briefing officer's does. Use the
  radial on it, pick a destination -- a friendly town whose supply is cut or
  thin, or one on another planet -- and you are handed a crate bound there.
  Walk into that town with the crate and the delivery is made: the crate is
  consumed and materiel_delivery is recorded for that region. No hand-in NPC,
  no menu at the far end. Arriving IS the delivery.

  WHY THIS FEEDS THE SIM WITH NO SIM CHANGE. warsim/sim/channels.lua already
  lists materiel_delivery in M.MATERIEL and folds it into that region's
  supply_stock, capped by materiel_contrib_cap_region / _faction. The only
  things in the way were two allowlists (war_contrib.lua's VALID_SOURCES, now
  amended, and bridge/flush_contributions.lua's, which already had it). Point
  value is DESIGN-VICTORY 274's 5.00 -- explicitly provisional. NOTE the
  faction cap is 3.0 per tick, so one delivery already saturates a faction's
  materiel for that window; that is the sim's tuned pacing, not a bug here.

  WHY A RADIAL AND NOT A CONVERSATION. war_officer.lua's header records why a
  ConvoTemplate was rejected here (option labels resolve through client string
  tables); war_officer_report.lua then proved a radial via
  setObjectMenuComponent works with plain labels. This copies that exactly.

  WHY THE CRATE IS AN EXISTING TEMPLATE. Object templates load once at boot
  (CLAUDE.md: object/ is a restart-bucket change). Reusing
  fs_reflex_supply_crate keeps this whole feature in the reload bucket. The
  crate carries no special flags of its own; everything that makes it a
  courier crate is screenplay data keyed on its OID:
    <oid>:war:courier:owner    who it was issued to (string OID)
    <oid>:war:courier:dest     region it is bound for
    <oid>:war:courier:origin   region it was issued at
    <oid>:war:courier:issued   ms timestamp
  and per player:
    <playerOid>:war:courier:active   OID of the crate they currently carry

  ANTI-FARM, all in Lua because there is no setNoTrade binding:
    - one crate per player at a time (active key);
    - delivery only by the OWNER, so crates cannot be passed to alts;
    - the crate cannot be donated as ordinary materiel (war_donate.lua's
      isEligible refuses anything with an owner key) -- otherwise one crate
      could pay twice, or pay once for zero travel;
    - crates spoil after EXPIRY_MS, so a stockpile cannot be held for a
      moment the cap is empty;
    - a destination must be a DIFFERENT town, and either off-planet or
      under-supplied, so the run is always a run.

  LIFECYCLE. ensure() spawns or re-skins each post's NPC to the current
  holder and is idempotent. It runs at include time (so a reload activates
  it without a restart) and every RESCAN_MS from start() at boot. A flipped
  starport therefore swaps its quartermaster within one rescan or one
  war-advance reload, whichever comes first.
]]

WarCourier = ScreenPlay:new {
	screenplayName = "WarCourier",
}

registerScreenPlay("WarCourier", true)

WarCourier.CRATE_TEMPLATE  = "object/tangible/item/quest/force_sensitive/fs_reflex_supply_crate.iff"
WarCourier.SOURCE          = "materiel_delivery"
WarCourier.POINTS          = 5.0
WarCourier.EXPIRY_MS       = 45 * 60 * 1000
WarCourier.MAX_DESTINATIONS = 5
WarCourier.RESCAN_MS       = 5 * 60 * 1000

-- NEVER SPAWN AT INCLUDE TIME. The first version of this file called
-- ensure() directly when included. spawnMobile() re-enters the screenplay
-- loader, which -- mid-include, with the version freshly bumped -- re-runs
-- screenplays.lua, which includes this file again, which spawns again. Lua
-- ran out of C stack ("too many C levels (limit is 200)") 281 spawns deep,
-- and the SAME failure aborted the include of unrelated modules on those
-- threads (war_hook, war_contrib_hook, war_heal, ServerEventAutomation...),
-- leaving the server running with partially loaded war Lua until a restart.
-- Measured 2026-09-04. Include time may only SCHEDULE; the event thread does
-- the work. Same rule war_officer.lua and war_officer_report.lua already
-- follow.
--
-- The scheduling itself is gated in shared memory, because every thread
-- re-runs the include chain after a reload and would otherwise queue one
-- kick each.
WarCourier.KICK_GATE_KEY  = "warcourier:kick_gate_ms"
WarCourier.KICK_MIN_GAP_MS = 60 * 1000

-- A stored OID that does not resolve is NOT proof the NPC is gone -- it may
-- be unresolvable on this thread. Only after this many consecutive misses is
-- the post treated as empty.
WarCourier.MISSES_BEFORE_RESPAWN = 2

-- Same idea for the reap list: an OID that fails to resolve on this many
-- consecutive reaps is forgotten (with its per-NPC keys), so an NPC that is
-- really gone does not sit in SPAWNED_KEY for the life of the process.
WarCourier.REAP_MISSES_BEFORE_FORGET = 3

-- Every OID this module has ever spawned, so a respawn reaps predecessors
-- even if the per-post pointer was overwritten.
WarCourier.SPAWNED_KEY = "warcourier:spawned"

-- Radial ids. The officer's Report uses 20; keep clear of it.
WarCourier.RADIAL_ROOT = 30

WarCourier.TEMPLATE = {
	imperial = "imperial_master_sergeant",
	rebel    = "rebel_engineer",
}

-- Six metres off the officer posts (war_officer.lua POSTS) so the two NPCs
-- do not stand in each other; Mos Eisley has no officer, so it sits six off
-- the town coordinate WarReport.COORDS uses.
WarCourier.POSTS = {
	{ region = "cor_coronet",    zone = "corellia", x = -172,  y = -4498, heading = 0 },
	{ region = "nab_theed",      zone = "naboo",    x = -6154, y = 3926,  heading = 0 },
	{ region = "tat_mos_eisley", zone = "tatooine", x = 3466,  y = -4762, heading = 0 },
	{ region = "tat_anchorhead", zone = "tatooine", x = 108,   y = -5354, heading = 0 },
}

local function factionOfRegion(regionId)
	if WarReport == nil or WarReport.state == nil then
		return nil
	end
	local st = WarReport.state()
	if st == nil or st.regions == nil then
		return nil
	end
	local r = st.regions[regionId]
	if r == nil or r.faction == nil then
		return nil
	end
	local f = string.lower(tostring(r.faction))
	if f ~= "imperial" and f ~= "rebel" then
		return nil
	end
	return f
end

local function factionOfPlayer(pPlayer)
	local f = CreatureObject(pPlayer):getFaction()
	if f == FACTIONREBEL then
		return "rebel"
	elseif f == FACTIONIMPERIAL then
		return "imperial"
	end
	return nil
end

local function regionName(regionId)
	if WarReport ~= nil and WarReport.regionName ~= nil then
		return WarReport.regionName(regionId)
	end
	return tostring(regionId)
end

-- ================================================================ NPCs ==

--- Drop everything keyed on one spawned NPC's OID.
local function forgetSpawned(token)
	pcall(function() deleteStringData("warcourier:region:" .. token) end)
	pcall(function() deleteData("warcourier:reapmiss:" .. token) end)
end

--- Reap every OID this module ever spawned that still resolves, except those
-- in `keep` (a set of OID strings).
local function reapSpawned(keep)
	local raw = readStringData(WarCourier.SPAWNED_KEY)
	if raw == nil or raw == "" then
		return 0
	end
	local reaped, survivors = 0, {}
	for token in string.gmatch(raw, "([^,]+)") do
		if keep[token] then
			survivors[#survivors + 1] = token
		else
			local p = getSceneObject(tonumber(token))
			if p ~= nil then
				pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
				forgetSpawned(token)
				reaped = reaped + 1
			else
				-- Unresolvable HERE is usually a cross-thread miss, so the
				-- record is kept -- but not forever (REAP_MISSES_BEFORE_FORGET).
				local missKey = "warcourier:reapmiss:" .. token
				local misses = (readData(missKey) or 0) + 1
				if misses >= WarCourier.REAP_MISSES_BEFORE_FORGET then
					forgetSpawned(token)
				else
					writeData(missKey, misses)
					survivors[#survivors + 1] = token
				end
			end
		end
	end
	writeStringData(WarCourier.SPAWNED_KEY, table.concat(survivors, ","))
	return reaped
end

local function rememberSpawned(oid)
	local raw = readStringData(WarCourier.SPAWNED_KEY)
	if raw == nil or raw == "" then
		writeStringData(WarCourier.SPAWNED_KEY, tostring(oid))
	else
		writeStringData(WarCourier.SPAWNED_KEY, raw .. "," .. tostring(oid))
	end
end

--- Spawn or re-skin every post's quartermaster to the current holder. Runs
-- ONLY on the event thread (kick / rescan / probe) -- see the note above.
function WarCourier:ensure()
	local spawned, kept, skipped = 0, 0, 0

	for i = 1, #self.POSTS do
		local post = self.POSTS[i]
		local ok, err = pcall(function()
			local faction = factionOfRegion(post.region)
			if faction == nil then
				skipped = skipped + 1
				return
			end

			local oidKey  = "warcourier:npc:" .. post.region
			local facKey  = "warcourier:npcfaction:" .. post.region
			local missKey = "warcourier:miss:" .. post.region
			local oid = tonumber(readStringData(oidKey))
			local pOld = (oid ~= nil) and getSceneObject(oid) or nil
			local sameFaction = (readStringData(facKey) == faction)

			if pOld ~= nil and sameFaction then
				writeData(missKey, 0)
				kept = kept + 1
				return
			end

			if pOld == nil and oid ~= nil and sameFaction then
				local misses = (readData(missKey) or 0) + 1
				writeData(missKey, misses)
				if misses < WarCourier.MISSES_BEFORE_RESPAWN then
					kept = kept + 1
					return
				end
			end
			writeData(missKey, 0)

			-- Reap everything this module ever spawned except the other
			-- posts' current NPCs, so no post can accumulate duplicates.
			local keep = {}
			for j = 1, #self.POSTS do
				if self.POSTS[j].region ~= post.region then
					local k = readStringData("warcourier:npc:" .. self.POSTS[j].region)
					if k ~= nil and k ~= "" then keep[k] = true end
				end
			end
			reapSpawned(keep)

			local template = self.TEMPLATE[faction]
			local pNpc = spawnMobile(post.zone, template, -1, post.x, 0, post.y, post.heading, 0)
			if pNpc == nil then
				printf("WarCourier: spawnMobile returned nil for " .. tostring(template) .. " at " .. post.region .. "\n")
				return
			end

			SceneObject(pNpc):setObjectMenuComponent("WarCourierMenuComponent")
			pcall(function()
				SceneObject(pNpc):setCustomObjectName(
					((faction == "rebel") and "Alliance" or "Imperial") .. " Quartermaster")
			end)
			-- The NPC does not need to know its own region at menu time; the
			-- menu looks it up by the NPC's OID.
			writeStringData(oidKey, tostring(SceneObject(pNpc):getObjectID()))
			writeStringData(facKey, faction)
			rememberSpawned(SceneObject(pNpc):getObjectID())
			writeStringData("warcourier:region:" .. tostring(SceneObject(pNpc):getObjectID()), post.region)
			spawned = spawned + 1
		end)
		if not ok then
			printf("WarCourier: ensure failed at " .. tostring(post.region) .. ": " .. tostring(err) .. "\n")
		end
	end

	printf("WarCourier: ensure -- spawned " .. spawned .. ", kept " .. kept .. ", skipped " .. skipped .. "\n")
end

function WarCourier:rescan()
	pcall(function() WarCourier:ensure() end)
	createEvent(WarCourier.RESCAN_MS, "WarCourier", "rescan", nil, "")
end

--- One-shot ensure on the event thread. Does NOT reschedule: the periodic
-- chain belongs to start() alone, so reloads can never stack timers.
function WarCourier:kick()
	pcall(function() WarCourier:ensure() end)
end

function WarCourier:start()
	createEvent(5000, "WarCourier", "rescan", nil, "")
end

-- ========================================================= destinations ==

--- Friendly towns a courier from `originRegion` could usefully carry to:
-- under-supplied first, then anything off-planet. Only towns with in-game
-- coordinates -- a crate for Lianorm Swamp could never be delivered.
function WarCourier.destinations(originRegion, faction)
	local out = {}
	if WarReport == nil or WarReport.state == nil or WarReport.regionIds == nil then
		return out
	end
	local st = WarReport.state()
	if st == nil or st.regions == nil then
		return out
	end

	local originPlanet = WarReport.PLANET_OF[originRegion]
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		local id = ids[i]
		local r = st.regions[id]
		if id ~= originRegion and r ~= nil and WarReport.COORDS[id] ~= nil
				and string.lower(tostring(r.faction or "")) == faction then
			local status = tostring(r.supply_status or "connected")
			local priority = nil
			if status == "cut" then
				priority = 0
			elseif status == "degraded" then
				priority = 1
			elseif WarReport.PLANET_OF[id] ~= originPlanet then
				priority = 2
			end
			if priority ~= nil then
				out[#out + 1] = { id = id, name = regionName(id), status = status, priority = priority }
			end
		end
	end

	table.sort(out, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.name < b.name
	end)

	while #out > WarCourier.MAX_DESTINATIONS do
		table.remove(out)
	end
	return out
end

local function labelFor(d)
	if d.status == "cut" then
		return d.name .. " -- supply cut"
	elseif d.status == "degraded" then
		return d.name .. " -- supply thin"
	end
	return d.name
end

-- ================================================================ issue ==

function WarCourier.issue(pPlayer, pNpc, dest)
	local playerOid = SceneObject(pPlayer):getObjectID()
	local faction = factionOfPlayer(pPlayer)
	local creature = CreatureObject(pPlayer)

	-- One at a time. If the recorded crate no longer exists (delivered,
	-- destroyed, spoiled) the slot is free.
	local activeOid = tonumber(readStringData(tostring(playerOid) .. ":war:courier:active"))
	if activeOid ~= nil and getSceneObject(activeOid) ~= nil then
		local carrying = readStringData(tostring(activeOid) .. ":war:courier:dest")
		creature:sendSystemMessage(WarVoice.courierAlready(regionName(carrying)))
		return
	end

	local pInventory = creature:getSlottedObject("inventory")
	if pInventory == nil then
		return
	end

	local pItem = giveItem(pInventory, WarCourier.CRATE_TEMPLATE, -1)
	if pItem == nil then
		creature:sendSystemMessage("Your inventory is full. Make room and ask again.")
		return
	end

	local oid = SceneObject(pItem):getObjectID()
	local originRegion = readStringData("warcourier:region:" .. tostring(SceneObject(pNpc):getObjectID())) or ""

	pcall(function() SceneObject(pItem):setCustomObjectName("Supply crate: " .. dest.name) end)
	writeStringData(tostring(oid) .. ":war:courier:owner", tostring(playerOid))
	writeStringData(tostring(oid) .. ":war:courier:dest", dest.id)
	writeStringData(tostring(oid) .. ":war:courier:origin", originRegion)
	writeData(tostring(oid) .. ":war:courier:issued", getTimestampMilli())
	writeStringData(tostring(playerOid) .. ":war:courier:active", tostring(oid))

	creature:sendSystemMessage(WarVoice.courierIssued(dest.name, faction))
	printf("WarCourier: issued crate " .. tostring(oid) .. " to " .. tostring(playerOid)
		.. " for " .. dest.id .. " from " .. originRegion .. "\n")
end

local function clearCrate(oid, playerOid)
	pcall(function() deleteStringData(tostring(oid) .. ":war:courier:owner") end)
	pcall(function() deleteStringData(tostring(oid) .. ":war:courier:dest") end)
	pcall(function() deleteStringData(tostring(oid) .. ":war:courier:origin") end)
	pcall(function() writeData(tostring(oid) .. ":war:courier:issued", 0) end)
	if playerOid ~= nil then
		pcall(function() deleteStringData(tostring(playerOid) .. ":war:courier:active") end)
	end
end

-- ============================================================== deliver ==

--- Called by WarPresence on entering a town's area. Consumes any crate in
-- the player's inventory bound for THIS region that they own.
function WarCourier.tryDeliver(pPlayer, regionId)
	if pPlayer == nil or regionId == nil then
		return
	end
	local creature = CreatureObject(pPlayer)
	local playerOid = tostring(SceneObject(pPlayer):getObjectID())

	-- One key read before up to eighty: a player with nothing in hand is the
	-- common case, and this fires on every war-town arrival. issue() sets the
	-- key and clearCrate() removes it, so "absent" means "no crate to find".
	local active = readStringData(playerOid .. ":war:courier:active")
	if active == nil or active == "" then
		return
	end

	local pInventory = creature:getSlottedObject("inventory")
	if pInventory == nil then
		return
	end
	local pInv = SceneObject(pInventory)

	-- Collect first, act second: destroying while iterating a container is
	-- how you skip the item after the one you destroyed.
	local found = {}
	for i = 0, pInv:getContainerObjectsSize() - 1, 1 do
		local pItem = pInv:getContainerObject(i)
		if pItem ~= nil then
			local oid = tostring(SceneObject(pItem):getObjectID())
			if readStringData(oid .. ":war:courier:dest") == regionId then
				found[#found + 1] = { pItem = pItem, oid = oid }
			end
		end
	end

	for _, c in ipairs(found) do
		local owner = readStringData(c.oid .. ":war:courier:owner")
		if owner ~= playerOid then
			creature:sendSystemMessage("That crate was issued to someone else. Command will not take it from you.")
		else
			local issued = readData(c.oid .. ":war:courier:issued") or 0
			local now = getTimestampMilli()
			if issued > 0 and (now - issued) > WarCourier.EXPIRY_MS then
				pcall(function() WarDonate:destroyItem(c.pItem) end)
				clearCrate(c.oid, playerOid)
				creature:sendSystemMessage(WarVoice.courierSpoiled(regionName(regionId)))
			else
				local faction = factionOfPlayer(pPlayer)
				local recorded, reason = false, "no_faction"
				if faction ~= nil then
					recorded, reason = WarContrib.record(faction, regionId, WarCourier.SOURCE,
						WarCourier.POINTS, SceneObject(pPlayer):getObjectID())
				end
				if recorded then
					-- Only now is the crate spent. A record that failed keeps
					-- the crate in hand so the run is not lost to a spool
					-- hiccup.
					pcall(function() WarDonate:destroyItem(c.pItem) end)
					clearCrate(c.oid, playerOid)
					creature:sendSystemMessage(WarVoice.courierDelivered(regionName(regionId), faction))
					printf("WarCourier: delivered crate " .. c.oid .. " at " .. regionId .. " by " .. playerOid .. "\n")
				else
					creature:sendSystemMessage("The quartermaster could not log your delivery. Keep the crate and try again shortly.")
					printf("WarCourier: record failed for crate " .. c.oid .. " at " .. regionId .. ": " .. tostring(reason) .. "\n")
				end
			end
		end
	end
end

-- =============================================================== radial ==

WarCourierMenuComponent = {}

function WarCourierMenuComponent:fillObjectMenuResponse(pSceneObject, pMenuResponse, pPlayer)
	if pSceneObject == nil or pPlayer == nil then
		return
	end
	local menuResponse = LuaObjectMenuResponse(pMenuResponse)
	menuResponse:addRadialMenuItem(WarCourier.RADIAL_ROOT, 3, "Requisition supply crate")

	local npcOid = tostring(SceneObject(pSceneObject):getObjectID())
	local region = readStringData("warcourier:region:" .. npcOid)
	local faction = readStringData("warcourier:npcfaction:" .. (region or ""))
	if region == nil or faction == nil then
		return
	end

	local dests = WarCourier.destinations(region, faction)
	for i = 1, #dests do
		-- Nested under the root item, with the SERVER callback (3):
		-- addRadialMenuItem's second argument is the callback, not a parent
		-- id, so the first version put five top-level entries with callback
		-- 30 on the wheel, and none of them ever reached handleObjectMenuSelect.
		menuResponse:addRadialMenuItemToRadialID(WarCourier.RADIAL_ROOT, WarCourier.RADIAL_ROOT + i, 3, labelFor(dests[i]))
	end
end

function WarCourierMenuComponent:handleObjectMenuSelect(pSceneObject, pPlayer, selectedID)
	if pSceneObject == nil or pPlayer == nil then
		return 0
	end
	local idx = tonumber(selectedID) - WarCourier.RADIAL_ROOT
	if idx == nil or idx < 0 or idx > WarCourier.MAX_DESTINATIONS then
		return 0
	end

	pcall(function()
		local creature = CreatureObject(pPlayer)
		local npcOid = tostring(SceneObject(pSceneObject):getObjectID())
		local region = readStringData("warcourier:region:" .. npcOid)
		local npcFaction = readStringData("warcourier:npcfaction:" .. (region or ""))
		local playerFaction = factionOfPlayer(pPlayer)

		if region == nil or npcFaction == nil or playerFaction ~= npcFaction then
			creature:sendSystemMessage("The quartermaster has nothing for you.")
			return
		end

		local dests = WarCourier.destinations(region, npcFaction)
		if #dests == 0 then
			creature:sendSystemMessage(WarVoice.courierNothing())
			return
		end
		if idx == 0 then
			-- Root selected with the submenu unopened: take the most urgent.
			idx = 1
		end
		if dests[idx] == nil then
			return
		end
		WarCourier.issue(pPlayer, pSceneObject, dests[idx])
	end)
	return 0
end

-- Activate on reload as well as boot -- but only by SCHEDULING a one-shot
-- kick on the event thread, never by spawning here (see the note by
-- KICK_GATE_KEY for what spawning at include time did). Gated so the first
-- thread through a reload schedules it and the rest skip.
pcall(function()
	local last = readSharedMemory(WarCourier.KICK_GATE_KEY) or 0
	local now = getTimestampMilli()
	if last == 0 or (now - last) >= WarCourier.KICK_MIN_GAP_MS then
		writeSharedMemory(WarCourier.KICK_GATE_KEY, now)
		createEvent(2000, "WarCourier", "kick", nil, "")
	end
end)

-- ================================================================ probe ==

function Tests:warCourierCheck()
	printf("WARCOURIER: begin\n")
	printf("WARCOURIER: bindings giveItem=" .. tostring(giveItem ~= nil)
		.. " LuaObjectMenuResponse=" .. tostring(LuaObjectMenuResponse ~= nil)
		.. " WarDonate.destroyItem=" .. tostring(WarDonate ~= nil and WarDonate.destroyItem ~= nil)
		.. " source_valid=" .. tostring(WarContrib ~= nil and WarContrib.VALID_SOURCES ~= nil
			and WarContrib.VALID_SOURCES[WarCourier.SOURCE] == true) .. "\n")

	for i = 1, #WarCourier.POSTS do
		local post = WarCourier.POSTS[i]
		local faction = factionOfRegion(post.region)
		local oid = tonumber(readStringData("warcourier:npc:" .. post.region))
		local alive = (oid ~= nil) and (getSceneObject(oid) ~= nil) or false
		local dests = faction and WarCourier.destinations(post.region, faction) or {}
		local names = {}
		for j = 1, #dests do names[j] = labelFor(dests[j]) end
		printf("WARCOURIER: post " .. post.region .. " holder=" .. tostring(faction)
			.. " npc_alive=" .. tostring(alive) .. " destinations=" .. #dests
			.. " [" .. table.concat(names, "; ") .. "]\n")
	end
	printf("WARCOURIER: end\n")
end
