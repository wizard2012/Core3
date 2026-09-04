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
  diagonally outside the town (BATTLE_OFFSET_M=180 applied on both axes), one
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

-- Squad size per side, per site. RAISED 3 -> 6 (2026-09-04, owner ruling
-- "the war doesn't feel real"): at 3v3 a "battle" was six NPCs in two short
-- lines, which a player could and did walk straight past in a town that had
-- three of them staged. 6v6 reads as an actual firefight, and it gives the
-- B27 squad system something to command -- WarSquad.MAX_TROOPS is 6, so a
-- single site can now furnish a full squad without stripping the site bare.
--
-- Footprint grows with this: a line is (SQUAD_SIZE-1) * TROOPER_GAP_M wide,
-- so 8m at 3 becomes 20m at 6, against a LINE_GAP_M of 10 between the two
-- lines. Sites sit on a placement circle of radius >= SITE_RADIUS_MIN (40),
-- where four sites are ~63m apart, so 20m still clears its neighbours.
WarBattle.SQUAD_SIZE = 6

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

-- Hard cap on combatants alive across EVERY region at once. RAISED 48 -> 192
-- (2026-09-04) alongside SQUAD_SIZE. At the old 48 the entire galactic war was
-- eight sites: one tick measured cor_doaba taking 24 of the 48 on its own,
-- nab_kaadara 18, cor_tyrena getting 1 of the 3 sites it wanted, and
-- tat_mos_espa getting NONE with "budget left=0" -- so even genuinely
-- contested regions were starved by the cap rather than by the simulation.
--
-- At SQUAD_SIZE=6 (12 NPCs/site) 192 is 16 sites galaxy-wide, spent in
-- hottest-region-first, hottest-site-first order -- see BUDGET above. The
-- simulation only runs 3 active fronts (warsim/config.lua max_active_fronts,
-- deliberately: 4 was tried and reverted for causing stalemate), and
-- MAX_SITES_PER_REGION is 4, so the realistic ceiling is 3 * 4 * 12 = 144.
-- The headroom above that is intentional and belongs to the lower-intensity
-- spread layer for uncontested regions.
--
-- THIS IS THE DIAL TO TURN DOWN FIRST if the server struggles: it is a hard
-- cap on simultaneously-live combat AI, and nothing else in this file scales
-- with it.
WarBattle.TOTAL_NPC_BUDGET = 192

