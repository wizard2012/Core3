--[[
  custom_scripts/screenplays/warreport/war_space.lua

  B61 S1 -- THE SKY BATTLE (docs/DESIGN-SPACE.md section 3, DECISIONS D28,
  owner rulings 2026-09-08). The war's orbits are regions (S0); this file is
  what happens in the space zone above each war planet:

    * PICKET  -- the orbit's holder keeps a wing (a leader and three fighters)
                 on guard patrol near the planet's launch point, where every
                 player arrives. Refilled every cycle while the holder holds.
    * ATTACK  -- when the sim exports the orbit as a front, the attacker's
                 wings (one below intensity TWO_WINGS_AT, two at or above;
                 a bomber in each) arrive from further out and are sent at
                 the picket. Kept up while the front stands; gone when it
                 closes or the season ends.
    * REPORTS -- every cycle the rosters are swept: a ship that is gone or
                 reads destroyed is a body (`casualty` for its side at the
                 orbit, one per hull); a wing wiped since the last sweep is a
                 lost line (`site_lost`). These are the SAME rows the ground
                 files (war_battle.lua), so the sim's one flip rule -- a dry
                 holder whose line was wiped -- decides the sky exactly as it
                 decides a town. A player who destroys a war ship records
                 npc_kill_faction at the orbit (rank; it forces the front).

  Runs on the ground's cadence (CYCLE_MS) from one event chain. Include time
  only SCHEDULES, gated in shared memory, because every thread re-runs the
  include chain after a reload (CLAUDE.md, "never spawn at include time").
  Ship AI runs with nobody nearby and NPC ships attack any ship whose faction
  is on their template's enemy list, so the fight happens whether or not a
  player is in the zone (owner ruling: always on, like the ground).

  Rosters live in shared string data, one per orbit and role:
    warspace:picket:<orbit>  ->  "<side>|<oid>,<oid>,..."
    warspace:attack:<orbit>  ->  "<side>|<oid>,<oid>,..."
  and every spawned hull carries "<oid>:warspace" -> "<orbit>|<side>" for
  the destruction observer. All of it is process memory: a restart starts
  clean, so nothing is ever counted twice across boots.

  Console: test warSpaceCheck (read-only), test warSpaceCycleNow (one cycle).
]]

WarSpace = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "WarSpace",
}

registerScreenPlay("WarSpace", true)

WarSpace.CYCLE_MS      = 5 * 60 * 1000  -- the ground's reconcile cadence
WarSpace.FIRST_MS      = 90 * 1000      -- after WarBattle's first cycle (45 s)
WarSpace.PICKET_SIZE   = 4              -- a leader and three fighters
WarSpace.WING_SIZE     = 4              -- a leader, two fighters, a bomber
WarSpace.TWO_WINGS_AT  = 0.5            -- front intensity that brings a second wing
WarSpace.MAX_SHIPS     = 12             -- hard cap per orbit, picket included
WarSpace.KILL_POINTS   = 0.5            -- a hull is worth a few troopers (npc_kill_faction is 0.15 a body)
WarSpace.GUARD_MIN     = 300
WarSpace.GUARD_MAX     = 1200

WarSpace.PICKET_KEY    = "warspace:picket:"
WarSpace.ATTACK_KEY    = "warspace:attack:"
WarSpace.SCHEDULED_KEY = "warspace:scheduled"
WarSpace.LAST_KEY      = "warspace:last_ms"
WarSpace.CYCLE_KEY     = "warspace:cycle"

-- The sky over each war planet. `picket` sits about 1.8 km from the stock
-- station at the planet's launch point (a ship spawned on the station would
-- start inside its no-fly volume); `attack` is another 3 km out along the
-- same bearing, so a fight begins on approach. All inside the zone's
-- +-7680 bounds. Axis order is Core3's x, z, y.
WarSpace.ORBITS = {
	cor_orbit = { zone = "space_corellia", planet = "corellia",
		picket = { x = 5020, z = -5000, y = -1700 }, attack = { x = 2520, z = -4400, y = -200 } },
	nab_orbit = { zone = "space_naboo", planet = "naboo",
		picket = { x = -1000, z = 1300, y = -5600 }, attack = { x = 1500, z = 1900, y = -4100 } },
	tat_orbit = { zone = "space_tatooine", planet = "tatooine",
		picket = { x = 800, z = -5500, y = 1000 }, attack = { x = -1700, z = -4900, y = -500 } },
}

