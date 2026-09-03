--[[
  custom_scripts/screenplays/warreport/war_battle_offset_sweep.lua

  Read-only console probe: sweeps candidate per-region SITE_OVERRIDES values
  (see war_battle.lua's SITE_OVERRIDES comment) against every point the game
  can actually stage a battle site on, across every contest tier, and
  reports which candidates come back fully clear of the navmesh audit.

  WHY THIS EXISTS
  ---------------
  war_battle.lua has four navmesh-audit failures to fix (recruiter-anchor
  and three circle sites, at nab_theed, cor_tyrena, tat_bestine). A circle
  site's radius is used at EVERY bearing sitesForContest() can produce for
  that region, and which bearing lands at a given siteIndex shifts as
  contest tier changes the site count -- so verifying a candidate radius
  only at the one bearing the original audit happened to sample would let
  the region silently regress the moment contest moves it into a different
  tier. This probe closes that gap: for each candidate, EVERY bearing the
  region could actually use must pass, not just one.

  This is an OFFLINE, READ-ONLY probe, same contract as
  spawnsafety/spawn_safety_probe.lua: it spawns nothing, writes nothing,
  changes no game state -- it only calls isPointWalkable(zone, x, z, y) and
  prints PASS/FAIL. z is looked up per point via getWorldFloor(x, y, zone),
  reused unchanged from spawn_safety_probe.lua's spawnsafetyCheck (its
  z == nil branch: "look up the ground floor height instead of trusting an
  authored value") rather than inventing a height rule of our own.

  WHAT IT CHECKS
  --------------
  For each of the four problem regions, the exact set of points
  war_battle.lua's siteOrigin() can actually produce is regenerated here
  from the real formula (45 + (siteIndex-1)*(360/totalSites), for every
  totalSites from 1 to WarBattle.MAX_SITES_PER_REGION -- read live off
  WarBattle, not a copied guess, since sitesForContest() only ever returns
  a value in that range) -- not narrowed to the one bearing named in the
  original failure report:

    - nab_theed: recruiter-anchor point, swept over ANCHOR_CANDIDATES.
    - nab_theed, cor_tyrena, tat_bestine: every circle bearing at every
      contest tier, swept over RADIUS_CANDIDATES.

  A candidate is reported ALL CLEAR for a region only if EVERY point it
  produces for that region passes isPointWalkable -- one failing bearing
  fails the whole candidate, even if every other bearing passed.

  This file does NOT decide which candidate to use and does NOT write to
  WarBattle.SITE_OVERRIDES -- it only produces the evidence a human uses to
  fill that table in. "No candidate came back ALL CLEAR for this region" is
  a real, useful result this probe can report, not a probe failure.

  RUN
  ---
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff \x27test battleOffsetSweep\n\x27"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep OFFSETSWEEP ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -400"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports "No Sockets found" even on a healthy
  server (see CLAUDE.md's known traps).

  This probe has NOT been run yet. Do not treat any candidate in this file
  as verified -- these are proposals to test, not results, until a human
  runs it against the live navmesh and reads the output.
]]

-- ======================================================= candidate lists ==

-- nab_theed recruiter-anchor: candidate {x, y} offset pairs to replace the
-- default (BATTLE_OFFSET_M, BATTLE_OFFSET_M) diagonal with. Reasoning (see
-- the battle-site-offset handoff report): smaller/larger symmetric
-- diagonals first (cheapest to reason about, keeps the existing "diagonal"
-- shape), then asymmetric pairs exploiting nab_theed's KILL_BOUNDS rect
-- being wide in x (halfW=840) and narrow in y (halfH=448), then the two
-- flipped-sign quadrants. nab_theed is the only region whose
-- recruiter-anchor failed the audit -- the other three failures are
-- circle sites, covered by RADIUS_CANDIDATES below instead.
local OFFSETSWEEP_ANCHOR_CANDIDATES = {
	nab_theed = {
		{ x = 60,  y = 60  },
		{ x = 70,  y = 70  },
		{ x = 90,  y = 90  },
		{ x = 100, y = 100 },
		{ x = 60,  y = 90  },
		{ x = 90,  y = 60  },
		{ x = -80, y = 80  },
		{ x = 80,  y = -80 },
	},
}

-- Candidate siteRadius overrides for the three regions whose circle sites
-- failed. All three failing points landed exactly on SITE_RADIUS_MAX=130
-- (see war_battle.lua's siteRadiusFor() -- every one of these regions'
-- computed radius clamps to the max), so pulling the radius in toward the
-- settled centre is the straightforward thing to try first.
local OFFSETSWEEP_RADIUS_CANDIDATES = {
	nab_theed   = { 90, 100, 110 },
	cor_tyrena  = { 90, 100, 110 },
	tat_bestine = { 90, 100, 110 },
}

-- ================================================================ points ==

--- Every circle-site (x, y) war_battle.lua's siteOrigin() could produce for
-- this region at the given radius, across every totalSites from 1 to
-- WarBattle.MAX_SITES_PER_REGION -- the live constant, so this can never
-- drift out of sync with what sitesForContest() actually returns. Mirrors
-- spawnsafety/spawn_safety_probe.lua's spawnsafetyBattleSites() dedup
-- approach (same bearing formula, same "skip a bearing already seen at a
-- smaller totalSites" dedup), reproduced here rather than called because
-- war_battle.lua's siteOrigin()/siteRadiusFor() are file-local (`local
-- function`), not reachable from outside that file.
local function offsetsweepCirclePoints(coords, radius)
	local points = {}
	local seenDegrees = {}
	local maxSites = (WarBattle ~= nil and WarBattle.MAX_SITES_PER_REGION) or 4

	for totalSites = 1, maxSites do
		for siteIndex = 1, totalSites do
			local degrees = 45 + (siteIndex - 1) * (360 / totalSites)
			local key = math.floor(degrees * 1000 + 0.5)
			if not seenDegrees[key] then
				seenDegrees[key] = true
				local rad = degrees * math.pi / 180
				points[#points + 1] = {
					label = string.format("circle@%.1fdeg", degrees),
					x = coords[1] + radius * math.cos(rad),
					y = coords[2] + radius * math.sin(rad),
				}
			end
		end
	end

	return points
end

-- ================================================================ checks ==

--- Checks one world point, prints a PASS/FAIL line, and returns whether it
-- passed. z is looked up via getWorldFloor(x, y, planet) -- the same
-- pattern spawn_safety_probe.lua's spawnsafetyCheck uses for computed
-- points (its z == nil branch), reused unchanged rather than inventing a
-- new height rule for this probe.
local function offsetsweepCheckPoint(label, planet, x, y)
	if type(isPointWalkable) ~= "function" then
		printf("OFFSETSWEEP: FATAL -- isPointWalkable is not registered in this Lua VM (build not deployed yet?)\n")
		return false
	end

	local z = 0
	if type(getWorldFloor) == "function" then
		z = getWorldFloor(x, y, planet)
	end

	local ok, walkable, distance = pcall(isPointWalkable, planet, x, z, y)

	if not ok then
		printf(string.format("OFFSETSWEEP:   FAIL %-20s x=%9.2f z=%8.2f y=%9.2f ERROR %s\n",
			label, x, z, y, tostring(walkable)))
		return false
	end

	printf(string.format("OFFSETSWEEP:   %s %-20s x=%9.2f z=%8.2f y=%9.2f dist=%.3f\n",
		walkable and "PASS" or "FAIL", label, x, z, y, distance or -1))

	return walkable and true or false
end

--- Checks every point a candidate produces for a region and returns true
-- only if ALL of them passed -- one failing bearing fails the candidate,
-- even if every other bearing for it passed.
local function offsetsweepCheckCandidate(regionId, planet, candidateLabel, points)
	local allPass = true
	for i = 1, #points do
		local pass = offsetsweepCheckPoint(
			regionId .. " " .. candidateLabel .. " " .. points[i].label,
			planet, points[i].x, points[i].y)
		if not pass then
			allPass = false
		end
	end
	printf(string.format("OFFSETSWEEP: candidate %s / %-14s -- %s (%d point(s) checked)\n",
		regionId, candidateLabel,
		allPass and "ALL CLEAR" or "FAIL (at least one bearing off navmesh)",
		#points))
	return allPass
end

-- =================================================================== main ==

function Tests:battleOffsetSweep()
	printf("OFFSETSWEEP: begin (candidate SITE_OVERRIDES sweep for off-navmesh battle sites)\n")

	if WarReport == nil or WarReport.COORDS == nil or WarReport.PLANET_OF == nil then
		printf("OFFSETSWEEP: FATAL -- WarReport.COORDS/PLANET_OF not available on this thread\n")
		return
	end
	if WarBattle == nil then
		printf("OFFSETSWEEP: FATAL -- WarBattle not available on this thread\n")
		return
	end

	-- regionId -> { anchor = {{label, pass}, ...}, radius = {{label, pass}, ...} }
	local summary = {}
	local function ensureSummary(regionId)
		summary[regionId] = summary[regionId] or { anchor = {}, radius = {} }
		return summary[regionId]
	end

	-- -------------------------------------------------- anchor candidates --
	for regionId, candidates in pairs(OFFSETSWEEP_ANCHOR_CANDIDATES) do
		local coords = WarReport.COORDS[regionId]
		local planet = WarReport.PLANET_OF[regionId]
		if coords == nil or planet == nil then
			printf("OFFSETSWEEP: SKIP  " .. regionId .. " anchor candidates -- no COORDS/PLANET_OF entry\n")
		else
			local s = ensureSummary(regionId)
			for i = 1, #candidates do
				local c = candidates[i]
				local label = string.format("anchorOffset(%g,%g)", c.x, c.y)
				local points = { { label = "recruiter-anchor", x = coords[1] + c.x, y = coords[2] + c.y } }
				local allPass = offsetsweepCheckCandidate(regionId, planet, label, points)
				s.anchor[#s.anchor + 1] = { label = label, pass = allPass }
			end
		end
	end

	-- -------------------------------------------------- radius candidates --
	for regionId, candidates in pairs(OFFSETSWEEP_RADIUS_CANDIDATES) do
		local coords = WarReport.COORDS[regionId]
		local planet = WarReport.PLANET_OF[regionId]
		if coords == nil or planet == nil then
			printf("OFFSETSWEEP: SKIP  " .. regionId .. " radius candidates -- no COORDS/PLANET_OF entry\n")
		else
			local s = ensureSummary(regionId)
			for i = 1, #candidates do
				local radius = candidates[i]
				local label = string.format("siteRadius(%g)", radius)
				local points = offsetsweepCirclePoints(coords, radius)
				local allPass = offsetsweepCheckCandidate(regionId, planet, label, points)
				s.radius[#s.radius + 1] = { label = label, pass = allPass }
			end
		end
	end

	-- ============================================================ summary ==
	printf("OFFSETSWEEP: ---- ranked summary ----\n")
	for regionId, s in pairs(summary) do
		if #s.anchor > 0 then
			local clear = {}
			for i = 1, #s.anchor do
				if s.anchor[i].pass then
					clear[#clear + 1] = s.anchor[i].label
				end
			end
			if #clear > 0 then
				printf("OFFSETSWEEP: " .. regionId .. " anchorOffset candidates ALL CLEAR: " .. table.concat(clear, ", ") .. "\n")
			else
				printf("OFFSETSWEEP: " .. regionId .. " anchorOffset candidates: NONE fully clear -- every candidate tested failed at least one point\n")
			end
		end
		if #s.radius > 0 then
			local clear = {}
			for i = 1, #s.radius do
				if s.radius[i].pass then
					clear[#clear + 1] = s.radius[i].label
				end
			end
			if #clear > 0 then
				printf("OFFSETSWEEP: " .. regionId .. " siteRadius candidates ALL CLEAR: " .. table.concat(clear, ", ") .. "\n")
			else
				printf("OFFSETSWEEP: " .. regionId .. " siteRadius candidates: NONE fully clear -- every candidate tested failed at least one bearing\n")
			end
		end
	end

	printf("OFFSETSWEEP: end\n")
end