-- SPREAD LAYER (2026-09-04, owner ruling). The simulation runs only 3 active
-- fronts, so on any given tick TEN of the thirteen war regions have nothing
-- staged in them at all -- an owner standing on Tatooine saw an empty planet
-- while the whole war was on Corellia and Naboo.
--
-- WHAT THIS LAYER IS, AND WHAT IT DELIBERATELY IS NOT. It does NOT stage
-- battles in uncontested regions. war_battle.lua's MIN_CONTEST comment is
-- right that doing so would be "inventing a war the simulation does not
-- have", and that rule is kept. Instead a held region gets a GARRISON: a
-- patrol of the CONTROLLING faction only, no enemy, no combat. That is a
-- truthful rendering of what the sim actually says about that region -- it is
-- held, not contested -- and for an enemy-faction player it is still live
-- content, because a garrison of the other side is attackable.
--
-- Separate budget on purpose: spending is fronts-first out of
-- TOTAL_NPC_BUDGET, and this pool is only touched afterwards, so a busy war
-- can never have its real battles crowded out by scenery.
WarBattle.SPREAD_SQUAD_SIZE = 4
WarBattle.SPREAD_NPC_BUDGET = 60

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
	-- anchorOffset verified by Tests:battleOffsetSweep against the live
	-- navmesh on 2026-09-03 -- ALL CLEAR at the one recruiter-anchor point
	-- this produces (not bearing-dependent, so contest tier cannot affect
	-- it). {90,90} was chosen as the smallest change off the default
	-- {80,80} that cleared, out of {90,90}/{100,100}/{-80,80}/{80,-80},
	-- keeping the diagonal shape and staying close to town.
	-- siteRadius verified by the widened Tests:battleOffsetSweep run against
	-- the live navmesh on 2026-09-03 -- ALL CLEAR at every bearing across
	-- every contest tier. The 60-170 sweep cleared at 60/70/80/150 only:
	-- 90 through 140 all failed at least one bearing, which reads as a ring
	-- of structures at mid radius rather than a single bad bearing. 80 was
	-- chosen as the largest value in the near band, keeping sites "much
	-- closer in" per the 2026-09-02 REWRITE note while staying clear.
	nab_theed   = { anchorOffset = { x = 90, y = 90 }, siteRadius = 80 },
	-- siteRadius verified by the widened Tests:battleOffsetSweep run against
	-- the live navmesh on 2026-09-03 -- ALL CLEAR at every bearing across
	-- every contest tier. The 60-170 sweep cleared at 70/80/140/150/160
	-- only: 90 through 130 all failed at least one bearing, the same
	-- mid-radius dead band nab_theed shows. 80 chosen for the same reason,
	-- and so both regions share one value rather than two arbitrary ones.
	cor_tyrena  = { siteRadius = 80 },
	-- siteRadius verified by Tests:battleOffsetSweep against the live
	-- navmesh on 2026-09-03 -- ALL CLEAR at every bearing across every
	-- contest tier (totalSites 1-4). 100 was chosen over the other clean
	-- candidate (110) because it is closer in, matching this file's own
	-- stated design direction of staging sites "much closer in" (see the
	-- 2026-09-02 REWRITE note above).
	tat_bestine = { siteRadius = 100 },
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

	-- B27 slice 1: one owner for the war screenplays' lifecycle rather than
	-- two competing ones. WarSquad only observes; it spawns nothing itself.
	if WarSquad ~= nil and WarSquad.start ~= nil then
		WarSquad:start()
	end
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
--
-- PROMOTED from `local function` to a WarBattle field (2026-09-03) so
-- spawn_safety_probe.lua (and any other console probe) can call the real,
-- live implementation -- SITE_OVERRIDES included -- instead of maintaining
-- a separate copy that silently drifts out of sync every time this
-- function changes. Behaviour is unchanged; this is a visibility promotion
-- only.
function WarBattle.siteRadiusFor(regionId)
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
--
-- PROMOTED from `local function` to a WarBattle field for the same reason
-- as WarBattle.siteRadiusFor above -- see that comment.
function WarBattle.siteOrigin(coords, regionId, siteIndex, totalSites, isRecruiterAnchor)
	if isRecruiterAnchor then
		return WarBattle.anchorPoint(coords, regionId)
	end
	local radius = WarBattle.siteRadiusFor(regionId)
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
			-- Healing this NPC feeds war materiel: B11's ruling wants a path
			-- for non-combatants, and a Medic had none. See war_heal.lua.
			-- The observer dies with the object, which cleanup already reaps.
			if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(pD) end
		end
		if pA ~= nil then
			attackers[#attackers + 1] = pA
			trackOid(SceneObject(pA):getObjectID())
			-- Healing this NPC feeds war materiel: B11's ruling wants a path
			-- for non-combatants, and a Medic had none. See war_heal.lua.
			-- The observer dies with the object, which cleanup already reaps.
			if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(pA) end
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
--- Spawn a single-faction garrison patrol. Unlike spawnSite() this sets
-- nobody on anybody: there is no opposing line, so no fight starts. Tracked
-- through the same trackOid() list as everything else, so the existing
-- clear-then-restage cycle owns its lifetime and this can leak nothing.
local function spawnGarrison(zone, regionId, faction, originX, originY)
	local spawned = 0

	for i = 1, WarBattle.SPREAD_SQUAD_SIZE do
		local template = pickTemplate(faction, i, regionId .. "g")
		if template ~= nil then
			-- Spread along one line only; a garrison reads as a patrol
			-- standing about, not as two ranks squaring up.
			local gx = originX + (i - 1) * WarBattle.TROOPER_GAP_M
			local pG = spawnMobile(zone, template, 0, gx, 0, originY, 0, 0)

			if pG ~= nil then
				spawned = spawned + 1
				trackOid(SceneObject(pG):getObjectID())
				-- Same materiel path as a battle NPC (see spawnSite).
				if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(pG) end
			end
		end
	end

	return spawned
end

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
	-- Reap the proximity/presence areas the PREVIOUS cycle spawned, before
	-- staging fresh ones. WarSquad.attachSite() used to be called every cycle
	-- with its return value discarded and nothing ever destroying the area --
	-- ~120 orphaned areas an hour at a 4-minute cycle, each still carrying a
	-- live ENTEREDAREA observer, so a player standing on a long-dead site
	-- could still trip formup. Both modules now own an explicit reap.
	if WarSquad ~= nil and WarSquad.clearAreas ~= nil then
		pcall(function() WarSquad.clearAreas() end)
	end
	if WarPresence ~= nil and WarPresence.clear ~= nil then
		pcall(function() WarPresence.clear() end)
	end

	local sitesStaged, npcsSpawned = 0, 0
	local primaryRegionWritten = false
	-- Regions the front pass touched, so the spread pass below never doubles
	-- up a garrison on top of a live battle.
	local stagedRegions = {}

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
			stagedRegions[regionId] = true
			for s = 1, wanted do
				if npcBudgetLeft < perSiteCost then
					break
				end

				local isRecruiterAnchor = (not primaryRegionWritten) and (s == 1)
				local ox, oy = WarBattle.siteOrigin(coords, regionId, s, wanted, isRecruiterAnchor)
				local fielded = spawnSite(zone, regionId, s, defender, attacker, ox, oy)

				-- B27 slice 1: the proximity area an overt player has to be inside
				-- for troops to fall in. Spawned per site, alongside the site, so
				-- there is no second source of truth about where a battle is.
				if fielded > 0 and WarSquad ~= nil and WarSquad.attachSite ~= nil then
					WarSquad.attachSite(zone, ox, oy)
				end

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

			-- One town-sized presence area per region that actually got
			-- sites, so a player arriving in a contested town is TOLD the war
			-- is here and gets a waypoint. Before this, the only in-world
			-- pointer at a live battle was war_recruiter.lua's markBattle(),
			-- which fires solely from a recruiter conversation -- i.e. only
			-- for players who already knew to go asking.
			if regionSitesStaged > 0 and WarPresence ~= nil and WarPresence.attachRegion ~= nil then
				pcall(function() WarPresence.attachRegion(zone, regionId, regionSitesStaged) end)
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

	-- ---- SPREAD PASS ---------------------------------------------------
	-- Everything the fronts did not touch. Runs on its own budget, after the
	-- fronts have taken what they need. See SPREAD_NPC_BUDGET above for why
	-- these are garrisons rather than battles.
	local garrisonBudget = WarBattle.SPREAD_NPC_BUDGET
	local garrisonsSpawned, garrisonRegions = 0, 0

	pcall(function()
		local st = WarReport.state()
		if st == nil or st.regions == nil then
			return
		end

		local ids = WarReport.regionIds()
		for i = 1, #ids do
			local regionId = ids[i]

			if garrisonBudget < WarBattle.SPREAD_SQUAD_SIZE then
				break
			end

			local r = st.regions[regionId]
			local coords = WarReport.COORDS[regionId]
			local zone = WarReport.PLANET_OF[regionId]

			if not stagedRegions[regionId] and r ~= nil and r.faction ~= nil
					and coords ~= nil and zone ~= nil and isZoneEnabled(zone) then
				-- Reuse the normal site placement so a garrison stands where a
				-- battle would, rather than on top of the town centre.
				local ox, oy = WarBattle.siteOrigin(coords, regionId, 1, 1, false)
				local n = spawnGarrison(zone, regionId, r.faction, ox, oy)

				if n > 0 then
					garrisonBudget = garrisonBudget - n
					garrisonsSpawned = garrisonsSpawned + n
					garrisonRegions = garrisonRegions + 1
				end
			end
		end
	end)

	printf(string.format(
		"WarBattle: spread staged %d garrison NPC(s) across %d held region(s), spread budget was %d\n",
		garrisonsSpawned, garrisonRegions, WarBattle.SPREAD_NPC_BUDGET))

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
