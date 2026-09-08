--[[
war_convoy.lua -- Convoys on the roads (B55; owner ruling 2026-09-07, evening:
"convoys on the roads").

Supply was a number. Now a front town's holder sends a convoy in every few
minutes: a quartermaster and two escorts appear START_M out along the road
home (the bearing from the town to the holder's capital on this planet) and
walk in, a leg every STEP_MS. If the quartermaster reaches the centre the
town gets CRATES of materiel_delivery -- real crates into the sim, a courier
run's worth -- and every friendly player within ESCORT_M is the escort and is
paid ESCORT_POINTS (base_delivery, to their name). If the quartermaster dies
on the way the ground reports convoy_lost: the digest says a convoy into the
town was destroyed, and the town simply never gets those crates. Attackers
deny supply by killing convoys; defenders keep it by walking beside them.

At most MAX_AT_ONCE convoys stand at a time, fronts first, hottest first.
The bodies are not in the battle roster and not in the NPC budget (six at
most). State: shared string data (warconvoy:<region>, warconvoy:list) and a
chain event, kicked at include time through a shared-memory gate (schedules
only -- CLAUDE.md). A restart loses the convoys with the process.

Pure, tested by the probe: WarConvoy.homeBearing, WarConvoy.candidates,
WarConvoy.legTowards. Console: test warConvoyCheck (read-only),
test warConvoyStageNow (an ACTION: spawns one convoy at the hottest front).
]]

WarConvoy = WarConvoy or {}

WarConvoy.ENABLED = true
WarConvoy.CYCLE_MS = 4 * 60 * 1000
WarConvoy.STEP_MS = 12 * 1000
WarConvoy.KICK_KEY = "warconvoy:kick_ms"
WarConvoy.KICK_GAP_MS = 60 * 1000
WarConvoy.CHAIN_KEY = "warconvoy:chain_ms"
WarConvoy.MAX_AT_ONCE = 2
WarConvoy.START_M = 160
WarConvoy.START_FALLBACK_M = { 120, 80 }
WarConvoy.LEG_M = 22
WarConvoy.ARRIVE_M = 14
WarConvoy.ESCORT_M = 30
WarConvoy.TIMEOUT_MS = 8 * 60 * 1000
WarConvoy.CRATES = 5.0
WarConvoy.ESCORT_POINTS = 2.0
WarConvoy.ESCORT_SOURCE = "base_delivery"
WarConvoy.DELIVERY_SOURCE = "materiel_delivery"
WarConvoy.LOST_SOURCE = "convoy_lost"
WarConvoy.KEY_PREFIX = "warconvoy:"
WarConvoy.LIST_KEY = "warconvoy:list"
WarConvoy.NAME = { imperial = "Imperial supply convoy", rebel = "Alliance supply convoy" }
WarConvoy.LINES = {
	imperial = { start = "Convoy for %s -- keep the pace, eyes on the treeline.", arrive = "Convoy in. %s eats tonight." },
	rebel    = { start = "Supply run for %s. Stay close and keep moving.",       arrive = "Made it. Crates for %s, signed and handed in." },
}

local function name(id)
	if WarLines ~= nil and WarLines.name ~= nil then
		return WarLines.name(id)
	end
	return tostring(id)
end

local function planetOf(id)
	return (WarLines ~= nil and WarLines.planetOf ~= nil) and WarLines.planetOf(id) or nil
end

--- The unit vector from a town toward "home": the holder's capital on the
-- same planet, else the holder's nearest held town there, else east. Pure
-- given the state and COORDS.
function WarConvoy.homeBearing(st, coordsOf, regionId, holder)
	local here = coordsOf[regionId]
	if here == nil or st == nil or type(st.regions) ~= "table" then
		return 1, 0, nil
	end
	local planet = planetOf(regionId)
	local bestId, bestD, capitalId = nil, nil, nil
	for id, r in pairs(st.regions) do
		if id ~= regionId and r.faction == holder and coordsOf[id] ~= nil and planetOf(id) == planet then
			local dx, dy = coordsOf[id][1] - here[1], coordsOf[id][2] - here[2]
			local d = math.sqrt(dx * dx + dy * dy)
			if r.is_capital == true and capitalId == nil then
				capitalId = id
			end
			if bestD == nil or d < bestD then
				bestId, bestD = id, d
			end
		end
	end
	local target = capitalId or bestId
	if target == nil then
		return 1, 0, nil
	end
	local dx, dy = coordsOf[target][1] - here[1], coordsOf[target][2] - here[2]
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then
		return 1, 0, target
	end
	return dx / len, dy / len, target
end

--- The fronts whose holder still has a road in (supply not cut), hottest
-- first: { region, holder }. Pure given fronts and the state.
function WarConvoy.candidates(st, fronts)
	local out = {}
	if st == nil or type(st.regions) ~= "table" or type(fronts) ~= "table" then
		return out
	end
	for _, f in ipairs(fronts) do
		local r = st.regions[f.id]
		if r ~= nil and r.faction ~= nil and r.supply_status ~= "cut" and WarConvoy.NAME[r.faction] ~= nil then
			out[#out + 1] = { region = f.id, holder = r.faction }
		end
	end
	return out
end

--- One leg from (x, y) toward (tx, ty): LEG_M closer, or the target itself
-- when it is nearer than that. Pure.
function WarConvoy.legTowards(x, y, tx, ty)
	local dx, dy = tx - x, ty - y
	local d = math.sqrt(dx * dx + dy * dy)
	if d <= WarConvoy.LEG_M then
		return tx, ty, d
	end
	return x + dx / d * WarConvoy.LEG_M, y + dy / d * WarConvoy.LEG_M, d
end

-- ----------------------------------------------------------- state ------
local function listOf()
	local raw = readStringData(WarConvoy.LIST_KEY)
	local out = {}
	if raw ~= nil and raw ~= "" then
		for id in string.gmatch(raw, "[^,]+") do out[#out + 1] = id end
	end
	return out
end

local function listWrite(list)
	writeStringData(WarConvoy.LIST_KEY, table.concat(list, ","))
end

local function recordOf(regionId)
	local raw = readStringData(WarConvoy.KEY_PREFIX .. tostring(regionId))
	if raw == nil or raw == "" then
		return nil
	end
	local oids, spawnMs, holder = string.match(raw, "^([%d,]+)|(%d+)|(%a+)$")
	if oids == nil then
		return nil
	end
	local rec = { oids = {}, spawnMs = tonumber(spawnMs) or 0, holder = holder }
	for id in string.gmatch(oids, "[^,]+") do rec.oids[#rec.oids + 1] = tonumber(id) end
	return rec
end

local function forget(regionId)
	writeStringData(WarConvoy.KEY_PREFIX .. tostring(regionId), "")
	local keep = {}
	for _, id in ipairs(listOf()) do
		if id ~= tostring(regionId) then keep[#keep + 1] = id end
	end
	listWrite(keep)
end

local function despawn(rec)
	for _, oid in ipairs(rec.oids) do
		local p = getSceneObject(oid)
		if p ~= nil then
			pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
		end
	end
end

local function say(pNpc, text)
	if pNpc ~= nil and text ~= nil then
		pcall(function() spatialChat(pNpc, text) end)
	end
end

local function walkable(zone, x, y)
	if type(isPointWalkable) ~= "function" or type(getWorldFloor) ~= "function" then
		return true
	end
	local okz, z = pcall(getWorldFloor, x, y, zone)
	if not okz or type(z) ~= "number" then
		return false
	end
	local ok, w = pcall(isPointWalkable, zone, x, z, y)
	return ok and w == true
end

-- ---------------------------------------------------------- spawn -------
--- Spawn one convoy for `holder` into `regionId`. Returns the bodies (0..3).
function WarConvoy.spawn(regionId, holder)
	if WarReport == nil or WarBattle == nil or WarBattle.ROLES == nil then
		return 0
	end
	local st = WarReport.state()
	local coords = WarReport.COORDS[regionId]
	local zone = WarReport.PLANET_OF[regionId]
	if st == nil or coords == nil or zone == nil or not isZoneEnabled(zone) or recordOf(regionId) ~= nil then
		return 0
	end
	local ux, uy, home = WarConvoy.homeBearing(st, WarReport.COORDS, regionId, holder)
	local sx, sy = nil, nil
	for _, r in ipairs({ WarConvoy.START_M, WarConvoy.START_FALLBACK_M[1], WarConvoy.START_FALLBACK_M[2] }) do
		local x, y = coords[1] + ux * r, coords[2] + uy * r
		if sx == nil and walkable(zone, x, y) then sx, sy = x, y end
	end
	if sx == nil then
		sx, sy = coords[1] + ux * WarConvoy.START_FALLBACK_M[2], coords[2] + uy * WarConvoy.START_FALLBACK_M[2]
	end
	local pool = WarBattle.ROLES[holder]
	if pool == nil then
		return 0
	end
	local oids, bodies = {}, {}
	local plan = { { pool.medic, 0, 0, WarConvoy.NAME[holder] }, { pool.rifleman, -uy * 3, ux * 3, nil }, { pool.rifleman, uy * 3, -ux * 3, nil } }
	for i, spec in ipairs(plan) do
		local x, y = sx + spec[2], sy + spec[3]
		local z = getWorldFloor(x, y, zone)
		local p = spawnMobile(zone, spec[1], 0, x, z, y, 0, 0)
		if p ~= nil then
			if spec[4] ~= nil then
				pcall(function() SceneObject(p):setCustomObjectName(spec[4]) end)
			end
			oids[#oids + 1] = SceneObject(p):getObjectID()
			bodies[#bodies + 1] = p
		end
	end
	if #bodies == 0 then
		return 0
	end
	local parts = {}
	for _, oid in ipairs(oids) do parts[#parts + 1] = tostring(oid) end
	writeStringData(WarConvoy.KEY_PREFIX .. tostring(regionId), table.concat(parts, ",") .. "|" .. tostring(getTimestampMilli()) .. "|" .. holder)
	local list = listOf()
	list[#list + 1] = tostring(regionId)
	listWrite(list)
	say(bodies[1], string.format(WarConvoy.LINES[holder].start, name(regionId)))
	printf(string.format("WarConvoy: %s convoy for %s from %s: %d bodies at (%.0f, %.0f), %.0f m out\n",
		tostring(holder), tostring(regionId), tostring(home), #bodies, sx, sy,
		math.sqrt((sx - coords[1]) ^ 2 + (sy - coords[2]) ^ 2)))
	return #bodies
end

--- Every few minutes: convoys for the fronts that can still be supplied,
-- up to MAX_AT_ONCE standing.
function WarConvoy.cycleOnce()
	if not WarConvoy.ENABLED or WarReport == nil or WarBattle == nil or WarBattle.fronts == nil then
		return 0
	end
	local st = WarReport.state()
	local standing = #listOf()
	local spawned = 0
	for _, c in ipairs(WarConvoy.candidates(st, WarBattle.fronts())) do
		if standing + spawned >= WarConvoy.MAX_AT_ONCE then
			break
		end
		if recordOf(c.region) == nil then
			local ok, n = pcall(WarConvoy.spawn, c.region, c.holder)
			if ok and (n or 0) > 0 then
				spawned = spawned + 1
			elseif not ok then
				printf("WarConvoy: spawn at " .. tostring(c.region) .. " failed: " .. tostring(n) .. "\n")
			end
		end
	end
	return spawned
end

-- ---------------------------------------------------------- the walk ----
local function arrived(regionId, rec, pQm)
	local st = WarReport.state()
	if WarContrib ~= nil and WarContrib.record ~= nil then
		local okR, recorded, why = pcall(WarContrib.record, rec.holder, regionId, WarConvoy.DELIVERY_SOURCE, WarConvoy.CRATES, nil)
		printf("WarConvoy: convoy into " .. tostring(regionId) .. " arrived: " .. tostring(WarConvoy.CRATES) .. " crates "
			.. ((okR and recorded) and "recorded" or ("NOT recorded: " .. tostring(why or recorded))) .. "\n")
		-- The escorts: friendly players beside the quartermaster.
		local players = {}
		pcall(function() players = SceneObject(pQm):getPlayersInRange(WarConvoy.ESCORT_M) end)
		if type(players) == "table" then
			for _, pPlayer in ipairs(players) do
				pcall(function()
					local side = (WarStandings ~= nil and WarStandings.factionOf ~= nil) and WarStandings.factionOf(pPlayer) or nil
					if side == rec.holder then
						local oid = SceneObject(pPlayer):getObjectID()
						WarContrib.record(rec.holder, regionId, WarConvoy.ESCORT_SOURCE, WarConvoy.ESCORT_POINTS, oid)
						CreatureObject(pPlayer):sendSystemMessage("The convoy you escorted into " .. name(regionId) .. " made it: "
							.. string.format("%.1f", WarConvoy.ESCORT_POINTS) .. " crates' worth to your name.")
					end
				end)
			end
		end
	end
	say(pQm, string.format(WarConvoy.LINES[rec.holder].arrive, name(regionId)))
end

local function lost(regionId, rec)
	if WarContrib ~= nil and WarContrib.record ~= nil then
		local okR, recorded, why = pcall(WarContrib.record, rec.holder, regionId, WarConvoy.LOST_SOURCE, 1, nil)
		printf("WarConvoy: convoy into " .. tostring(regionId) .. " destroyed -- "
			.. ((okR and recorded) and "reported" or ("NOT reported: " .. tostring(why or recorded))) .. "\n")
	end
end

function WarConvoy.stepOnce()
	local now = getTimestampMilli()
	local moved = 0
	for _, regionId in ipairs(listOf()) do
		pcall(function()
			local rec = recordOf(regionId)
			if rec == nil then
				forget(regionId)
				return
			end
			local coords = WarReport.COORDS[regionId]
			local zone = WarReport.PLANET_OF[regionId]
			local pQm = getSceneObject(rec.oids[1] or 0)
			local okd, dead = pcall(function() return pQm ~= nil and CreatureObject(pQm):isDead() end)
			if pQm == nil or (okd and dead == true) then
				lost(regionId, rec)
				despawn(rec)
				forget(regionId)
				return
			end
			if (now - rec.spawnMs) > WarConvoy.TIMEOUT_MS or coords == nil or zone == nil then
				printf("WarConvoy: convoy into " .. tostring(regionId) .. " timed out; stood down\n")
				despawn(rec)
				forget(regionId)
				return
			end
			local so = SceneObject(pQm)
			local x, y = so:getWorldPositionX(), so:getWorldPositionY()
			local nx, ny, d = WarConvoy.legTowards(x, y, coords[1], coords[2])
			if d <= WarConvoy.ARRIVE_M then
				arrived(regionId, rec, pQm)
				despawn(rec)
				forget(regionId)
				return
			end
			local z = getWorldFloor(nx, ny, zone)
			for i, oid in ipairs(rec.oids) do
				local p = getSceneObject(oid)
				if p ~= nil then
					local ox, oy = 0, 0
					if i > 1 then
						local ux, uy = (coords[1] - x) / math.max(1, d), (coords[2] - y) / math.max(1, d)
						local side = (i == 2) and 1 or -1
						ox, oy = -uy * 3 * side, ux * 3 * side
					end
					pcall(function() AiAgent(p):setNextPosition(nx + ox, z, ny + oy, 0) end)
				end
			end
			moved = moved + 1
		end)
	end
	return moved
end

-- --------------------------------------------------------- the chains ---
function WarConvoy:cycle()
	pcall(WarConvoy.cycleOnce)
	createEvent(WarConvoy.CYCLE_MS, "WarConvoy", "cycle", nil, "")
end

function WarConvoy:step()
	writeSharedMemory(WarConvoy.CHAIN_KEY, getTimestampMilli())
	pcall(WarConvoy.stepOnce)
	createEvent(WarConvoy.STEP_MS, "WarConvoy", "step", nil, "")
end

function WarConvoy:kick()
	createEvent(20 * 1000, "WarConvoy", "cycle", nil, "")
	createEvent(WarConvoy.STEP_MS, "WarConvoy", "step", nil, "")
	printf("WarConvoy: chains started\n")
end

-- Include-time kick: schedules only, one thread per reload wins the gate,
-- and only when no chain has stepped in the last two minutes (a reload
-- must not start a second chain beside a running one).
pcall(function()
	local last = readSharedMemory(WarConvoy.KICK_KEY) or 0
	local stepped = readSharedMemory(WarConvoy.CHAIN_KEY) or 0
	local t = getTimestampMilli()
	if (last == 0 or (t - last) >= WarConvoy.KICK_GAP_MS) and (stepped == 0 or (t - stepped) > 10 * WarConvoy.STEP_MS) then
		writeSharedMemory(WarConvoy.KICK_KEY, t)
		createEvent(3000, "WarConvoy", "kick", nil, "")
	end
end)

-- ------------------------------------------------------------ probes ----
if type(Tests) == "table" then
	function Tests:warConvoyCheck()
		printf("WARCONVOY: begin\n")
		local ok, err = pcall(function()
			local st = WarReport.state()
			local fronts = (WarBattle ~= nil and WarBattle.fronts ~= nil) and WarBattle.fronts() or {}
			local cands = WarConvoy.candidates(st, fronts)
			printf("WARCONVOY: " .. tostring(#cands) .. " candidate front(s) of " .. tostring(#fronts) .. "; standing now: " .. tostring(#listOf()) .. "\n")
			for _, c in ipairs(cands) do
				local ux, uy, home = WarConvoy.homeBearing(st, WarReport.COORDS, c.region, c.holder)
				printf(string.format("WARCONVOY:   %s (%s) home=%s bearing=(%.2f, %.2f)\n", c.region, c.holder, tostring(home), ux, uy))
			end
			for _, regionId in ipairs(listOf()) do
				local rec = recordOf(regionId)
				local pQm = rec and getSceneObject(rec.oids[1] or 0) or nil
				printf("WARCONVOY:   standing at " .. regionId .. ": " .. (pQm and string.format("quartermaster at (%.0f, %.0f)", SceneObject(pQm):getWorldPositionX(), SceneObject(pQm):getWorldPositionY()) or "no quartermaster") .. "\n")
			end
			local nx, ny, d = WarConvoy.legTowards(0, 0, 100, 0)
			printf("WARCONVOY: " .. ((math.abs(nx - WarConvoy.LEG_M) < 0.01 and ny == 0 and d == 100) and "PASS" or "FAIL") .. " a leg is LEG_M toward the target\n")
			nx, ny, d = WarConvoy.legTowards(0, 0, 5, 0)
			printf("WARCONVOY: " .. ((nx == 5 and d == 5) and "PASS" or "FAIL") .. " the last leg lands on the target\n")
			local ux, uy = WarConvoy.homeBearing({ regions = {} }, WarReport.COORDS, "nab_theed", "imperial")
			printf("WARCONVOY: " .. ((ux == 1 and uy == 0) and "PASS" or "FAIL") .. " no home means east\n")
			printf("WARCONVOY: " .. ((#WarConvoy.candidates(nil, fronts) == 0) and "PASS" or "FAIL") .. " no state, no candidates\n")
			local stepped = readSharedMemory(WarConvoy.CHAIN_KEY) or 0
			printf("WARCONVOY: " .. ((stepped > 0 and (getTimestampMilli() - stepped) < 5 * WarConvoy.STEP_MS) and "PASS" or "FAIL")
				.. " the step chain is alive (last step " .. tostring(math.floor((getTimestampMilli() - stepped) / 1000)) .. " s ago)\n")
		end)
		if not ok then
			printf("WARCONVOY: failed: " .. tostring(err) .. "\n")
		end
		printf("WARCONVOY: end\n")
	end

	function Tests:warConvoyStageNow()
		printf("WARCONVOYNOW: begin\n")
		local ok, err = pcall(function()
			local st = WarReport.state()
			local cands = WarConvoy.candidates(st, WarBattle.fronts())
			if #cands == 0 then
				printf("WARCONVOYNOW: no candidate front\n")
				return
			end
			local n = WarConvoy.spawn(cands[1].region, cands[1].holder)
			printf("WARCONVOYNOW: " .. tostring(n) .. " bodies for " .. cands[1].region .. "\n")
		end)
		if not ok then
			printf("WARCONVOYNOW: failed: " .. tostring(err) .. "\n")
		end
		printf("WARCONVOYNOW: end\n")
	end
end
