--[[
  custom_scripts/screenplays/simplayers/sim_players.lua

  SimPlayers: Erenshor-style NPC "players" for the war (docs/DESIGN-SIMPLAYERS.md).

  Twelve named, persistent characters (sim_config.lua ROSTER) who live in the
  war the way a player would. Each is a small state machine driven by one
  global tick:

    rest    standing in a cantina (or on the shuttle pad) of some war city,
            greeting players who come near, until they decide to move
    travel  despawned -- "on the shuttle" -- arriving at `dest` after TRAVEL_MS
    fight   spawned at a front, set on the other side's troops, earning XP
            per tick alive, until the stint ends or they die
    clone   dead; back at a friendly city after CLONE_MS with a line about it
    escort  following the player who asked, until dismissed, lost, or bored

  What they touch and what they do not (Contract P / L, DESIGN-POPULATION):
  they kill and die on the ground exactly like war_battle.lua's troops --
  they are that pool's templates, faction-flagged and ATTACKABLE, so the
  other side (players included) can kill them -- and they write NOTHING to
  the war sim: no ledger row, no population count, no supply. The sim never
  knows they exist; the ground does.

  STATE lives in string shared memory (survives reloads, visible from every
  thread) and is mirrored to log/simplayers.state so a restart puts everyone
  back where they were (rank included). OIDs are not persisted across a
  restart -- the bodies are non-persistent objects and go with the process.

  INCLUDE-TIME RULE (CLAUDE.md): nothing here spawns at include time. The
  tail of this file only schedules a one-shot, shared-memory-gated kick, so
  a reload onto a running server starts the tick chain without a restart.
]]

SimPlayers = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "SimPlayers",
}

registerScreenPlay("SimPlayers", true)

SimPlayers.STATE_FILE   = "log/simplayers.state"
SimPlayers.CHAIN_KEY    = "simplayers:chain_ms"
SimPlayers.KICK_KEY     = "simplayers:kick_ms"
SimPlayers.KICK_GAP_MS  = 60 * 1000

-- ================================================================ helpers ==

local function cfg()
	return (type(SIM_CONFIG) == "table") and SIM_CONFIG or nil
end

local function now()
	return getTimestampMilli()
end

local function stableHash(s)
	local h = 17
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 1000003
	end
	return h
end

local function regionName(regionId)
	if WarReport ~= nil and WarReport.regionName ~= nil then
		return WarReport.regionName(regionId)
	end
	return tostring(regionId)
end

local function stateKey(id)
	return "simplayers:" .. id
end

-- ----------------------------------------------------------- state I/O ----

local FIELDS = { "state", "region", "until_ms", "oid", "xp", "escort", "misses", "lastChat", "intent", "dest", "last", "rank" }

function SimPlayers.load(id)
	local raw = readStringData(stateKey(id))
	local st = { state = "", region = "", until_ms = 0, oid = 0, xp = 0, escort = 0, misses = 0, lastChat = 0, intent = "", dest = "", last = "", rank = 1 }
	if raw == nil or raw == "" then
		return st, false
	end
	for k, v in string.gmatch(raw, "([%w_]+)=([^;]*)") do
		local n = tonumber(v)
		if k == "state" or k == "region" or k == "intent" or k == "dest" or k == "last" then
			st[k] = v
		elseif n ~= nil then
			st[k] = n
		end
	end
	return st, true
end

