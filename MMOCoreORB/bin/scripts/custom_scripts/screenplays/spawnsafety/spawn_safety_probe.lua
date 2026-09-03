--[[
  custom_scripts/screenplays/spawnsafety/spawn_safety_probe.lua

  B21 spawn-placement safety audit.

  WHY THIS EXISTS
  ---------------
  Nothing today answers "is this world coordinate safe to spawn a walking NPC
  on" -- CreatureManagerImplementation::placeCreature sets position blindly
  (no floor snap, no collision check, no rejection) and
  AiAgentImplementation::findNextPosition just returns false, silently,
  forever, when pathing fails. war_battle.lua stages up to 48 NPCs/cycle on a
  circle around each town centre with NO terrain awareness at all, and
  street_life.lua works around the whole problem by only ever using
  coordinates a human already hand-vetted in each city's own
  screenplays/cities/*.lua -- which is exactly why naboo_keren.lua (no
  stationaryMobiles/patrolPoints table at all) gets no ambient life: there is
  no vetted coordinate to hand it.

  This is an OFFLINE, READ-ONLY audit. It spawns nothing, writes nothing, and
  changes no game state -- it only calls the new isPointWalkable(zoneName, x,
  z, y) DirectorManager Lua binding (server/zone/managers/director/
  DirectorManager.cpp), which in turn calls the new
  PathFinderManager::isPointOnNavMesh() (server/zone/managers/collision/
  PathFinderManager.cpp), for every coordinate below and prints PASS/FAIL
  plus the distance to the nearest walkable point.

  WHAT IT CHECKS
  --------------
  1. Each war region's WarReport.COORDS town centre (from war_report.lua).
  2. The SAME site circle war_battle.lua actually stages fights on --
     reproduced here from war_battle.lua's siteRadiusFor()/siteOrigin()
     (BATTLE_OFFSET_M, SITE_RADIUS_FRACTION/MIN/MAX, DEFAULT_TOWN_RADIUS,
     MAX_SITES_PER_REGION -- copied as of the 2026-09-02 rewrite; if those
     constants change in war_battle.lua this audit goes stale and should be
     re-synced) -- NOT an approximation of it. war_battle.lua itself is not
     touched or called.
  3. Every stationaryMobiles / patrolPoints coordinate in the 13
     war-mapped cities' screenplays/cities/*.lua -- the exact tables
     street_life.lua trusts by inheritance today, with no verification at
     all.
  4. naboo_keren.lua's `mobiles` table, filtered to cell == 0 (open-world,
     not cell-relative) rows -- the free, zero-risk candidates for finally
     giving Keren ambient life. Does NOT edit naboo_keren.lua or
     street_life.lua; this only produces the verified coordinate list a
     follow-up change would need.
  5. POPULATION_AID_POSTS and POPULATION_CANTINAS (custom_scripts/
     screenplays/population/population_config.lua) -- the medic/performer
     standing-service sites. These are hand-picked, human-authored
     coordinates that no tool has ever verified, same as #3/#4 above, and
     they are read live (not hardcoded here), so this check reflects
     whatever population_config.lua the running server actually has loaded
     -- including tat_anchorhead's POPULATION_CANTINAS row (owner ruling,
     2026-09-03, commit 80a8656fe5: co-located with the medic's own aid
     post at +4m x, z inherited UNCHANGED from the unoffset point and never
     floor-snapped -- exactly the kind of row this check exists to catch).
     Rows with a non-zero `cell` are interior and are explicitly SKIPPED,
     not tested -- same caveat as #3/#4's cell-relative rows.

  A row whose x/y falls inside a building interior (cell ~= 0, e.g.
  mobiles rows like {x=60, y=0.6, cell=1106372}) is skipped, not tested --
  those coordinates are cell-relative, not world coordinates, and testing
  them against the OUTDOOR navmesh would be meaningless (see war_report.lua's
  own COORDS header for the same caveat).

  RUN
  ---
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff \x27test spawnSafetyAudit\n\x27"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep SPAWNAUDIT ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -400"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports "No Sockets found" even on a healthy
  server (see CLAUDE.md's known traps).

  This audit has NOT been run yet -- isPointWalkable requires a rebuilt,
  restarted server, and this change does neither (build-only, no restart, no
  deploy; see the C++ side's header comments). Do not treat any numbers in
  this file's comments as audit results; there are none yet.
]]

-- ============================================================ region map ==

-- Maps each WarReport.COORDS / KILL_BOUNDS id to the city screenplay global
-- table that owns its stationaryMobiles/patrolPoints/mobiles rows, and the
-- zone (planet) name isPointWalkable/getWorldFloor need. All 13 are the
-- war-mapped cities per war_report.lua's WarReport.COORDS table.
local SPAWNSAFETY_REGIONS = {
	{ id = "tat_anchorhead",  planet = "tatooine", screenplay = "TatooineAnchorheadScreenPlay" },
	{ id = "tat_bestine",     planet = "tatooine", screenplay = "TatooineBestineScreenPlay" },
	{ id = "tat_mos_eisley",  planet = "tatooine", screenplay = "TatooineMosEisleyScreenPlay" },
	{ id = "tat_mos_espa",    planet = "tatooine", screenplay = "TatooineMosEspaScreenPlay" },

	{ id = "cor_bela_vistal", planet = "corellia",  screenplay = "CorelliaBelaVistalScreenPlay" },
	{ id = "cor_coronet",     planet = "corellia",  screenplay = "CorelliaCoronetScreenPlay" },
	{ id = "cor_tyrena",      planet = "corellia",  screenplay = "CorelliaTyrenaScreenPlay" },
	{ id = "cor_kor_vella",   planet = "corellia",  screenplay = "CorelliaKorVellaScreenPlay" },
	{ id = "cor_doaba",       planet = "corellia",  screenplay = "CorelliaDoabaGuerfelScreenPlay" },

	{ id = "nab_kaadara",     planet = "naboo", screenplay = "NabooKaadaraScreenPlay" },
	-- naboo_keren.lua has NO stationaryMobiles/patrolMobiles/patrolPoints table
	-- at all -- confirmed by direct grep of screenplays/cities/naboo_keren.lua.
	-- That is the whole reason Keren gets no street_life ambient population.
	-- Its `mobiles` table is audited separately below (see KEREN section).
	{ id = "nab_keren",       planet = "naboo", screenplay = "NabooKerenScreenPlay" },
	{ id = "nab_moenia",      planet = "naboo", screenplay = "NabooMoeniaScreenPlay" },
	{ id = "nab_theed",       planet = "naboo", screenplay = "NabooTheedScreenPlay" },
}

-- ============================================================ war_battle ==
-- Reproduced from custom_scripts/screenplays/warreport/war_battle.lua
-- (siteRadiusFor/siteOrigin/townRadius, as of the 2026-09-02 rewrite).
-- war_battle.lua is READ ONLY by this file -- these are copies of its
-- constants and formulas, not calls into it (its site-math helpers are
-- `local`, not reachable from outside that file).

local SPAWNSAFETY_BATTLE_OFFSET_M = 80          -- WarBattle.BATTLE_OFFSET_M
local SPAWNSAFETY_SITE_RADIUS_FRACTION = 0.4    -- WarBattle.SITE_RADIUS_FRACTION
local SPAWNSAFETY_SITE_RADIUS_MIN = 40          -- WarBattle.SITE_RADIUS_MIN
local SPAWNSAFETY_SITE_RADIUS_MAX = 130         -- WarBattle.SITE_RADIUS_MAX
local SPAWNSAFETY_DEFAULT_TOWN_RADIUS = 150     -- WarBattle.DEFAULT_TOWN_RADIUS
local SPAWNSAFETY_MAX_SITES_PER_REGION = 4      -- WarBattle.MAX_SITES_PER_REGION

-- Mirrors war_battle.lua's local townRadius(regionId).
local function spawnsafetyTownRadius(regionId)
	local bounds = WarReport.KILL_BOUNDS and WarReport.KILL_BOUNDS[regionId]
	if bounds == nil then
		return SPAWNSAFETY_DEFAULT_TOWN_RADIUS
	end
	if bounds.kind == "circle" and type(bounds.radius) == "number" then
		return bounds.radius
	end
	if bounds.kind == "rect" then
		local halfW = math.abs(bounds.x2 - bounds.x1) / 2
		local halfH = math.abs(bounds.y2 - bounds.y1) / 2
		return math.min(halfW, halfH)
	end
	return SPAWNSAFETY_DEFAULT_TOWN_RADIUS
end

-- Mirrors war_battle.lua's local siteRadiusFor(regionId).
local function spawnsafetySiteRadiusFor(regionId)
	local r = spawnsafetyTownRadius(regionId) * SPAWNSAFETY_SITE_RADIUS_FRACTION
	if r < SPAWNSAFETY_SITE_RADIUS_MIN then
		r = SPAWNSAFETY_SITE_RADIUS_MIN
	elseif r > SPAWNSAFETY_SITE_RADIUS_MAX then
		r = SPAWNSAFETY_SITE_RADIUS_MAX
	end
	return r
end

--- Every world (x, y) war_battle.lua can actually place a site's origin at
-- for this region: the legacy recruiter-anchor diagonal, plus the circle
-- point at every bearing siteOrigin() can produce across every totalSites
-- value from 1 to SPAWNSAFETY_MAX_SITES_PER_REGION (the radius does not
-- depend on totalSites, only the bearing spacing does -- see war_battle.lua's
-- siteOrigin()). Returns a list of {label, x, y}.
local function spawnsafetyBattleSites(regionId, coords)
	local sites = {}

	sites[#sites + 1] = {
		label = "recruiter-anchor",
		x = coords[1] + SPAWNSAFETY_BATTLE_OFFSET_M,
		y = coords[2] + SPAWNSAFETY_BATTLE_OFFSET_M,
	}

	local radius = spawnsafetySiteRadiusFor(regionId)
	local seenDegrees = {}

	for totalSites = 1, SPAWNSAFETY_MAX_SITES_PER_REGION do
		for siteIndex = 1, totalSites do
			local degrees = 45 + (siteIndex - 1) * (360 / totalSites)
			local key = math.floor(degrees * 1000 + 0.5)
			if not seenDegrees[key] then
				seenDegrees[key] = true
				local rad = degrees * math.pi / 180
				sites[#sites + 1] = {
					label = "circle@" .. string.format("%.1f", degrees) .. "deg",
					x = coords[1] + radius * math.cos(rad),
					y = coords[2] + radius * math.sin(rad),
				}
			end
		end
	end

	return sites
end

-- ================================================================ shared ==

local spawnsafetyPass = 0
local spawnsafetyFail = 0
local spawnsafetySkip = 0

--- Checks one world point and prints a PASS/FAIL/SKIP line. z == nil means
-- "look up the ground floor height for (x, y) instead of trusting an
-- authored value" -- used for computed points (town centres, battle sites),
-- never for hand-authored city rows, which already carry their own z.
local function spawnsafetyCheck(label, planet, x, z, y)
	if type(isPointWalkable) ~= "function" then
		printf("SPAWNAUDIT: FATAL -- isPointWalkable is not registered in this Lua VM (build not deployed yet?)\n")
		return false
	end

	if z == nil then
		if type(getWorldFloor) == "function" then
			z = getWorldFloor(x, y, planet)
		else
			z = 0
		end
	end

	local ok, walkable, distance = pcall(isPointWalkable, planet, x, z, y)

	if not ok then
		spawnsafetyFail = spawnsafetyFail + 1
		printf(string.format("SPAWNAUDIT: FAIL  %-28s %-10s x=%9.2f z=%8.2f y=%9.2f ERROR %s\n",
			label, planet, x, z, y, tostring(walkable)))
		return false
	end

	if walkable then
		spawnsafetyPass = spawnsafetyPass + 1
		printf(string.format("SPAWNAUDIT: PASS  %-28s %-10s x=%9.2f z=%8.2f y=%9.2f dist=%.3f\n",
			label, planet, x, z, y, distance or -1))
	else
		spawnsafetyFail = spawnsafetyFail + 1
		printf(string.format("SPAWNAUDIT: FAIL  %-28s %-10s x=%9.2f z=%8.2f y=%9.2f dist=%.3f\n",
			label, planet, x, z, y, distance or -1))
	end

	return walkable
end

-- ============================================================== per-city ==

--- Audits one city screenplay's stationaryMobiles and patrolPoints rows,
-- skipping any row whose cell is not 0 (0 == open world; anything else is a
-- cell-relative interior coordinate street_life.lua would never use as a
-- world point either -- see this file's header).
local function spawnsafetyAuditCity(regionEntry)
	local sp = _G[regionEntry.screenplay]

	if sp == nil then
		printf("SPAWNAUDIT: SKIP  city screenplay " .. regionEntry.screenplay .. " not loaded in this VM\n")
		spawnsafetySkip = spawnsafetySkip + 1
		return
	end

	-- stationaryMobiles row shape: {respawn, x, z, y, direction, cell, mood}
	if type(sp.stationaryMobiles) == "table" then
		for i = 1, #sp.stationaryMobiles do
			local row = sp.stationaryMobiles[i]
			local cell = row[6]
			if cell == 0 or cell == nil then
				spawnsafetyCheck(regionEntry.id .. " stationaryMobiles[" .. i .. "]", regionEntry.planet, row[2], row[3], row[4])
			else
				spawnsafetySkip = spawnsafetySkip + 1
			end
		end
	end

	-- patrolPoints shape: routeName -> { {x, z, y, cell, delayAtNextPoint}, ... }
	if type(sp.patrolPoints) == "table" then
		for routeName, route in pairs(sp.patrolPoints) do
			if type(route) == "table" then
				for i = 1, #route do
					local pt = route[i]
					local cell = pt[4]
					if cell == 0 or cell == nil then
						spawnsafetyCheck(regionEntry.id .. " patrolPoints." .. tostring(routeName) .. "[" .. i .. "]", regionEntry.planet, pt[1], pt[2], pt[3])
					else
						spawnsafetySkip = spawnsafetySkip + 1
					end
				end
			end
		end
	end
end

-- =============================================================== keren ====

--- naboo_keren.lua has no stationaryMobiles/patrolMobiles/patrolPoints table
-- (confirmed by grep -- this is WHY Keren gets no ambient street life today),
-- but it DOES have a `mobiles` table where stock Core3 already spawns real
-- NPCs, including open-world (cell == 0) rows. Those are free, zero-risk
-- candidates for finally giving Keren ambient life -- this audits exactly
-- those rows and nothing else. Does NOT edit naboo_keren.lua.
-- mobiles row shape: {template, respawn, x, z, y, direction, cell, mood}
local function spawnsafetyAuditKeren()
	local sp = NabooKerenScreenPlay

	if sp == nil then
		printf("SPAWNAUDIT: SKIP  NabooKerenScreenPlay not loaded in this VM\n")
		spawnsafetySkip = spawnsafetySkip + 1
		return
	end

	if type(sp.mobiles) ~= "table" then
		printf("SPAWNAUDIT: SKIP  NabooKerenScreenPlay.mobiles missing\n")
		return
	end

	for i = 1, #sp.mobiles do
		local row = sp.mobiles[i]
		local cell = row[7]
		if cell == 0 or cell == nil then
			spawnsafetyCheck("nab_keren mobiles[" .. i .. "] (" .. tostring(row[1]) .. ")", "naboo", row[3], row[4], row[5])
		else
			spawnsafetySkip = spawnsafetySkip + 1
		end
	end
end

-- ===================================================== population sites ===

--- Audits one POPULATION_AID_POSTS/POPULATION_CANTINAS-shaped table: a map
-- of regionId -> { zone, x, z, y, heading, cell }. Rows with a non-zero
-- `cell` are interior coordinates (12 of 13 POPULATION_CANTINAS rows) --
-- testing those against the outdoor navmesh would be meaningless and would
-- read as a false FAIL, so they are explicitly SKIPPED with a line saying
-- so, never silently dropped and never tested. Defensive by design: this
-- is read from a sibling in-flight file this probe does not own, so a nil
-- global, a non-table global, or a malformed row must degrade to a clean
-- SKIP line, never a Lua error.
local function spawnsafetyAuditPopulationTable(tableName, tbl)
	if type(tbl) ~= "table" then
		printf("SPAWNAUDIT: SKIP  " .. tableName .. " is nil or not a table (population_config.lua not loaded on this thread?)\n")
		spawnsafetySkip = spawnsafetySkip + 1
		return
	end

	for regionId, row in pairs(tbl) do
		if type(row) ~= "table" then
			printf("SPAWNAUDIT: SKIP  " .. tableName .. "." .. tostring(regionId) .. " is not a table row\n")
			spawnsafetySkip = spawnsafetySkip + 1
		elseif row.cell ~= nil and row.cell ~= 0 then
			printf("SPAWNAUDIT: SKIP  " .. tableName .. "." .. tostring(regionId)
				.. " cell=" .. tostring(row.cell) .. " (interior coordinate -- outdoor navmesh check would be meaningless)\n")
			spawnsafetySkip = spawnsafetySkip + 1
		elseif type(row.x) ~= "number" or type(row.z) ~= "number" or type(row.y) ~= "number" or type(row.zone) ~= "string" then
			printf("SPAWNAUDIT: SKIP  " .. tableName .. "." .. tostring(regionId) .. " missing/non-numeric zone/x/z/y\n")
			spawnsafetySkip = spawnsafetySkip + 1
		else
			spawnsafetyCheck(tableName .. "." .. tostring(regionId), row.zone, row.x, row.z, row.y)
		end
	end
end

-- ================================================================= main ===

function Tests:spawnSafetyAudit()
	printf("SPAWNAUDIT: begin (B21 spawn-placement safety check)\n")

	if WarReport == nil or WarReport.COORDS == nil then
		printf("SPAWNAUDIT: FATAL -- WarReport.COORDS not available on this thread\n")
		return
	end

	spawnsafetyPass, spawnsafetyFail, spawnsafetySkip = 0, 0, 0

	for i = 1, #SPAWNSAFETY_REGIONS do
		local region = SPAWNSAFETY_REGIONS[i]
		local coords = WarReport.COORDS[region.id]

		if coords == nil then
			printf("SPAWNAUDIT: SKIP  " .. region.id .. " has no WarReport.COORDS entry\n")
		else
			-- 1. Town centre.
			spawnsafetyCheck(region.id .. " town-centre", region.planet, coords[1], nil, coords[2])

			-- 2. The real war_battle.lua site circle (reproduced, not approximated).
			local sites = spawnsafetyBattleSites(region.id, coords)
			for s = 1, #sites do
				spawnsafetyCheck(region.id .. " " .. sites[s].label, region.planet, sites[s].x, nil, sites[s].y)
			end
		end

		-- 3. This city's own street_life-trusted stationaryMobiles/patrolPoints.
		spawnsafetyAuditCity(region)
	end

	-- 4. Keren's open-world mobiles rows -- the payoff (see header/spawnsafetyAuditKeren).
	spawnsafetyAuditKeren()

	-- 5. Population service sites (medic aid posts, performer cantinas) --
	-- hand-picked, never verified, read live from population_config.lua.
	spawnsafetyAuditPopulationTable("POPULATION_AID_POSTS", POPULATION_AID_POSTS)
	spawnsafetyAuditPopulationTable("POPULATION_CANTINAS", POPULATION_CANTINAS)

	printf(string.format("SPAWNAUDIT: end -- pass=%d fail=%d skip=%d\n", spawnsafetyPass, spawnsafetyFail, spawnsafetySkip))
end
