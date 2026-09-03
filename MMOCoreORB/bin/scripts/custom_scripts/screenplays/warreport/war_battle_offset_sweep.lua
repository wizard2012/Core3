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

  RESULTS SO FAR (2026-09-03 run against the live navmesh)
  ----------------------------------------------------------
  - nab_theed anchorOffset: ALL CLEAR at (90,90), (100,100), (-80,80),
    (80,-80). {90,90} was chosen (smallest change off the default {80,80})
    and is now live in war_battle.lua's SITE_OVERRIDES. REMOVED from
    ANCHOR_CANDIDATES below -- settled, no need to keep re-sweeping it.
  - tat_bestine siteRadius: ALL CLEAR at 100 and 110. 100 was chosen (closer
    in, matching this project's stated design direction) and is now live in
    war_battle.lua's SITE_OVERRIDES. REMOVED from RADIUS_CANDIDATES below --
    settled.
  - nab_theed siteRadius: NONE of {90, 100, 110} came back fully clear.
  - cor_tyrena siteRadius: NONE of {90, 100, 110} came back fully clear.
    RADIUS_CANDIDATES below widens both to a 60-170 band (the 90-110 band
    failing does not by itself say which direction, if any, helps) and the
    per-candidate output now names which bearing(s) failed, plus flags any
    bearing that fails at EVERY candidate radius tested for that region --
    that pattern means a fixed obstacle at that bearing, not a radius
    problem, and no radius will fix it.

  This probe has been run once already (see RESULTS above for what is
  settled). Do not treat any candidate still listed below as verified --
  these are proposals still waiting on a fresh run.
]]

-- ======================================================= candidate lists ==

-- nab_theed recruiter-anchor is SETTLED (see RESULTS above) -- no entries
-- left to sweep. Leaving the table empty (rather than deleting the whole
-- anchor-sweep code path) keeps this file ready to sweep a future
-- recruiter-anchor failure at another region without rewriting anything.
local OFFSETSWEEP_ANCHOR_CANDIDATES = {
}

-- Candidate siteRadius overrides for the two regions still unresolved
-- (tat_bestine is SETTLED -- see RESULTS above, removed from this table).
-- The first sweep (90/100/110) all failed for both regions; that band
-- alone doesn't say whether a smaller or larger radius would clear, so
-- this widens to roughly 60-170 in both directions from the 130 the
-- default computation clamps to.
local OFFSETSWEEP_RADIUS_CANDIDATES = {
	nab_theed  = { 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170 },
	cor_tyrena = { 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170 },
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

--- Checks every point a candidate produces for a region. Returns whether
-- ALL of them passed (one failing bearing fails the candidate, even if
-- every other bearing for it passed) plus the list of point labels that
-- failed, so the caller can report exactly which bearing(s) sank it rather
-- than a bare pass/fail.
local function offsetsweepCheckCandidate(regionId, planet, candidateLabel, points)
	local allPass = true
	local failedLabels = {}
	for i = 1, #points do
		local pass = offsetsweepCheckPoint(
			regionId .. " " .. candidateLabel .. " " .. points[i].label,
			planet, points[i].x, points[i].y)
		if not pass then
			allPass = false
			failedLabels[#failedLabels + 1] = points[i].label
		end
	end
	if allPass then
		printf(string.format("OFFSETSWEEP: candidate %s / %-14s -- ALL CLEAR (%d point(s) checked)\n",
			regionId, candidateLabel, #points))
	else
		printf(string.format("OFFSETSWEEP: candidate %s / %-14s -- FAIL, failing bearing(s): %s (%d/%d point(s) checked)\n",
			regionId, candidateLabel, table.concat(failedLabels, ", "), #failedLabels, #points))
	end
	return allPass, failedLabels
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

	-- regionId -> { anchor = {{label, pass}, ...},
	--               radius = {{label, pass}, ...},
	--               radiusCandidateCount = N,
	--               radiusBearingFailCount = { [bearingLabel] = N, ... } }
	local summary = {}
	local function ensureSummary(regionId)
		summary[regionId] = summary[regionId] or {
			anchor = {}, radius = {}, radiusCandidateCount = 0, radiusBearingFailCount = {},
		}
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
				local allPass, failedLabels = offsetsweepCheckCandidate(regionId, planet, label, points)
				s.radius[#s.radius + 1] = { label = label, pass = allPass }
				s.radiusCandidateCount = s.radiusCandidateCount + 1
				for f = 1, #failedLabels do
					local bl = failedLabels[f]
					s.radiusBearingFailCount[bl] = (s.radiusBearingFailCount[bl] or 0) + 1
				end
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

			-- A bearing that fails at EVERY radius candidate tested for this
			-- region cannot be fixed by any radius -- it is a fixed obstacle at
			-- that bearing (a wall, cliff, water, etc.), not a distance
			-- problem. Surface that explicitly rather than letting it hide
			-- inside a wall of per-candidate FAIL lines.
			local alwaysFails = {}
			for bearingLabel, failCount in pairs(s.radiusBearingFailCount) do
				if failCount >= s.radiusCandidateCount and s.radiusCandidateCount > 0 then
					alwaysFails[#alwaysFails + 1] = bearingLabel
				end
			end
			if #alwaysFails > 0 then
				printf("OFFSETSWEEP: " .. regionId .. " -- bearing(s) failing at EVERY siteRadius candidate tested (" ..
					s.radiusCandidateCount .. " candidates): " .. table.concat(alwaysFails, ", ") ..
					" -- likely a fixed obstacle at that bearing; no radius will fix it\n")
			end
		end
	end

	printf("OFFSETSWEEP: end\n")
end