function SimPlayers.save(id, st)
	local parts = {}
	for _, k in ipairs(FIELDS) do
		parts[#parts + 1] = k .. "=" .. tostring(st[k] == nil and "" or st[k])
	end
	writeStringData(stateKey(id), table.concat(parts, ";"))
end

--- Mirror to disk (everything but oid, which dies with the process).
function SimPlayers.persistAll()
	local c = cfg()
	if c == nil then return end
	local fh = io.open(SimPlayers.STATE_FILE, "w")
	if fh == nil then
		return
	end
	for _, sim in ipairs(c.ROSTER) do
		local st = SimPlayers.load(sim.id)
		fh:write(string.format("%s|%s|%s|%d|%d|%d|%s|%s\n", sim.id, st.state, st.region,
			math.floor(st.until_ms or 0), math.floor(st.xp or 0), math.floor(st.rank or 1),
			tostring(st.intent or ""), tostring(st.dest or "")))
	end
	fh:close()
end

--- Read the mirror back for any sim whose shared-memory record is empty
-- (i.e. after a restart). Bodies are respawned by the first tick.
function SimPlayers.restoreFromDisk()
	local fh = io.open(SimPlayers.STATE_FILE, "r")
	if fh == nil then
		return 0
	end
	local restored = 0
	for line in fh:lines() do
		local id, state, region, until_ms, xp, rank, intent, dest = string.match(line,
			"^([%w_]+)|([%w_]*)|([%w_]*)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([%w_]*)|([%w_]*)")
		if id ~= nil then
			local st, present = SimPlayers.load(id)
			if not present then
				st.region = region
				st.until_ms = tonumber(until_ms) or 0
				st.xp = tonumber(xp) or 0
				st.rank = tonumber(rank) or 1
				st.intent = intent
				st.dest = dest
				st.oid = 0
				if state == "travel" or state == "clone" then
					-- Still in progress; resumes on its own timer.
					st.state = state
				else
					-- The body died with the process. Anyone who was standing
					-- somewhere (resting, fighting, following) arrives back
					-- there on the first tick, as if off a shuttle -- not
					-- counted as killed, no clone line, rank intact.
					st.state = "travel"
					st.dest = (region ~= "" and region) or dest
					st.intent = (state == "fight") and "fight" or "rest"
					st.until_ms = 0
				end
				SimPlayers.save(id, st)
				restored = restored + 1
			end
		end
	end
	fh:close()
	return restored
end

-- ------------------------------------------------------------ rank/xp -----

function SimPlayers.rankFor(xp)
	local c = cfg()
	local r = 1
	if c == nil then return 1 end
	for i = 1, #c.RANKS do
		if xp >= c.RANKS[i].xp then
			r = i
		end
	end
	return r
end

function SimPlayers.rankTitle(sim, rank)
	local c = cfg()
	if c == nil then return "" end
	local row = c.RANKS[math.max(1, math.min(rank, #c.RANKS))]
	return row[sim.faction] or row.rebel or ""
end

function SimPlayers.templateFor(sim, rank)
	local c = cfg()
	if c == nil then return nil end
	local pool = c.TEMPLATES[sim.faction]
	if pool == nil or #pool == 0 then return nil end
	return pool[math.max(1, math.min(rank, #pool))]
end

-- ------------------------------------------------------------- world -------

local function warState()
	if WarReport == nil or WarReport.state == nil then
		return nil
	end
	return WarReport.state()
end

local function regionRow(regionId)
	local st = warState()
	if st == nil or st.regions == nil then
		return nil
	end
	return st.regions[regionId]
end

local function regionHolder(regionId)
	local r = regionRow(regionId)
	return r and r.faction or nil
end

local function regionSupply(regionId)
	local r = regionRow(regionId)
	return r and r.supply_status or nil
end

local function planetOf(regionId)
	return (WarReport ~= nil and WarReport.PLANET_OF ~= nil) and WarReport.PLANET_OF[regionId] or nil
end

local function fronts()
	if WarReport == nil or WarReport.frontRegions == nil then
		return {}
	end
	local ok, f = pcall(WarReport.frontRegions)
	if not ok or type(f) ~= "table" then
		return {}
	end
	return f
end

local function allRegions()
	if WarReport == nil or WarReport.regionIds == nil then
		return {}
	end
	local ok, ids = pcall(WarReport.regionIds)
	if not ok or type(ids) ~= "table" then
		return {}
	end
	return ids
end

--- Regions with in-game coordinates only; a SimPlayer cannot stand in a
-- region the map has no place for (Jundland, Lianorm).
local function placeable(regionId)
	local c = cfg()
	return c ~= nil and c.ARRIVALS[regionId] ~= nil and WarReport ~= nil and WarReport.COORDS[regionId] ~= nil
end

-- ------------------------------------------------------------- bodies -----

local function resolve(st)
	if st.oid == nil or st.oid == 0 then
		return nil
	end
	return getSceneObject(st.oid)
end

local function despawn(st)
	local p = resolve(st)
	if p ~= nil then
		pcall(function() deleteStringData(tostring(st.oid) .. ":sim:id") end)
		pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
	end
	st.oid = 0
	st.misses = 0
end

--- Where to stand at rest: the cantina if the city has one, else the pad.
local function restSpot(regionId, idx)
	local c = cfg()
	if c == nil then return nil end
	local spot = nil
	if c.REST_IN_CANTINA and type(POPULATION_CANTINAS) == "table" and POPULATION_CANTINAS[regionId] ~= nil then
		local s = POPULATION_CANTINAS[regionId]
		spot = { zone = s.zone, x = s.x, z = s.z, y = s.y, cell = s.cell or 0 }
		-- Not on the performer's exact spot, and not on each other.
		spot.x = spot.x + 1.5 + ((idx or 0) % 3) * 1.2
		spot.y = spot.y - 1.0 - (math.floor((idx or 0) / 3) % 2) * 1.2
	else
		local a = c.ARRIVALS[regionId]
		if a == nil then return nil end
		spot = { zone = a.zone, x = a.x + ((idx or 0) % 4) * 1.5, z = a.z, y = a.y + (math.floor((idx or 0) / 4) % 3) * 1.5, cell = 0 }
	end
	return spot
end

--- Where to stand at a front: beside site 1 of that region.
local function fightSpot(regionId, idx)
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	local zone = planetOf(regionId)
	if coords == nil or zone == nil then return nil end
	local ox, oy = coords[1], coords[2]
	if WarBattle ~= nil and WarBattle.siteOrigin ~= nil then
		local ok, sx, sy = pcall(WarBattle.siteOrigin, coords, regionId, 1, 3, false)
		if ok and sx ~= nil and sy ~= nil then
			ox, oy = sx, sy
		end
	end
	return { zone = zone, x = ox + 6 + ((idx or 0) % 4) * 2, z = 0, y = oy + 6 + (math.floor((idx or 0) / 4) % 3) * 2, cell = 0 }
end

local function spawnBody(sim, st, spot, stationary)
	local template = SimPlayers.templateFor(sim, st.rank or 1)
	if template == nil or spot == nil then
		return nil
	end
	local p = spawnMobile(spot.zone, template, 0, spot.x, spot.z, spot.y, 0, spot.cell or 0)
	if p == nil then
		printf("SimPlayers: spawnMobile returned nil for " .. sim.id .. " (" .. tostring(template) .. ") at " .. tostring(spot.zone) .. "\n")
		return nil
	end
	local so = SceneObject(p)
	pcall(function() so:setCustomObjectName(sim.name) end)
	pcall(function() so:setObjectMenuComponent("SimPlayerMenuComponent") end)
	if stationary then
		pcall(function() AiAgent(p):addObjectFlag(AI_STATIONARY) end)
	end
	st.oid = so:getObjectID()
	st.misses = 0
	writeStringData(tostring(st.oid) .. ":sim:id", sim.id)
	return p
end

--- The enemy war NPCs standing in a region right now, from war_battle's
-- roster (oid|region|site|faction|ox|oy records).
local function enemiesIn(regionId, faction)
	local out = {}
	if WarBattle == nil or WarBattle.ROSTER_KEY == nil then
		return out
	end
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return out
	end
	for rec in string.gmatch(raw, "([^;]+)") do
		local oid, region, site, fac = string.match(rec, "^(%d+)|([%w_]+)|([%w_]+)|([%w_]+)")
		if oid ~= nil and region == regionId and fac ~= nil and fac ~= faction then
			out[#out + 1] = tonumber(oid)
		end
	end
	return out
end

local function engage(sim, st, pNpc)
	local ok, inCombat = pcall(function() return CreatureObject(pNpc):isInCombat() end)
	if ok and inCombat then
		return true
	end
	local mine = SceneObject(pNpc)
	local zone = mine:getZoneName()
	local mx, my = mine:getWorldPositionX(), mine:getWorldPositionY()
	local candidates = enemiesIn(st.region, sim.faction)
	local best, bestD = nil, 250 * 250
	for _, oid in ipairs(candidates) do
		local p = getSceneObject(oid)
		if p ~= nil then
			local so = SceneObject(p)
			if so:getZoneName() == zone then
				local dx, dy = so:getWorldPositionX() - mx, so:getWorldPositionY() - my
				local d = dx * dx + dy * dy
				if d < bestD then
					best, bestD = p, d
				end
			end
		end
	end
	if best == nil then
		return false
	end
	pcall(function() AiAgent(pNpc):removeObjectFlag(AI_STATIONARY) end)
	pcall(function() AiAgent(pNpc):setDefender(best) end)
	pcall(function() AiAgent(pNpc):setFollowObject(best) end)
	pcall(function() AiAgent(best):setDefender(pNpc) end)
	return true
end

local function playersNear(pNpc, range)
	local ok, players = pcall(function() return SceneObject(pNpc):getPlayersInRange(range) end)
	if not ok or type(players) ~= "table" then
		return {}
	end
	return players
end

local function say(pNpc, text)
	if pNpc == nil or text == nil or text == "" then
		return
	end
	pcall(function() spatialChat(pNpc, text) end)
end

local function galaxy(text)
	if text == nil or text == "" then return end
	pcall(function() broadcastToGalaxy(nil, text) end)
end

-- ------------------------------------------------------------ deciding ----

--- The front chosen by style, or nil for "no fight for me right now".
local function chooseFront(sim, st, bucket)
	local f = fronts()
	if sim.style == "brawler" then
		for i = 1, #f do
			if placeable(f[i].id) then return f[i].id end
		end
		return nil
	elseif sim.style == "grinder" then
		local ok = {}
		for i = 1, #f do
			if placeable(f[i].id) then ok[#ok + 1] = f[i].id end
		end
		if #ok == 0 then return nil end
		return ok[(stableHash(sim.id .. ":" .. tostring(bucket)) % #ok) + 1]
	elseif sim.style == "defender" then
		local best, bestC = nil, 0
		for _, id in ipairs(allRegions()) do
			local r = regionRow(id)
			if r ~= nil and r.faction == sim.faction and placeable(id) then
				local c = tonumber(r.contest) or 0
				if c > bestC then best, bestC = id, c end
			end
		end
		if bestC >= 1.0 then return best end
		return nil
	elseif sim.style == "homebody" then
		local home = sim.home
		for i = 1, #f do
			if placeable(f[i].id) and planetOf(f[i].id) == planetOf(home) then
				return f[i].id
			end
		end
		return nil
	end
	return nil
end

--- A city to rest in next, by style.
local function chooseCity(sim, st, bucket)
	if sim.style == "runner" then
		-- The thinnest friendly town: a courier by trade.
		local best, order = nil, { cut = 0, degraded = 1, connected = 2 }
		local bestO = 3
		for _, id in ipairs(allRegions()) do
			local r = regionRow(id)
			if r ~= nil and r.faction == sim.faction and placeable(id) then
				local o = order[tostring(r.supply_status)] or 2
				if o < bestO or (o == bestO and stableHash(id .. tostring(bucket)) % 2 == 0) then
					best, bestO = id, o
				end
			end
		end
		return best or sim.home
	elseif sim.style == "scout" then
		local ok = {}
		for _, id in ipairs(allRegions()) do
			if placeable(id) and id ~= st.region then ok[#ok + 1] = id end
		end
		if #ok == 0 then return sim.home end
		table.sort(ok)
		return ok[(stableHash(sim.id .. ":" .. tostring(bucket)) % #ok) + 1]
	end
	return sim.home
end

--- Where to next. Returns (regionId, intent) with intent "fight" or "rest".
function SimPlayers.decide(sim, st)
	local bucket = math.floor(now() / (10 * 60 * 1000))
	local front = chooseFront(sim, st, bucket)
	if front ~= nil then
		return front, "fight"
	end
	local city = chooseCity(sim, st, bucket)
	if city == nil or not placeable(city) then
		city = placeable(sim.home) and sim.home or "tat_mos_eisley"
	end
	return city, "rest"
end

-- ------------------------------------------------------------- moving -----

local function window(minMs, maxMs, salt)
	local span = math.max(0, (maxMs or minMs) - minMs)
	return minMs + (stableHash(tostring(salt)) % (span + 1))
end

local function enterRest(sim, st, idx, regionId, line)
	local c = cfg()
	despawn(st)
	st.state = "rest"
	st.last = st.region
	st.region = regionId
	st.until_ms = now() + window(c.REST_MIN_MS, c.REST_MAX_MS, sim.id .. tostring(now()))
	local p = spawnBody(sim, st, restSpot(regionId, idx), true)
	if p ~= nil and line ~= nil then
		say(p, line)
	end
	SimPlayers.save(sim.id, st)
end

local function enterFight(sim, st, idx, regionId)
	local c = cfg()
	despawn(st)
	st.state = "fight"
	st.last = st.region
	st.region = regionId
	st.until_ms = now() + window(c.FIGHT_MIN_MS, c.FIGHT_MAX_MS, sim.id .. tostring(now()))
	local p = spawnBody(sim, st, fightSpot(regionId, idx), false)
	if p ~= nil then
		say(p, SimVoice.arriveFight(sim, { dest = regionName(regionId) }, now()))
		engage(sim, st, p)
	end
	SimPlayers.save(sim.id, st)
end

local function depart(sim, st, idx, dest, intent)
	local c = cfg()
	local p = resolve(st)
	if p ~= nil and #playersNear(p, c.INVITE_RANGE_M) > 0 then
		say(p, SimVoice.leaving(sim, { dest = regionName(dest) }, now()))
	end
	if dest == st.region then
		if intent == "fight" then
			enterFight(sim, st, idx, dest)
		else
			enterRest(sim, st, idx, dest, nil)
		end
		return
	end
	despawn(st)
	st.state = "travel"
	st.last = st.region
	st.dest = dest
	st.intent = intent
	st.until_ms = now() + c.TRAVEL_MS
	SimPlayers.save(sim.id, st)
end

--- The friendly city a dead SimPlayer wakes up in: same planet if their side
-- holds anything there, else home.
local function cloneCity(sim, st)
	local planet = planetOf(st.region)
	local candidates = {}
	for _, id in ipairs(allRegions()) do
		if placeable(id) and regionHolder(id) == sim.faction and planetOf(id) == planet then
			candidates[#candidates + 1] = id
		end
	end
	table.sort(candidates)
	if #candidates > 0 then
		return candidates[(stableHash(sim.id .. st.region) % #candidates) + 1]
	end
	return placeable(sim.home) and sim.home or "tat_mos_eisley"
end

-- ------------------------------------------------------------- escort -----

function SimPlayers.recruit(sim, st, pNpc, pPlayer)
	local c = cfg()
	local playerFaction = CreatureObject(pPlayer):getFaction()
	local want = (sim.faction == "rebel") and FACTIONREBEL or FACTIONIMPERIAL
	if playerFaction ~= want then
		say(pNpc, SimVoice.escortRefuse(sim, {}))
		return false
	end
	pcall(function() AiAgent(pNpc):removeObjectFlag(AI_STATIONARY) end)
	pcall(function() AiAgent(pNpc):storeFollowObject() end)
	pcall(function() AiAgent(pNpc):setFollowObject(pPlayer) end)
	st.state = "escort"
	st.escort = SceneObject(pPlayer):getObjectID()
	st.until_ms = now() + c.ESCORT_MS
	st.misses = 0
	SimPlayers.save(sim.id, st)
	say(pNpc, SimVoice.escortAccept(sim, {}))
	return true
end

local function endEscort(sim, st, idx, pNpc, line)
	if pNpc ~= nil then
		pcall(function() AiAgent(pNpc):restoreFollowObject() end)
		pcall(function() AiAgent(pNpc):addObjectFlag(AI_STATIONARY) end)
		say(pNpc, line)
		local so = SceneObject(pNpc)
		local here = (WarReport ~= nil and WarReport.regionAt ~= nil)
			and WarReport.regionAt(so:getZoneName(), so:getWorldPositionX(), so:getWorldPositionY()) or nil
		if here ~= nil then
			st.region = here
		end
	end
	local c = cfg()
	st.state = "rest"
	st.escort = 0
	st.until_ms = now() + window(c.REST_MIN_MS, c.REST_MAX_MS, sim.id .. tostring(now()))
	SimPlayers.save(sim.id, st)
end

-- --------------------------------------------------------------- step -----

function SimPlayers.step(sim, st, idx)
	local c = cfg()
	local t = now()

	if not c.ENABLED then
		if st.oid ~= 0 then
			despawn(st)
			SimPlayers.save(sim.id, st)
		end
		return
	end

	-- First sight of this character: home, at rest.
	if st.state == "" or st.state == nil then
		local home = placeable(sim.home) and sim.home or "tat_mos_eisley"
		enterRest(sim, st, idx, home, nil)
		return
	end

	if st.state == "travel" then
		if t >= (st.until_ms or 0) then
			local dest = placeable(st.dest) and st.dest or (placeable(sim.home) and sim.home or "tat_mos_eisley")
			if st.intent == "fight" then
				enterFight(sim, st, idx, dest)
			else
				enterRest(sim, st, idx, dest, nil)
			end
		end
		return
	end

	if st.state == "clone" then
		if t >= (st.until_ms or 0) then
			local city = placeable(st.dest) and st.dest or cloneCity(sim, st)
			enterRest(sim, st, idx, city, SimVoice.cloned(sim, { dest = regionName(city) }, t))
		end
		return
	end

	local p = resolve(st)

	if st.state == "escort" then
		local pPlayer = (st.escort ~= 0) and getSceneObject(st.escort) or nil
		if p == nil then
			-- Died while following: clone as from a fight.
			st.state = "clone"
			st.dest = cloneCity(sim, st)
			st.until_ms = t + c.CLONE_MS
			st.oid = 0
			SimPlayers.save(sim.id, st)
			return
		end
		local lost = (pPlayer == nil)
		if not lost then
			local d = SceneObject(p):getDistanceTo(pPlayer)
			if SceneObject(p):getZoneName() ~= SceneObject(pPlayer):getZoneName() or d > c.ESCORT_LEASH_M then
				st.misses = (st.misses or 0) + 1
				lost = st.misses >= c.ESCORT_LEASH_TICKS
			else
				st.misses = 0
			end
		end
		if lost then
			endEscort(sim, st, idx, p, SimVoice.escortLost(sim, {}))
		elseif t >= (st.until_ms or 0) then
			endEscort(sim, st, idx, p, SimVoice.escortDismiss(sim, {}))
		else
			SimPlayers.save(sim.id, st)
		end
		return
	end

	if st.state == "fight" then
		if p == nil then
			st.misses = (st.misses or 0) + 1
			if st.misses >= c.MISSES_BEFORE_DEAD then
				st.state = "clone"
				st.dest = cloneCity(sim, st)
				st.until_ms = t + c.CLONE_MS
				st.oid = 0
				st.misses = 0
			end
			SimPlayers.save(sim.id, st)
			return
		end
		st.misses = 0
		st.xp = (st.xp or 0) + c.XP_PER_FIGHT_TICK
		local newRank = SimPlayers.rankFor(st.xp)
		if newRank > (st.rank or 1) then
			st.rank = newRank
			galaxy(SimVoice.promoted(sim, { rank = SimPlayers.rankTitle(sim, newRank), where = regionName(st.region) }))
		end
		engage(sim, st, p)
		if t >= (st.until_ms or 0) then
			-- Stint over: stand down in the same town (respawn as the rank's
			-- body if it changed, which is the only visible sign of a
			-- promotion besides the announcement).
			enterRest(sim, st, idx, st.region, nil)
			return
		end
		SimPlayers.save(sim.id, st)
		return
	end

	-- rest
	if p == nil then
		-- Killed or reaped while resting: come back at the same spot.
		st.misses = (st.misses or 0) + 1
		if st.misses >= c.MISSES_BEFORE_DEAD then
			spawnBody(sim, st, restSpot(st.region, idx), true)
		end
		SimPlayers.save(sim.id, st)
		return
	end
	st.misses = 0
	if t >= (st.until_ms or 0) then
		local dest, intent = SimPlayers.decide(sim, st)
		depart(sim, st, idx, dest, intent)
		return
	end
	if (t - (st.lastChat or 0)) >= c.CHAT_MIN_GAP_MS and #playersNear(p, c.CHAT_RANGE_M) > 0 then
		local f = fronts()
		say(p, SimVoice.greet(sim, {
			front = (f[1] ~= nil) and regionName(f[1].id) or "nowhere",
			hold  = regionName(st.region),
			thin  = regionName(chooseCity({ id = sim.id, style = "runner", faction = sim.faction, home = sim.home }, st, 0) or st.region),
			last  = regionName((st.last ~= nil and st.last ~= "") and st.last or st.region),
		}, math.floor(t / 60000)))
		st.lastChat = t
	end
	SimPlayers.save(sim.id, st)
end

-- --------------------------------------------------------------- tick -----

function SimPlayers:tickOnce()
	local c = cfg()
	if c == nil or type(c.ROSTER) ~= "table" then
		return 0
	end
	local n = 0
	for i, sim in ipairs(c.ROSTER) do
		local st = SimPlayers.load(sim.id)
		local ok, err = pcall(SimPlayers.step, sim, st, i)
		if not ok then
			printf("SimPlayers: step " .. sim.id .. " failed: " .. tostring(err) .. "\n")
		end
		n = n + 1
	end
	pcall(SimPlayers.persistAll)
	return n
end

function SimPlayers:tick()
	writeSharedMemory(SimPlayers.CHAIN_KEY, now())
	pcall(function() SimPlayers:tickOnce() end)
	local c = cfg()
	createEvent((c and c.TICK_MS) or 30000, "SimPlayers", "tick", nil, "")
end

--- Start the tick chain unless one is already running (its heartbeat is
-- CHAIN_KEY, refreshed every tick). Safe to call from boot, from the
-- include-time kick, and from a probe.
function SimPlayers:ensureChain()
	local c = cfg()
	local tickMs = (c and c.TICK_MS) or 30000
	local last = readSharedMemory(SimPlayers.CHAIN_KEY) or 0
	if last ~= 0 and (now() - last) < (3 * tickMs) then
		return false
	end
	writeSharedMemory(SimPlayers.CHAIN_KEY, now())
	createEvent(2000, "SimPlayers", "tick", nil, "")
	return true
end

function SimPlayers:kick()
	self:ensureChain()
end

function SimPlayers:start()
	local restored = 0
	pcall(function() restored = SimPlayers.restoreFromDisk() end)
	printf("SimPlayers: boot -- restored " .. tostring(restored) .. " character(s) from disk\n")
	self:ensureChain()
end

-- ============================================================== radial ====

SimPlayerMenuComponent = {}

local function simFor(pNpc)
	local id = readStringData(tostring(SceneObject(pNpc):getObjectID()) .. ":sim:id")
	local c = cfg()
	if id == nil or id == "" or c == nil then
		return nil, nil
	end
	for _, sim in ipairs(c.ROSTER) do
		if sim.id == id then
			return sim, SimPlayers.load(id)
		end
	end
	return nil, nil
end

function SimPlayerMenuComponent:fillObjectMenuResponse(pSceneObject, pMenuResponse, pPlayer)
	if pSceneObject == nil or pPlayer == nil then
		return
	end
	local c = cfg()
	if c == nil then return end
	local sim, st = simFor(pSceneObject)
	if sim == nil then return end
	local menuResponse = LuaObjectMenuResponse(pMenuResponse)
	menuResponse:addRadialMenuItem(c.RADIAL_ROOT, 3, "Talk")
	menuResponse:addRadialMenuItemToRadialID(c.RADIAL_ROOT, c.RADIAL_ASK, 3, "Ask about the war")
	menuResponse:addRadialMenuItemToRadialID(c.RADIAL_ROOT, c.RADIAL_WHERE, 3, "Where are you headed?")
	local me = SceneObject(pPlayer):getObjectID()
	if st.state == "escort" and st.escort == me then
		menuResponse:addRadialMenuItemToRadialID(c.RADIAL_ROOT, c.RADIAL_RECRUIT, 3, "Carry on without me")
	else
		menuResponse:addRadialMenuItemToRadialID(c.RADIAL_ROOT, c.RADIAL_RECRUIT, 3, "Fight alongside me")
	end
end

function SimPlayerMenuComponent:handleObjectMenuSelect(pSceneObject, pPlayer, selectedID)
	if pSceneObject == nil or pPlayer == nil then
		return 0
	end
	local c = cfg()
	if c == nil then return 0 end
	local sim, st = simFor(pSceneObject)
	if sim == nil then return 0 end
	local sel = tonumber(selectedID)

	pcall(function()
		if sel == c.RADIAL_ASK or sel == c.RADIAL_ROOT then
			local f = fronts()
			say(pSceneObject, SimVoice.askWar(sim, {
				front = (f[1] ~= nil) and regionName(f[1].id) or "",
				here = regionName(st.region),
				here_supply = regionSupply(st.region),
				rank = SimPlayers.rankTitle(sim, st.rank or 1),
				salt = math.floor(now() / 60000),
			}))
		elseif sel == c.RADIAL_WHERE then
			say(pSceneObject, SimVoice.where(sim, {
				state = st.state, here = regionName(st.region),
				dest = (st.state == "travel") and regionName(st.dest) or "",
			}))
		elseif sel == c.RADIAL_RECRUIT then
			local me = SceneObject(pPlayer):getObjectID()
			if st.state == "escort" and st.escort == me then
				local idx = 1
				for i, s in ipairs(c.ROSTER) do if s.id == sim.id then idx = i end end
				endEscort(sim, st, idx, pSceneObject, SimVoice.escortDismiss(sim, {}))
			elseif st.state == "escort" then
				say(pSceneObject, "I'm already with someone.")
			else
				SimPlayers.recruit(sim, st, pSceneObject, pPlayer)
			end
		end
	end)
	return 0
end

-- ===================================================== include-time kick ==
-- Schedules only (CLAUDE.md rule). One thread per reload wins the gate.
pcall(function()
	local last = readSharedMemory(SimPlayers.KICK_KEY) or 0
	local t = getTimestampMilli()
	if last == 0 or (t - last) >= SimPlayers.KICK_GAP_MS then
		writeSharedMemory(SimPlayers.KICK_KEY, t)
		createEvent(3000, "SimPlayers", "kick", nil, "")
	end
end)
