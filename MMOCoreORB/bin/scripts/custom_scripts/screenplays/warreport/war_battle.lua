--[[
  custom_scripts/screenplays/warreport/war_battle.lua

  Live skirmishes at the front: several small squads of opposing GCW NPCs
  spawned close around a contested town, set on each other, that a player can
  walk into and join.

  WHY THIS EXISTS
  ---------------
  Until now the war was legible but not fightable. Region control changed which
  faction garrisons a town and how thick its patrols are, and flips were
  broadcast -- but there was nowhere to actually SEE the war being fought.
  Stock Core3 does not help: screenplays/battlefields/battlefield_spawner.lua
  places battlefield MARKERS (no-build radius objects) and spawns no
  combatants at all, so there is no existing NPC-vs-NPC fighting anywhere in
  the game to join.

  2026-09-02 REWRITE: the first version staged exactly one 4v4, ~255m
  diagonally outside the town (BATTLE_OFFSET_M=80 applied on both axes), one
  region at a time, with a 2-minute silent gap between 10-minute battles. A
  player standing in the actual town saw nothing. This version stages several
  small sites much closer in, at more than one front region at once, on a
  gapless cycle, under a hard NPC budget. See "PLACEMENT" and "BUDGET" below.

  HOW THE FIGHTING ACTUALLY WORKS
  -------------------------------
  AiAgent:setDefender(target) is the documented-by-example mechanism -- it is
  what screenplays/events/syren/syren.lua uses to set NPCs on a player. It
  takes any SceneObject, so pointing two AI agents at each other makes them
  engage. Each combatant is given one opposing defender on spawn; Core3's own
  aggro then keeps the melee going as they retaliate.

  PLACEMENT
  ---------
  Sites are placed on a circle around WarReport.COORDS[region] (the town
  centre), at a radius derived from WarReport.KILL_BOUNDS[region] -- the
  town's own attribution radius, already sourced from the authoritative Core3
  region tables (see war_report.lua's KILL_BOUNDS comment). Using a fraction
  of a town's OWN radius, rather than one fixed distance for every town, is
  why a small town (tat_anchorhead, radius 125) doesn't get a site flung
  further out than a big one (cor_kor_vella, radius 758) -- see
  siteRadiusFor(). The very first site of the highest-contest region is
  placed at the recruiter-anchor point (coords + BATTLE_OFFSET_M diagonal by
  default, or a region's SITE_OVERRIDES.anchorOffset when the default lands
  off the navmesh) computed by WarBattle.anchorPoint() -- see the
  SITE_OVERRIDES comment above WarBattle.anchorOffset() for why that function
  is the ONLY place this arithmetic exists. war_recruiter.lua's markBattle()
  calls the same function to drop its waypoint, so the two cannot
  independently drift apart. Every other site is spread at even bearings
  around the town at the derived radius (see bearingOffset()).

  This is bearing/radius math with NO terrain awareness -- it does not know
  about walls, cliffs, water, or building interiors. Failure mode: a site can
  land inside a structure, in a wall, or over a ledge, and an NPC spawned
  there can end up stuck. The mitigation taken here is distance, not terrain
  sensing: radii are kept inside each town's own attribution circle (so
  sites land in the settled area, not out in raw terrain the game has no
  data for either) and clamped to SITE_RADIUS_MIN/MAX so a site is never
  absurdly close (spawning inside a building near the exact centre) or
  absurdly far (back outside town). This is a real residual risk the human
  in Moenia should watch for: an NPC pair that never moves and never fights
  is the signature of one or both being stuck in geometry.

  BUDGET
  ------
  WarBattle.TOTAL_NPC_BUDGET hard-caps the number of combatants alive across
  EVERY region at once, not per region. Regions are already ranked
  hottest-first by WarReport.frontRegions(); stageBattles() below walks that
  ranked list and, within each region, its ranked list of candidate sites,
  spending budget in that fixed priority order and stopping the instant the
  next site would exceed it. So a hot front is filled up to its own
  contest-scaled site count before a cooler front gets anything, and if the
  galaxy-wide sum of every front's "ideal" site count would blow the budget,
  the coldest of the ranked fronts is the one that goes without -- never the
  hottest. See sitesForContest() and stageBattles().

  LIFECYCLE AND WHY IT IS BOUNDED
  -------------------------------
  There is deliberately no separate "battle lifetime" timer any more. Each
  cycle() tears down every NPC the previous cycle tracked (by OID, from a
  single flat list -- see trackOid/trackedOids/clear below) and immediately
  stages a fresh set, then reschedules itself. That means no NPC ever
  survives longer than one BATTLE_INTERVAL_MS, which is the same "cannot
  outlive its own bookkeeping" guarantee the original design had via
  BATTLE_LIFETIME_MS -- just without the old design's dead gap between a
  battle ending and the next one starting (old: 10-minute life, 12-minute
  interval, 2 minutes of nothing; new: clear-then-respawn every
  BATTLE_INTERVAL_MS, so the front is never simultaneously empty on both
  sides of a cycle boundary).

  Cleanup is unconditional and pcall-wrapped per phase in cycle(): if
  spawnBattle-equivalent staging throws partway through (e.g. one region's
  spawnMobile call fails), every OID it managed to track before the error is
  still in the flat OIDS_KEY list, and the NEXT cycle's clear() -- which runs
  before that cycle stages anything new -- sweeps them up regardless of which
  region or site they belonged to. Nothing is tracked by region, so nothing
  can be "orphaned" by a region-specific bookkeeping mistake.

  A player can join simply by attacking: these are ordinary faction NPCs, so a
  faction-aligned player is free to engage the opposing side.
]]

