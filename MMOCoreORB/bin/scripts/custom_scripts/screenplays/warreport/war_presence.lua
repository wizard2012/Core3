--[[
  custom_scripts/screenplays/warreport/war_presence.lua

  "The war does not feel real" -- owner, 2026-09-04, standing in Kaadara while
  three battle sites were staged 80-130m away.

  THE PROBLEM THIS SOLVES. Before this file the ONLY in-world thing that told
  a player where the fighting was, was war_recruiter.lua's markBattle(), and
  that fires exclusively from a recruiter CONVERSATION. So the war was
  discoverable only by players who already knew to go and ask. war_map.lua
  puts city pins on the planet map, but a pin on a city is not a pin on a
  battle, and neither says "there is a firefight 100m from you right now".

  WHAT THIS DOES. war_battle.lua calls attachRegion() once per region it
  actually stages. That spawns ONE large active area at the town centre --
  much larger than WarSquad's 48m formup radius, because this one has to catch
  a player wandering into town, not a player already standing in the fight.
  Entering it sends a system message naming the region and how many
  engagements are live, and drops a waypoint on the anchor site.

  WHY THE WAYPOINT GOES THROUGH WarBattle.anchorPoint(). Same reasoning
  war_recruiter.lua's markBattle() documents: that function is the single
  place the coords+offset arithmetic lives, including per-region
  SITE_OVERRIDES. Recomputing it here would let this waypoint and the actual
  fight drift apart the moment a region gets an override.

  AREA LIFETIME, AND THE LEAK THIS FILE DOES NOT REPEAT. WarSquad.attachSite()
  spawns one area per site every cycle and its return value is discarded by
  the caller, with nothing destroying it -- at a 4-minute cycle that is ~120
  orphaned areas an hour, each still carrying a live ENTEREDAREA observer, so
  a player standing on a long-dead site could still trip formup. This file
  registers every area it spawns in persistent string data (surviving
  reload-lua.sh, which wipes plain Lua tables) and clear() destroys them all
  at the top of each staging cycle. war_battle.lua now calls
  WarSquad.clearAreas() the same way for the same reason.
]]

WarPresence = ScreenPlay:new {
	screenplayName = "WarPresence",
}

-- Big on purpose. WarSquad.AREA_RADIUS_M is 48 because that is "inside the
-- battle"; this is "arriving in the town the battle is in". Most war towns
-- have a KILL_BOUNDS radius around 150, and sites sit out to 130, so 400
-- catches somebody on the road in without covering the next town over.
WarPresence.AREA_RADIUS_M = 400

-- Per player, per region. Long enough that crossing the boundary repeatedly
-- does not spam, short enough that coming back after a real absence tells you
-- the war is still on.
WarPresence.COOLDOWN_MS = 10 * 60 * 1000