-- Stock ship-agent templates (bin/scripts/ship_mobile/ships/). Tier 1-2:
-- a picket a new pilot in a starter fighter can fight, not a wall.
WarSpace.WINGS = {
	imperial = { leader = "imp_tie_interceptor_tier2", fighter = "imp_tie_fighter_tier1", bomber = "imp_tie_bomber_tier1" },
	rebel    = { leader = "reb_awing_tier2",           fighter = "reb_xwing_tier1",       bomber = "reb_ywing_tier1" },
}

-- Deterministic scatter around a point, one entry per slot (metres).
WarSpace.SCATTER = {
	{ 0, 0, 0 }, { 180, 40, -120 }, { -160, -30, 150 }, { 90, 120, 200 },
	{ -220, 60, -80 }, { 140, -110, -210 }, { -60, 150, 230 }, { 240, -70, 60 },
	{ -240, -140, -40 }, { 60, 200, -180 }, { 200, 90, 170 }, { -120, -190, 110 },
}

function WarSpace.orbitIds()
	local ids = {}
	for id, _ in pairs(WarSpace.ORBITS) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

function WarSpace.planetName(orbitId)
	local cfg = WarSpace.ORBITS[orbitId]
	local planet = cfg and cfg.planet or nil
	if WarReport ~= nil and WarReport.planetName ~= nil and planet ~= nil then
		return WarReport.planetName(planet)
	end
	return tostring(planet)
end

-- ------------------------------------------------------------- rosters --