WarBattle = WarBattle or {}

WarBattle.screenplayName = "WarBattle"

-- Squad size per side, per site. Kept small (3v3, not the original 4v4) so
-- that fielding several sites at once stays inside the NPC budget below.
WarBattle.SQUAD_SIZE = 3

-- Shared default metres-from-town-centre diagonal for the recruiter-anchor
-- site (both x and y). This is the DEFAULT only -- WarBattle.anchorOffset()
-- (see SITE_OVERRIDES below) is what siteOrigin() and war_recruiter.lua's
-- markBattle() actually call, and it substitutes a region's
-- SITE_OVERRIDES.anchorOffset in place of this pair when one is set. Never
-- read this field directly outside WarBattle.anchorOffset() -- go through
-- the function so a per-region override can never be bypassed by one call
-- site and honoured by the other. Every non-anchor site uses
-- siteRadiusFor() instead -- see PLACEMENT above.
WarBattle.BATTLE_OFFSET_M = 80

-- Radius used for every non-primary site: this fraction of the town's own
-- WarReport.KILL_BOUNDS attribution radius, clamped to
-- [SITE_RADIUS_MIN, SITE_RADIUS_MAX] so a tiny town doesn't get a site
-- practically on top of its centre and a huge one doesn't get flung back
-- outside the settled area.
WarBattle.SITE_RADIUS_FRACTION = 0.4
WarBattle.SITE_RADIUS_MIN = 40
WarBattle.SITE_RADIUS_MAX = 130

-- Fallback radius for a region with no WarReport.KILL_BOUNDS entry at all
-- (should not happen for anything WarReport.COORDS lists, but siteRadiusFor
-- must never divide by / index into a nil).
WarBattle.DEFAULT_TOWN_RADIUS = 150

-- Spacing between the two lines, and between troopers within a line. Shrunk
-- from the original (18/5) along with the tighter site radius, so a site's
-- own footprint (about 8m x 10m at SQUAD_SIZE=3) stays well inside the gap
-- between adjacent sites on the placement circle.
WarBattle.LINE_GAP_M = 10
WarBattle.TROOPER_GAP_M = 4

-- How often the whole front is torn down and restaged. No separate
-- "lifetime" timer any more -- see LIFECYCLE above.
WarBattle.BATTLE_INTERVAL_MS = 4 * 60 * 1000