-- Persistent registries. Plain Lua tables do NOT survive reload-lua.sh (see
-- war_login.lua's header on PlayerTriggers being rebuilt), and an area whose
-- OID we forgot is an area we can never destroy.
WarPresence.AREAS_KEY = "warpresence:areas"

local function splitOids(raw)
	local out = {}
	if raw == nil or raw == "" then
		return out
	end
	for token in string.gmatch(raw, "([^,]+)") do
		local oid = tonumber(token)
		if oid ~= nil then
			out[#out + 1] = oid
		end
	end
	return out
end

--- Destroy every presence area from previous cycles. Safe to call when there
-- are none, and safe if an area was already reaped by something else.
function WarPresence.clear()
	pcall(function()
		for _, oid in ipairs(splitOids(readStringData(WarPresence.AREAS_KEY))) do
			local pArea = getSceneObject(oid)
			if pArea ~= nil then
				pcall(function() SceneObject(pArea):destroyObjectFromWorld(false) end)
			end
			-- Drop the per-area region mapping too, or the string-data table
			-- grows without bound across cycles.
			pcall(function() deleteStringData("warpresence:area:" .. tostring(oid)) end)
		end
		writeStringData(WarPresence.AREAS_KEY, "")
	end)
end

--- Spawn the "you have walked into a contested town" area for one region.
-- Called by war_battle.lua once per region it actually staged sites in.
function WarPresence.attachRegion(zoneName, regionId, sites)
	-- sites == 0 is a HELD town (the spread layer's garrison), which gets an
	-- arrival line of its own. Only a nil/negative count is refused.
	if zoneName == nil or regionId == nil or sites == nil or sites < 0 then
		return nil
	end

	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	if coords == nil then
		return nil
	end

	local pArea = nil
	pcall(function()
		-- Arg order (zone, iff, x, z, y, radius, cell) -- same as
		-- WarSquad.attachSite, which documents the C++ stack offsets.
		pArea = spawnActiveArea(zoneName, "object/active_area.iff",
			coords[1], 0, coords[2], WarPresence.AREA_RADIUS_M, 0)

		if pArea == nil then
			return
		end

		createObserver(ENTEREDAREA, "WarPresence", "onEnteredArea", pArea)

		local oid = SceneObject(pArea):getObjectID()

		-- Region + site count are stored against the AREA, not in a Lua
		-- table, so the observer still knows what it is announcing after a
		-- reload has thrown every in-memory table away.
		writeStringData("warpresence:area:" .. tostring(oid),
			tostring(regionId) .. "," .. tostring(sites))

		local raw = readStringData(WarPresence.AREAS_KEY)
		if raw == nil or raw == "" then
			writeStringData(WarPresence.AREAS_KEY, tostring(oid))
		else
			writeStringData(WarPresence.AREAS_KEY, raw .. "," .. tostring(oid))
		end
	end)

	return pArea
end

function WarPresence:onEnteredArea(pArea, pCreature)
	pcall(function()
		if pArea == nil or pCreature == nil then
			return
		end
		if not SceneObject(pCreature):isPlayerCreature() then
			return
		end

		local areaOid = SceneObject(pArea):getObjectID()
		local stored = readStringData("warpresence:area:" .. tostring(areaOid))
		if stored == nil or stored == "" then
			return
		end

		local regionId, sites = string.match(stored, "([^,]+),([^,]+)")
		if regionId == nil then
			return
		end
		sites = tonumber(sites) or 1

		local playerOid = SceneObject(pCreature):getObjectID()
		local key = playerOid .. ":war:presence:" .. regionId
		local last = readData(key)
		local now = getTimestampMilli()
		if last ~= nil and last > 0 and (now - last) < WarPresence.COOLDOWN_MS then
			return
		end
		writeData(key, now)

		local name = regionId
		if WarReport ~= nil and WarReport.regionName ~= nil then
			name = WarReport.regionName(regionId)
		end

		local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
		local r = (st ~= nil and st.regions ~= nil) and st.regions[regionId] or nil

		if sites > 0 then
			local plural = (sites == 1) and "engagement" or "engagements"
			CreatureObject(pCreature):sendSystemMessage(string.format(
				"%s is CONTESTED -- %d %s underway nearby. A waypoint has been added to your datapad.",
				tostring(name), sites, plural))
		elseif WarVoice ~= nil and WarVoice.held ~= nil then
			CreatureObject(pCreature):sendSystemMessage(WarVoice.held(name, r and r.faction or nil))
		end

		-- Supply visibility (owner ruling 2026-09-04): the sim has always
		-- known when a line is cut; this is the first time the ground says so.
		if r ~= nil and WarVoice ~= nil and WarVoice.supply ~= nil then
			local line = WarVoice.supply(name, r.supply_status)
			if line ~= nil then
				CreatureObject(pCreature):sendSystemMessage(line)
			end
		end

		-- Courier hand-in: walking into the destination town with its crate
		-- IS the delivery. No NPC, no menu -- see war_courier.lua.
		if WarCourier ~= nil and WarCourier.tryDeliver ~= nil then
			pcall(function() WarCourier.tryDeliver(pCreature, regionId) end)
		end

		-- Layer 2: ground that changed hands here recently is news on arrival.
		-- Written by war_battle.lua's reconcile() on a capture, cleared when
		-- that garrison ages out.
		local captor = readStringData("warbattle:lastcapture:" .. tostring(regionId))
		if captor ~= nil and captor ~= "" and WarVoice ~= nil and WarVoice.captureNote ~= nil then
			CreatureObject(pCreature):sendSystemMessage(WarVoice.captureNote(captor))
		end

		if sites > 0 then
			WarPresence.markSite(pCreature, regionId)
		end
	end)
	return 0
end

--- Waypoint the anchor site. Deliberately delegates the coords+offset maths
-- to WarBattle.anchorPoint() rather than recomputing it -- see the header.
function WarPresence.markSite(pPlayer, regionId)
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	local zone = (WarReport ~= nil) and WarReport.PLANET_OF[regionId] or nil
	if coords == nil or zone == nil then
		return
	end

	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return
	end

	local wx, wy = coords[1], coords[2]
	if WarBattle ~= nil and WarBattle.anchorPoint ~= nil then
		wx, wy = WarBattle.anchorPoint(coords, regionId)
	end

	local color = 6
	if WarRecruiter ~= nil and WarRecruiter.WAYPOINT_COLOR ~= nil then
		color = WarRecruiter.WAYPOINT_COLOR
	end

	local name = regionId
	if WarReport ~= nil and WarReport.regionName ~= nil then
		name = WarReport.regionName(regionId)
	end

	pcall(function()
		PlayerObject(pGhost):addWaypoint(zone, "Fighting: " .. tostring(name), "",
			wx, 0, wy, color, true, true, 0, 0)
	end)
end

--- No global schedule of its own: war_battle.lua owns the war screenplays'
-- lifecycle (same reasoning WarSquad:start() documents).
function WarPresence:start()
end

--- Server-side proof this module is wired: that it loaded on this thread,
-- that war_battle.lua's staging actually registered presence areas, and that
-- the reap key is readable. It cannot prove a player SEES the message --
-- per CLAUDE.md, in-game behaviour is not provable server-side.
function Tests:warPresenceCheck()
	printf("WARPRESENCE: begin\n")

	if WarPresence == nil then
		printf("WARPRESENCE: FAIL -- module not loaded on this thread\n")
		return
	end

	printf("WARPRESENCE: PASS module loaded, radius=" .. tostring(WarPresence.AREA_RADIUS_M) .. "m\n")
	printf("WARPRESENCE: attachRegion callable=" .. tostring(type(WarPresence.attachRegion) == "function") .. "\n")
	printf("WARPRESENCE: clear callable=" .. tostring(type(WarPresence.clear) == "function") .. "\n")

	local raw = readStringData(WarPresence.AREAS_KEY)
	local n = 0
	if raw ~= nil and raw ~= "" then
		for _ in string.gmatch(raw, "([^,]+)") do n = n + 1 end
	end
	printf("WARPRESENCE: registered presence area(s)=" .. tostring(n) .. "\n")

	local sraw = (WarSquad ~= nil) and readStringData(WarSquad.AREAS_KEY) or nil
	local sn = 0
	if sraw ~= nil and sraw ~= "" then
		for _ in string.gmatch(sraw, "([^,]+)") do sn = sn + 1 end
	end
	printf("WARPRESENCE: registered WarSquad formup area(s)=" .. tostring(sn) .. "\n")

	printf("WARPRESENCE: end\n")
end