--- Read a roster and sweep it: returns side, the live oids (in order) and
-- how many hulls are gone or destroyed since it was written. A destroyed
-- hull that still stands is removed from the world here, one sweep late,
-- so the zone does not fill with wrecks.
function WarSpace.sweep(key)
	local raw = readStringData(key)
	if raw == nil or raw == "" then
		return nil, {}, 0
	end
	local side, list = string.match(raw, "^([a-z]+)|(.*)$")
	if side == nil then
		return nil, {}, 0
	end
	local alive, dead = {}, 0
	for tok in string.gmatch(list, "([^,]+)") do
		local oid = tonumber(tok)
		if oid ~= nil then
			local p = getSceneObject(oid)
			local gone = (p == nil)
			if not gone then
				local ok, destroyed = pcall(function() return ShipObject(p):isShipDestroyed() end)
				if ok and destroyed then
					gone = true
					pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
				end
			end
			if gone then
				dead = dead + 1
			else
				alive[#alive + 1] = oid
			end
		end
	end
	return side, alive, dead
end

function WarSpace.save(key, side, oids)
	if side == nil or #oids == 0 then
		writeStringData(key, "")
		return
	end
	local parts = {}
	for i = 1, #oids do parts[i] = tostring(oids[i]) end
	writeStringData(key, side .. "|" .. table.concat(parts, ","))
end

function WarSpace.despawnAll(oids)
	for i = 1, #oids do
		local p = getSceneObject(oids[i])
		if p ~= nil then
			pcall(function() dropObserver(SHIPDESTROYED, "WarSpace", "onShipDestroyed", p) end)
			pcall(function() deleteStringData(tostring(oids[i]) .. ":warspace") end)
			pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
		end
	end
end

-- ------------------------------------------------------------- spawning --

--- Spawn `count` hulls of `side` at `point` for `role` ("picket" or
-- "attack"), slots continuing from `startIndex`. Returns the oids spawned.
function WarSpace.spawnWing(orbitId, cfg, side, point, count, role, startIndex)
	local wing = WarSpace.WINGS[side]
	local out = {}
	if wing == nil or point == nil or count <= 0 then
		return out
	end
	for i = 1, count do
		local slot = startIndex + i
		local template = wing.fighter
		if slot == 1 then
			template = wing.leader
		elseif role == "attack" and slot % WarSpace.WING_SIZE == 0 then
			template = wing.bomber
		end
		local off = WarSpace.SCATTER[((slot - 1) % #WarSpace.SCATTER) + 1]
		local p = spawnShipAgent(template, cfg.zone, point.x + off[1], point.z + off[2], point.y + off[3])
		if p == nil then
			printf("WarSpace: spawnShipAgent failed for " .. tostring(template) .. " in " .. tostring(cfg.zone) .. "\n")
		else
			local oid = SceneObject(p):getObjectID()
			out[#out + 1] = oid
			writeStringData(tostring(oid) .. ":warspace", orbitId .. "|" .. side)
			pcall(function() ShipAiAgent(p):setDespawnOnNoPlayerInRange(false) end)
			createObserver(SHIPDESTROYED, "WarSpace", "onShipDestroyed", p)
			if role == "picket" then
				pcall(function()
					ShipAiAgent(p):setMinimumGuardPatrol(WarSpace.GUARD_MIN)
					ShipAiAgent(p):setMaximumGuardPatrol(WarSpace.GUARD_MAX)
					ShipAiAgent(p):setGuardPatrol()
				end)
			else
				pcall(function() ShipAiAgent(p):setRandomPatrol() end)
			end
		end
	end
	return out
end

--- Send every attacker at a picket hull (round-robin), so the fight starts
-- without waiting for the AI to notice each other.
function WarSpace.engage(attackers, picket)
	if #picket == 0 then
		return
	end
	for i = 1, #attackers do
		local pA = getSceneObject(attackers[i])
		local pT = getSceneObject(picket[((i - 1) % #picket) + 1])
		if pA ~= nil and pT ~= nil then
			pcall(function() ShipAiAgent(pA):engageShipTarget(pT) end)
		end
	end
end

-- -------------------------------------------------------------- reports --

local function bump(counts, orbitId, side, n)
	if side == nil or n == nil or n <= 0 then return end
	local k = orbitId .. "|" .. side
	counts[k] = (counts[k] or 0) + n
end

--- The ground's report call, verbatim in shape (war_battle.lua's
-- WarBattle.report): one WarContrib.record per (orbit, side), no character.
function WarSpace.report(counts, source)
	if WarContrib == nil or WarContrib.record == nil then
		return
	end
	local keys = {}
	for k, n in pairs(counts) do
		if n and n > 0 then keys[#keys + 1] = k end
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local region, faction = string.match(k, "^([^|]+)|(.+)$")
		if region ~= nil and faction ~= nil then
			local ok, recorded, why = pcall(WarContrib.record, faction, region, source, counts[k], nil)
			if ok and recorded then
				printf(string.format("WarSpace: %s %s at %s x%d -- recorded\n", tostring(faction), tostring(source), tostring(region), counts[k]))
			else
				printf(string.format("WarSpace: %s %s at %s NOT recorded: %s\n", tostring(faction), tostring(source), tostring(region), tostring(why or recorded)))
			end
		end
	end
end

-- ---------------------------------------------------------------- cycle --

--- One orbit: sweep both rosters, file the bodies, then restage the picket
-- for the holder and the attack wings for the exported front.
function WarSpace.reconcileOrbit(orbitId, o, cfg, seasonOver, casualties, lost)
	local holder = (o.faction == "imperial" or o.faction == "rebel") and o.faction or nil

	local pside, palive, pdead = WarSpace.sweep(WarSpace.PICKET_KEY .. orbitId)
	if pside ~= nil and pdead > 0 then
		bump(casualties, orbitId, pside, pdead)
		if #palive == 0 then bump(lost, orbitId, pside, 1) end
	end
	local aside, aalive, adead = WarSpace.sweep(WarSpace.ATTACK_KEY .. orbitId)
	if aside ~= nil and adead > 0 then
		bump(casualties, orbitId, aside, adead)
		if #aalive == 0 then bump(lost, orbitId, aside, 1) end
	end

	-- the picket follows the holder
	if pside ~= nil and pside ~= holder then
		WarSpace.despawnAll(palive)
		palive, pside = {}, nil
	end
	if holder ~= nil and #palive < WarSpace.PICKET_SIZE then
		local spawned = WarSpace.spawnWing(orbitId, cfg, holder, cfg.picket, WarSpace.PICKET_SIZE - #palive, "picket", #palive)
		for i = 1, #spawned do palive[#palive + 1] = spawned[i] end
		pside = (#palive > 0) and holder or nil
	end
	WarSpace.save(WarSpace.PICKET_KEY .. orbitId, pside, palive)

	-- the attackers follow the front
	local front = (not seasonOver) and type(o.front) == "table" and o.front or nil
	local attacker = front and front.attacker or nil
	if attacker ~= "imperial" and attacker ~= "rebel" then attacker = nil end
	if attacker ~= nil and attacker == holder then attacker = nil end  -- a stale front
	if attacker == nil or (aside ~= nil and aside ~= attacker) then
		WarSpace.despawnAll(aalive)
		aalive, aside = {}, nil
	end
	local intensity = front and (tonumber(front.intensity) or 0) or 0
	if attacker ~= nil then
		local wings = (intensity >= WarSpace.TWO_WINGS_AT) and 2 or 1
		local want = wings * WarSpace.WING_SIZE
		local room = WarSpace.MAX_SHIPS - #palive
		if want > room then want = room end
		if #aalive < want then
			local spawned = WarSpace.spawnWing(orbitId, cfg, attacker, cfg.attack, want - #aalive, "attack", #aalive)
			for i = 1, #spawned do aalive[#aalive + 1] = spawned[i] end
		end
		aside = (#aalive > 0) and attacker or nil
		WarSpace.engage(aalive, palive)
	end
	WarSpace.save(WarSpace.ATTACK_KEY .. orbitId, aside, aalive)

	printf(string.format("WarSpace: %s -- %s holds the sky, picket %d/%d (%d lost); %s\n",
		orbitId, tostring(holder), #palive, WarSpace.PICKET_SIZE, pdead,
		attacker and string.format("%s attacking at %.2f with %d hull(s) (%d lost)", attacker, intensity, #aalive, adead)
			or "no attack"))
end

function WarSpace.runCycle()
	local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	if st == nil or type(st.orbits) ~= "table" then
		printf("WarSpace: no orbits in the war state (S0 export missing?)\n")
		return
	end
	local seasonOver = type(st.season) == "table" and st.season.winner ~= nil and st.season.winner ~= ""
	writeData(WarSpace.CYCLE_KEY, (readData(WarSpace.CYCLE_KEY) or 0) + 1)
	local casualties, lost = {}, {}
	for _, id in ipairs(WarSpace.orbitIds()) do
		local o = st.orbits[id]
		local cfg = WarSpace.ORBITS[id]
		if o ~= nil and cfg ~= nil and isZoneEnabled(cfg.zone) then
			local ok, err = pcall(function() WarSpace.reconcileOrbit(id, o, cfg, seasonOver, casualties, lost) end)
			if not ok then
				printf("WarSpace: " .. id .. " failed: " .. tostring(err) .. "\n")
			end
		end
	end
	WarSpace.report(casualties, "casualty")
	WarSpace.report(lost, "site_lost")
	writeData(WarSpace.LAST_KEY, getTimestampMilli())
end

function WarSpace:cycle(pNil, args)
	local ok, err = pcall(function() WarSpace.runCycle() end)
	if not ok then
		printf("WarSpace: cycle failed: " .. tostring(err) .. "\n")
	end
	createEvent(WarSpace.CYCLE_MS, "WarSpace", "cycle", nil, "")
end

--- Schedule the chain exactly once per boot, whoever includes this file.
function WarSpace.schedule()
	if (readData(WarSpace.SCHEDULED_KEY) or 0) == 1 then
		return false
	end
	writeData(WarSpace.SCHEDULED_KEY, 1)
	createEvent(WarSpace.FIRST_MS, "WarSpace", "cycle", nil, "")
	return true
end

function WarSpace:start()
	WarSpace.schedule()
end

-- --------------------------------------------------------- destruction --

--- SHIPDESTROYED on every hull we spawn. pKiller is the ship that fired
-- the killing shot; a player's ship has a pilot, an NPC's has none.
function WarSpace:onShipDestroyed(pShip, pKiller)
	if pShip == nil then
		return 1
	end
	local oid = SceneObject(pShip):getObjectID()
	local tag = readStringData(tostring(oid) .. ":warspace")
	pcall(function() deleteStringData(tostring(oid) .. ":warspace") end)
	if pKiller == nil or tag == nil or tag == "" then
		return 1
	end
	local orbitId, victimSide = string.match(tag, "^([a-z_]+)|([a-z]+)$")
	if orbitId == nil then
		return 1
	end
	local pPilot = nil
	pcall(function() pPilot = ShipObject(pKiller):getPilot() end)
	if pPilot == nil then
		return 1
	end
	pcall(function()
		if not CreatureObject(pPilot):isPlayerCreature() then
			return
		end
		local side = (WarStandings ~= nil and WarStandings.factionOf ~= nil) and WarStandings.factionOf(pPilot) or nil
		if side == nil or side == victimSide or WarContrib == nil or WarContrib.record == nil then
			return
		end
		WarContrib.record(side, orbitId, "npc_kill_faction", WarSpace.KILL_POINTS, CreatureObject(pPilot):getObjectID())
		CreatureObject(pPilot):sendSystemMessage("[War] Splash one over " .. WarSpace.planetName(orbitId) .. ". Your side will hear of it.")
	end)
	return 1
end

-- Include time: schedule only (gated), never spawn.
pcall(function() WarSpace.schedule() end)