-- Contest at or above which a region is considered worth fighting over. Below
-- this the sim says nothing is happening there, and staging a battle would be
-- inventing a war the simulation does not have. Unchanged from the original
-- and still equal to the floor WarReport.frontRegions() itself uses.
WarBattle.MIN_CONTEST = 1.0

-- Hard cap on sites in a single region, even if sitesForContest() would ask
-- for more. Matches sitesForContest()'s own top tier.
WarBattle.MAX_SITES_PER_REGION = 4

-- Hard cap on combatants alive across EVERY region at once. At
-- SQUAD_SIZE=3 (6 NPCs/site) this is 8 sites galaxy-wide, spent in
-- hottest-region-first, hottest-site-first order -- see BUDGET above.
WarBattle.TOTAL_NPC_BUDGET = 48

-- Combatant templates. Verified present in the running server by the
-- warBridgeCheck probe, which listed them among templates the cities spawn.
WarBattle.TROOPS = {
	imperial = { "stormtrooper", "stormtrooper_rifleman", "sand_trooper" },
	rebel    = { "rebel_trooper", "rebel_commando", "rebel_scout" },
}

WarBattle.OIDS_KEY = "warbattle:oids"
WarBattle.REGION_KEY = "warbattle:region"

-- ============================================================ overrides ==
-- Per-region overrides for site placement math, added after a navmesh-backed
-- audit (isPointWalkable, 2026-09-02) found four sites computed by the
-- shared default math sitting off the walkable navmesh. Two independent
-- sub-fields, because they fix two different kinds of site:
--
--   anchorOffset = { x = <dx>, y = <dy> }
--     Overrides BATTLE_OFFSET_M for THIS region's recruiter-anchor site
--     only (siteOrigin()'s isRecruiterAnchor branch). Read ONLY through
--     WarBattle.anchorPoint() below -- the SINGLE place this arithmetic
--     exists. war_recruiter.lua's markBattle() calls that same function
--     instead of recomputing coords+offset itself, so the fight location
--     and the waypoint that points at it can never independently drift
--     apart, no matter what future edit touches either file.
--
--   siteRadius = <metres>
--     Overrides siteRadiusFor()'s computed circle radius for every
--     non-primary ("circle@Ndeg") site in this region. war_recruiter.lua
--     never reads this -- it only ever points at the recruiter anchor, never
--     at a circle site -- so there is no divergence risk to guard here.
--     LIMITATION: a radius override still spreads sites around the FULL
--     360-degree circle, and which bearing lands at a given siteIndex shifts
--     as contest tier changes the site count (sitesForContest()). Verifying
--     one bearing walkable at a candidate radius is not proof every bearing
--     at that radius is clear -- re-check across bearings/contest tiers
--     before trusting a region is fully fixed, not just the bearing named in
--     the original failure report.
--
-- Every value here MUST be independently verified against the live
-- isPointWalkable audit before being uncommented. DO NOT GUESS: an
-- unverified number that merely looks plausible is exactly the failure mode
-- that has already cost this project time (a "fix" that copied a coordinate
-- which was itself still failing). Leave an entry commented out until a
-- human confirms the candidate passes.
WarBattle.SITE_OVERRIDES = {
	-- nab_theed   = { anchorOffset = { x = ??, y = ?? }, siteRadius = ?? },
	-- cor_tyrena  = { siteRadius = ?? },
	-- tat_bestine = { siteRadius = ?? },
}

--- The (dx, dy) applied to a region's WarReport.COORDS to place its
-- recruiter-anchor site. Per-region override if SITE_OVERRIDES has one,
-- else the shared BATTLE_OFFSET_M diagonal for both axes.
function WarBattle.anchorOffset(regionId)
	local override = WarBattle.SITE_OVERRIDES[regionId]
	if override ~= nil and override.anchorOffset ~= nil then
		return override.anchorOffset.x, override.anchorOffset.y
	end
	return WarBattle.BATTLE_OFFSET_M, WarBattle.BATTLE_OFFSET_M
end

--- World-space point for a region's recruiter-anchor site. THE ONLY place
-- coords+offset arithmetic for that site exists -- siteOrigin() below and
-- war_recruiter.lua's markBattle() both call this instead of recomputing it,
-- so they are structurally unable to diverge (see SITE_OVERRIDES comment).
function WarBattle.anchorPoint(coords, regionId)
	local dx, dy = WarBattle.anchorOffset(regionId)
	return coords[1] + dx, coords[2] + dy
end

registerScreenPlay("WarBattle", true)

function WarBattle:start()
	if not isZoneEnabled("tatooine") then
		return
	end
	-- First battle on a delay, for the same reason WarOfficer spawns late:
	-- the war state may not be readable on this thread at start() time.
	createEvent(45000, "WarBattle", "cycle", nil, "")
end

-- ================================================================ helpers ==

local function trackOid(oid)
	local raw = readStringData(WarBattle.OIDS_KEY)
	if raw == nil or raw == "" then
		writeStringData(WarBattle.OIDS_KEY, tostring(oid))
	else
		writeStringData(WarBattle.OIDS_KEY, raw .. "," .. tostring(oid))
	end
end

local function trackedOids()
	local out = {}
	local raw = readStringData(WarBattle.OIDS_KEY)
	if raw == nil or raw == "" then
		return out
	end
	for token in string.gmatch(raw, "([^,]+)") do
		local n = tonumber(token)
		if n ~= nil and n > 0 then
			out[#out + 1] = n
		end
	end
	return out
end

--- Deterministic pick, so a given region/site/slot always fields the same
-- trooper type. Avoids needing an RNG and keeps repeat visits visually
-- stable.
local function pickTemplate(faction, index, salt)
	local pool = WarBattle.TROOPS[faction]
	if pool == nil or #pool == 0 then
		return nil
	end
	local h = index
	for i = 1, #salt do
		h = (h * 31 + salt:byte(i)) % 100003
	end
	return pool[(h % #pool) + 1]
end

--- How many simultaneous sites a region's contest level earns. Ranked
-- tiers, not a smooth formula, so the scaling is easy to read and to
-- reason about at a glance (and easy to re-tune without doing algebra).
local function sitesForContest(contest)
	contest = contest or 0
	if contest >= 20 then
		return 4
	elseif contest >= 10 then
		return 3
	elseif contest >= 5 then
		return 2
	else
		return 1
	end
end

--- The town's own attribution radius from WarReport.KILL_BOUNDS, collapsed
-- to a single number regardless of whether the bound is a circle or a
-- rectangle (nab_keren, nab_theed). For a rectangle this is the radius of
-- the largest circle that still fits inside it, so a placement at this
-- radius is inside the rectangle at every bearing, not just some.
local function townRadius(regionId)
	local bounds = WarReport.KILL_BOUNDS and WarReport.KILL_BOUNDS[regionId]
	if bounds == nil then
		return WarBattle.DEFAULT_TOWN_RADIUS
	end
	if bounds.kind == "circle" and type(bounds.radius) == "number" then
		return bounds.radius
	end
	if bounds.kind == "rect" then
		local halfW = math.abs(bounds.x2 - bounds.x1) / 2
		local halfH = math.abs(bounds.y2 - bounds.y1) / 2
		return math.min(halfW, halfH)
	end
	return WarBattle.DEFAULT_TOWN_RADIUS
end

--- Placement radius for every non-primary site at a region: a fraction of
-- that town's own radius, clamped so it never gets absurdly close to or far
-- from the centre regardless of how big or small the town is.
local function siteRadiusFor(regionId)
	local override = WarBattle.SITE_OVERRIDES[regionId]
	if override ~= nil and override.siteRadius ~= nil then
		return override.siteRadius
	end
	local r = townRadius(regionId) * WarBattle.SITE_RADIUS_FRACTION
	if r < WarBattle.SITE_RADIUS_MIN then
		r = WarBattle.SITE_RADIUS_MIN
	elseif r > WarBattle.SITE_RADIUS_MAX then
		r = WarBattle.SITE_RADIUS_MAX
	end
	return r
end

--- World-space origin for one site: bearings spread evenly around the town
-- starting at 45 degrees, at siteRadiusFor()'s radius -- EXCEPT the very
-- first site of the very first region staged this cycle, which uses the
-- exact legacy diagonal offset instead, to stay byte-for-byte compatible
-- with war_recruiter.lua's own waypoint math (see PLACEMENT above).
local function siteOrigin(coords, regionId, siteIndex, totalSites, isRecruiterAnchor)
	if isRecruiterAnchor then
		return WarBattle.anchorPoint(coords, regionId)
	end
	local radius = siteRadiusFor(regionId)
	local degrees = 45 + (siteIndex - 1) * (360 / totalSites)
	local rad = degrees * math.pi / 180
	return coords[1] + radius * math.cos(rad), coords[2] + radius * math.sin(rad)
end

-- ================================================================ cleanup ==

--- Destroy every currently-tracked combatant, regardless of which region or
-- site spawned it. Deliberately flat (one list, not one per region/site) --
-- see LIFECYCLE above for why that is what makes cleanup airtight under a
-- mid-cycle error.
function WarBattle:clear()
	local oids = trackedOids()
	local removed = 0
	for i = 1, #oids do
		local pObj = getSceneObject(oids[i])
		if pObj ~= nil then
			pcall(function() SceneObject(pObj):destroyObjectFromWorld(false) end)
			removed = removed + 1
		end
	end
	writeStringData(WarBattle.OIDS_KEY, "")
	return removed
end

-- ================================================================== spawn ==

--- Choose where to fight: the single most-contested region that has
-- coordinates. Kept for the warBattleNow probe's informational printf and
-- for anything else reading a single "top" front; stageBattles() below does
-- the real multi-region, multi-site work and does not call this.
function WarBattle:pickRegion()
	if WarReport == nil or WarReport.state() == nil then
		return nil
	end

	local front = WarReport.frontRegions(WarBattle.MIN_CONTEST)
	for i = 1, #front do
		local id = front[i].id
		if WarReport.COORDS[id] ~= nil then
			return id, front[i].faction, front[i].contest
		end
	end
	return nil
end

--- Spawn one defender/attacker line pair at (originX, originY). Returns the
-- number of NPCs actually fielded (0, 2*n, or a lopsided partial count on a
-- spawnMobile failure -- the caller only checks for zero-on-both-sides).
local function spawnSite(zone, regionId, siteIndex, defenderFaction, attackerFaction, originX, originY)
	local defenders, attackers = {}, {}

	for i = 1, WarBattle.SQUAD_SIZE do
		local dTemplate = pickTemplate(defenderFaction, i, regionId .. "s" .. siteIndex .. "d")
		local aTemplate = pickTemplate(attackerFaction, i, regionId .. "s" .. siteIndex .. "a")

		local dx = originX + (i - 1) * WarBattle.TROOPER_GAP_M
		local dy = originY
		local ax = originX + (i - 1) * WarBattle.TROOPER_GAP_M
		local ay = originY + WarBattle.LINE_GAP_M

		local pD = dTemplate and spawnMobile(zone, dTemplate, 0, dx, 0, dy, 0, 0) or nil
		local pA = aTemplate and spawnMobile(zone, aTemplate, 0, ax, 0, ay, 180, 0) or nil

		if pD ~= nil then
			defenders[#defenders + 1] = pD
			trackOid(SceneObject(pD):getObjectID())
		end
		if pA ~= nil then
			attackers[#attackers + 1] = pA
			trackOid(SceneObject(pA):getObjectID())
		end
	end

	if #defenders == 0 or #attackers == 0 then
		return #defenders + #attackers
	end

	-- Set them on each other. setDefender is the mechanism syren.lua uses to
	-- put an AI into combat with a target; pointing both sides at each other
	-- starts the fight, and Core3's own retaliation keeps it going.
	local pairs_n = math.min(#defenders, #attackers)
	for i = 1, pairs_n do
		pcall(function() AiAgent(defenders[i]):setDefender(attackers[i]) end)
		pcall(function() AiAgent(attackers[i]):setDefender(defenders[i]) end)
	end

	return #defenders + #attackers
end

--- Stage every site at every qualifying front region, in strict
-- hottest-first priority, spending WarBattle.TOTAL_NPC_BUDGET as it goes.
-- See BUDGET above. Returns the number of sites actually staged and the
-- number of NPCs spawned, for the caller's log line.
function WarBattle:stageBattles()
	if WarReport == nil or WarReport.state() == nil then
		printf("WarBattle: war state not readable on this thread -- no battles staged\n")
		return 0, 0
	end

	local front = WarReport.frontRegions(WarBattle.MIN_CONTEST)
	if #front == 0 then
		printf("WarBattle: no contested region above MIN_CONTEST -- front is quiet\n")
		return 0, 0
	end

	local npcBudgetLeft = WarBattle.TOTAL_NPC_BUDGET
	local perSiteCost = WarBattle.SQUAD_SIZE * 2
	local sitesStaged, npcsSpawned = 0, 0
	local primaryRegionWritten = false

	for r = 1, #front do
		local regionId = front[r].id
		local coords = WarReport.COORDS[regionId]
		local zone = WarReport.PLANET_OF[regionId]

		if coords ~= nil and zone ~= nil and isZoneEnabled(zone) then
			local holder = front[r].faction
			local defender = holder
			local attacker = (holder == "rebel") and "imperial" or "rebel"
			local wanted = math.min(sitesForContest(front[r].contest), WarBattle.MAX_SITES_PER_REGION)

			local regionSitesStaged = 0
			for s = 1, wanted do
				if npcBudgetLeft < perSiteCost then
					break
				end

				local isRecruiterAnchor = (not primaryRegionWritten) and (s == 1)
				local ox, oy = siteOrigin(coords, regionId, s, wanted, isRecruiterAnchor)
				local fielded = spawnSite(zone, regionId, s, defender, attacker, ox, oy)

				if fielded > 0 then
					npcBudgetLeft = npcBudgetLeft - perSiteCost
					npcsSpawned = npcsSpawned + fielded
					sitesStaged = sitesStaged + 1
					regionSitesStaged = regionSitesStaged + 1
					if isRecruiterAnchor then
						writeStringData(WarBattle.REGION_KEY, regionId)
						primaryRegionWritten = true
					end
				end
			end

			printf(string.format(
				"WarBattle: %s (%s) contest=%.2f holder=%s -- %d/%d site(s) staged, budget left=%d\n",
				tostring(regionId), tostring(zone), front[r].contest or 0, tostring(holder),
				regionSitesStaged, wanted, npcBudgetLeft))
		end

		if npcBudgetLeft < perSiteCost then
			break
		end
	end

	if not primaryRegionWritten then
		writeStringData(WarBattle.REGION_KEY, "")
	end

	printf(string.format("WarBattle: cycle staged %d site(s), %d NPC(s), budget was %d\n",
		sitesStaged, npcsSpawned, WarBattle.TOTAL_NPC_BUDGET))

	return sitesStaged, npcsSpawned
end

--- Kept for the warBattleNow probe (calls WarBattle:clear() then
-- WarBattle:spawnBattle() with no args) and any other external caller
-- expecting the old single-battle entry point name. Delegates to the real
-- multi-region, multi-site staging.
function WarBattle:spawnBattle()
	local staged = WarBattle:stageBattles()
	return staged > 0
end

--- One turn of the loop: tear down every previously-tracked combatant
-- (regardless of region/site), stage a fresh front, schedule the next turn.
-- The reschedule happens unconditionally and outside the pcalls, so a
-- staging error can never stop the loop or leave the front frozen.
function WarBattle:cycle()
	pcall(function() WarBattle:clear() end)
	pcall(function() WarBattle:stageBattles() end)
	createEvent(WarBattle.BATTLE_INTERVAL_MS, "WarBattle", "cycle", nil, "")
end
