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

-- GRAND BATTLES slice A (docs/DESIGN-BATTLES.md, owner rulings 2026-09-05):
-- one site per front, a LINE per side, and reinforcement waves while the
-- site stands. SQUAD_SIZE above is what war_squad.lua hands a player and
-- what the spread garrisons use; a front's line is LINE_SIZE.
WarBattle.LINE_SIZE = 12            -- bodies per side at a front's site
WarBattle.LINE_SIZE_OFFENSIVE = 16  -- when the sim marks the front an offensive
WarBattle.LINE_RANK = 8             -- bodies per rank; a line forms in ranks of this
WarBattle.WAVE_TRIGGER_FRAC = 0.5   -- a side at or below this fraction of its line gets a wave
WarBattle.WAVE_SIZE_FRAC = 0.5      -- a wave is this fraction of the line
WarBattle.WAVES_MAX_PER_SIDE = 3    -- per site; after that the line it has is the line it dies with
WarBattle.WAVES_ENABLED = true      -- the switch docs/DESIGN-BATTLES.md section 5 names

-- Slice B: squads with a sergeant and roles; a TEND pass between battle
-- cycles that reinforces and orders retreats (a 4-minute reconcile catches
-- almost no line in its half-strength window -- measured: two of six
-- sites resolved inside one cycle with no wave); chatter.
WarBattle.TEND_INTERVAL_MS = 75 * 1000
WarBattle.TEND_NPC_BUDGET = 48       -- bodies one tend pass may add, all fronts
WarBattle.RETREAT_FRAC = 0.35        -- a side at or below this fraction of its line...
WarBattle.RETREAT_ENEMY_FRAC = 0.6   -- ...while the other side is above this, falls back (if a wave is still due)
WarBattle.RETREAT_COOLDOWN_MS = 5 * 60 * 1000
-- Stuck sites (measured 2026-09-05, Theed site 1: bodies spawned at z=0
-- under the city's 6 m ground and the stall fallback put the attackers in
-- a canal; line of sight failed both ways and 24 bodies stood in combat
-- with nobody hurt for as long as the site stood). A two-sided site with
-- nobody hurt and nobody dead for STUCK_PASSES tend passes is quiet: the
-- attackers are closed to STUCK_CLOSE_M of the defenders on walkable
-- ground; if it stays quiet as long again the site breaks off and the
-- region's site ring turns SITE_TURN_DEG so the next cycle stages on
-- different ground.
WarBattle.STUCK_PASSES = 3
WarBattle.STUCK_CLOSE_M = 10
WarBattle.SITE_TURN_DEG = 30
-- Slice C: walkers (docs/DESIGN-BATTLES.md section 2). One per side at a
-- front whose intensity is at or above WALKER_INTENSITY or that is an
-- offensive; the line attacking a capital under siege gets the AT-AT
-- (Imperial only -- the Rebels keep their liberated AT-ST). A walker
-- stands WALKER_BACK_M behind its line, counts WALKER_CRATES casualties
-- when it falls (reconcile), and never waves. Two bodies per hot site on
-- top of the lines; not charged to the site budget.
WarBattle.WALKERS_ENABLED = true
WarBattle.WALKER_INTENSITY = 0.75
WarBattle.WALKER_CRATES = 4
WarBattle.WALKER_BACK_M = 10
WarBattle.WALKERS = { imperial = "war_at_st", rebel = "war_at_st_liberated", siege = "war_at_at" }
WarBattle.ROLES_ENABLED = true
-- The war's own templates (custom_scripts/mobile/war/war_troops.lua, boot-
-- loaded). spawnTroop() falls back to TROOPS if a name is not loaded yet.
WarBattle.ROLES = {
	imperial = { sergeant = "war_imperial_sergeant", medic = "war_imperial_medic", marksman = "war_imperial_marksman",
	             heavy = "war_imperial_heavy", rifleman = "war_imperial_rifleman" },
	rebel    = { sergeant = "war_rebel_sergeant", medic = "war_rebel_medic", marksman = "war_rebel_marksman",
	             heavy = "war_rebel_heavy", rifleman = "war_rebel_rifleman" },
}
-- Position in the line -> role. One sergeant, then a medic, a marksman and a
-- heavy per rank; the rest riflemen. A wave is riflemen led by a medic.
WarBattle.LINE_PATTERN = {
	"sergeant", "medic", "marksman", "heavy", "rifleman", "rifleman", "rifleman", "rifleman",
	"rifleman", "medic", "marksman", "heavy", "rifleman", "rifleman", "rifleman", "rifleman",
}

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

-- How far OUTSIDE the site the attacking side forms up, along the radial
-- running from the town centre out through the site (2026-09-04, owner
-- ruling). Previously both sides were spawned LINE_GAP_M apart -- ten metres
-- -- which meant an assault on a town appeared fully formed inside that town,
-- two ranks facing off like a diorama. Attackers now appear out past the
-- settled edge and advance in, so a player watching a contested town sees
-- troops coming for it.
--
-- Kept deliberately modest. This project has already been bitten by NPCs
-- frozen on unpathable ground (see the Anchorhead createNavMesh work), and
-- every extra metre outward is more chance of spawning somewhere the navmesh
-- cannot path out of. If troops are ever seen standing still out in open
-- country, THIS is the first dial to turn down.
--
-- 120 -> 80 (measured 2026-09-05, `test warSiteDistanceCheck`): at 120 m
-- the attacking line at Mos Eisley site 3 was still at exactly 120 m ten
-- minutes in, following=6, hurt=0, while the defenders had walked OUT to
-- 56-65 m -- rifle range -- and were shooting them. AiAgent's FOLLOWING
-- state leashes an agent that is more than MAX_OOS_RANGE (75 m) from its
-- HOME with no line of sight to its target, and home was the attacker's own
-- spawn point 120 m out; every step toward the town was a step out of
-- range of home. Two changes, together: form up at 80 m, and set every
-- attacker's home to the ground it is taking (spawnSite), so the same rule
-- now pulls a lost attacker INTO the town rather than back out of it.
WarBattle.APPROACH_DISTANCE_M = 80

-- A line that has not moved STALL_CHECK_MS after forming up is not
-- advancing and never will (measured 2026-09-05: Mos Eisley's attackers at
-- exactly 80 m for three minutes with following=6, twice, and a Doaba line
-- at 48 m likewise -- both endpoints on the navmesh, no path between them;
-- Kaadara's lines, same code, resolved every site in that time). Rather
-- than let a site stand as a diorama for five cycles, checkAdvance() puts a
-- stalled line down at STALL_FALLBACK_M -- outside the site, inside rifle
-- range -- and the fight starts. The advance is lost for that site; the
-- battle is not.
WarBattle.STALL_CHECK_MS   = 75 * 1000
WarBattle.STALL_TOLERANCE_M = 6
WarBattle.STALL_FALLBACK_M = 24

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

-- PERSISTENCE (2026-09-04, owner ruling "make battles have consequence").
--
-- WHAT CHANGED. cycle() used to call clear() -- destroy EVERY tracked NPC --
-- and then restage from nothing, every BATTLE_INTERVAL_MS. That is what made
-- the war feel like scenery: a player could fight through a site, and four
-- minutes later the dead were back and the survivors were gone, with the
-- fight they had just won erased underneath them. It also meant no engagement
-- could ever resolve, because none of them lasted long enough to.
--
-- Now cycle() reconciles instead. A site where BOTH sides still have living
-- NPCs is left completely alone -- no despawn, no respawn, no reset. Only
-- slots that are empty, one-sided, or too old are cleared and restaged.
--
-- WHAT REPLACES THE OLD LEAK GUARANTEE. The previous design was leak-proof by
-- brute force: nothing outlived one interval. That guarantee is now carried by
-- three things instead, and all three matter:
--   1. Every unit is still recorded in OIDS_KEY, so clear() still owns it.
--   2. ROSTER_KEY additionally records which region/site/faction each unit
--      belongs to, so reconcile() can reason about a slot rather than a flat
--      list. Rebuilt from survivors every cycle, so it cannot grow unbounded.
--   3. MAX_SITE_AGE_CYCLES caps how long any slot may persist, so a permanent
--      stalemate cannot pin NPCs alive forever.
--
-- ROSTER_KEY format: records separated by ";", fields within a record by "|":
--   oid|regionId|siteIndex|faction
-- OIDS_KEY deliberately keeps its old bare-comma-separated-OID format --
-- war_squad.lua's stagedOids() parses it with tonumber() and would break on
-- anything richer. Two views of the same set, one of them load-bearing for
-- another module.
-- Record: oid|regionId|siteIndex|faction|originX|originY[|w] -- the last
-- field marks a walker (slice C); older four-field records still parse.
WarBattle.ROSTER_KEY = "warbattle:roster"
WarBattle.CYCLE_KEY = "warbattle:cycle"

-- How many cycles a single engagement may persist before it is torn down and
-- restaged regardless of who is still standing. At a 4-minute interval this is
-- 20 minutes: long enough that a fight is a place you can go back to, short
-- enough that the front still reshapes itself to what the simulation says.
WarBattle.MAX_SITE_AGE_CYCLES = 5

-- How many slots may age out in ONE reconcile pass. Every slot staged in the
-- same cycle reaches MAX_SITE_AGE_CYCLES in the same cycle, and razing them
-- all at once IS the "war resets every few minutes" that persistence exists
-- to end -- measured 2026-09-05 in screenlog.0: every fifth reconcile razed
-- and restaged all 22 slots (132 NPCs) on a front nobody was standing on.
-- Capped, the oldest few refresh each cycle and the rest keep standing, so
-- the front reshapes itself as a rolling change rather than a reset.
-- Resolutions (one side wiped, a capture) are never deferred by this cap.
WarBattle.MAX_AGEOUTS_PER_CYCLE = 3

-- Layer 2 of the feedback stack (owner ruling 2026-09-04, "make battles have
-- consequence"): when one side wipes the other at a site, the WINNER's troops
-- hold that ground as a garrison until the slot ages out, and stageBattles()
-- will not restage a battle over it. The sim, not the game, decides when that
-- ground is contested again. Capped on its own so a run of captures can never
-- draw down TOTAL_NPC_BUDGET or the spread pool.
WarBattle.CAPTURE_GARRISON_MAX_SLOTS = 8

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
	-- Slice B: the tend chain (waves, retreats) between cycles.
	createEvent(60000, "WarBattle", "tendSites", nil, "")

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

--- Record a unit in BOTH views: the flat OID list clear() and war_squad.lua
-- consume, and the structured roster reconcile() needs. siteIndex 0 means a
-- spread-layer garrison rather than a battle site.
local function trackUnit(oid, regionId, siteIndex, faction, originX, originY, kind)
	trackOid(oid)

	-- Six fields. ox/oy are the SITE origin (where the defenders stood), so a
	-- capture garrison stands on the ground that was actually taken. Older
	-- four-field records are still parsed by reconcile() -- they just cannot
	-- produce a capture garrison for the one cycle it takes them to age out.
	local rec = tostring(oid) .. "|" .. tostring(regionId) .. "|"
		.. tostring(siteIndex) .. "|" .. tostring(faction) .. "|"
		.. (originX ~= nil and string.format("%.1f", originX) or "") .. "|"
		.. (originY ~= nil and string.format("%.1f", originY) or "")
		-- Seventh field, slice C: "w" marks a walker (WALKER_CRATES on death).
		.. ((kind == "w") and "|w" or "")

	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		writeStringData(WarBattle.ROSTER_KEY, rec)
	else
		writeStringData(WarBattle.ROSTER_KEY, raw .. ";" .. rec)
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
	-- A region whose site broke off as stuck (tendOnce) has its ring turned
	-- so the next site stands on different ground. Wraps after a full turn.
	local turns = 0
	if type(readData) == "function" then
		turns = readData("warbattle:siteturn:" .. tostring(regionId)) or 0
	end
	local degrees = 45 + (siteIndex - 1) * (360 / totalSites) + turns * WarBattle.SITE_TURN_DEG
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
	-- Every slot's age clock too: a slot restaged after this clear would
	-- otherwise inherit the old birth cycle and be razed before its time.
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw ~= nil and raw ~= "" then
		local seen = {}
		for rec in string.gmatch(raw, "([^;]+)") do
			local f = {}
			for field in string.gmatch(rec .. "|", "([^|]*)|") do
				f[#f + 1] = field
			end
			if f[2] ~= nil and f[2] ~= "" and f[3] ~= nil and f[3] ~= "" then
				local key = f[2] .. ":" .. f[3]
				if not seen[key] then
					seen[key] = true
					writeData("warbattle:born:" .. key, 0)
				end
			end
		end
	end
	writeStringData(WarBattle.OIDS_KEY, "")
	-- The roster is a second view of the same set; leaving it behind would
	-- have reconcile() reasoning about units that no longer exist.
	writeStringData(WarBattle.ROSTER_KEY, "")
	return removed
end

--- Reconcile the standing war against what is still alive, instead of razing
-- it. Returns (heldSites, heldGarrisons, captures):
--   heldSites      { ["region:site"] = true }  slots to leave completely alone
--   heldGarrisons  { [regionId] = true }       ditto for the spread layer
--   captures       array of { region, faction } resolved this cycle
--
-- A slot is KEPT when both sides still have living units and it is younger
-- than MAX_SITE_AGE_CYCLES. A slot with exactly one surviving side is a
-- CAPTURE: that faction won the position, so it is recorded, the survivors
-- stand down, and the slot is freed for restaging.
--
-- `advanceClock` (default true) is the age clock. The periodic cycle passes
-- true; probes pass false so that LOOKING at the war does not age it -- with
-- the clock advancing on every call, `test warReconcileNow` was a cycle, and
-- five probes in a row razed the front exactly like five real cycles would.
--- Spool `counts` ({ ["region|faction"] = n }) as `source` rows. Never
-- throws; a rejection is printed, not raised.
function WarBattle.report(counts, source)
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
				printf(string.format("WarBattle: %s %s at %s x%d -- recorded\n",
					tostring(faction), tostring(source), tostring(region), counts[k]))
			else
				printf(string.format("WarBattle: %s %s at %s NOT recorded: %s\n",
					tostring(faction), tostring(source), tostring(region), tostring(why or recorded)))
			end
		end
	end
end

--- The fronts the ground fights at: the sim's exported list (war_state.lua
-- schema 4, `fronts`), hottest first, each as { id, faction (holder),
-- attacker, staging, intensity, contest }. Falls back to the contest-ranked
-- top-N when the export predates schema 4. D27 slice 2: the ground stages
-- where the war says the fronts are, at every one of them.
function WarBattle.fronts()
	local st = WarReport.state()
	if st == nil then
		return {}
	end
	local out = {}
	if type(st.fronts) == "table" and #st.fronts > 0 then
		for i = 1, #st.fronts do
			local f = st.fronts[i]
			local r = f ~= nil and st.regions[f.region] or nil
			if r ~= nil and r.faction ~= nil then
				local intensity = tonumber(f.intensity) or 0
				out[#out + 1] = {
					id = f.region, faction = r.faction, attacker = f.attacker, staging = f.staging,
					intensity = intensity, contest = math.min(100, intensity * 100),
					offensive = f.offensive == true,
				}
			end
		end
		table.sort(out, function(a, b)
			if a.intensity ~= b.intensity then return a.intensity > b.intensity end
			return a.id < b.id
		end)
		return out
	end
	return WarReport.frontRegions(WarBattle.MIN_CONTEST)
end

--- Sites a front earns: two at intensity >= FRONT_TWO_SITES_INTENSITY, else
-- one (owner ruling 2026-09-05: every front gets a fight; the hottest get
-- two). Legacy contest-ranked fronts keep the old tiering.
WarBattle.FRONT_TWO_SITES_INTENSITY = 0.5
local function sitesForFront(front)
	if front.intensity ~= nil then
		return (front.intensity >= WarBattle.FRONT_TWO_SITES_INTENSITY) and 2 or 1
	end
	return sitesForContest(front.contest)
end

function WarBattle:reconcile(advanceClock)
	local heldSites, heldGarrisons, captures = {}, {}, {}

	local cycleNo = readData(WarBattle.CYCLE_KEY) or 0
	if advanceClock ~= false then
		cycleNo = cycleNo + 1
		writeData(WarBattle.CYCLE_KEY, cycleNo)
	end

	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return heldSites, heldGarrisons, captures
	end

	local slots = {}
	-- D27 slice 2: bodies. A roster unit that is dead or gone this cycle
	-- is a casualty the ground reports once (it leaves the roster below).
	local casualties = {}
	for rec in string.gmatch(raw, "([^;]+)") do
		local f = {}
		for field in string.gmatch(rec .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		local oid, regionId, siteIndex, faction = tonumber(f[1]), f[2], f[3], f[4]
		local ox, oy = tonumber(f[5]), tonumber(f[6])

		if oid ~= nil and regionId ~= nil and regionId ~= "" and siteIndex ~= nil and siteIndex ~= "" then
			local key = regionId .. ":" .. siteIndex
			if slots[key] == nil then
				slots[key] = { region = regionId, site = siteIndex, alive = {}, units = {}, seen = {} }
			end
			if ox ~= nil and oy ~= nil and slots[key].ox == nil then
				slots[key].ox, slots[key].oy = ox, oy
			end
			slots[key].seen[faction] = true

			-- Alive means the body is alive, not that the OID resolves. A
			-- corpse is not a combatant: a killed NPC keeps resolving until
			-- Core3 reaps it, and while it did, a site with one side wiped
			-- still counted as two-sided -- "kept 12 live engagement(s),
			-- 0 capture(s)" for every cycle of a night in which sites were
			-- resolving inside three minutes (measured 2026-09-05). Dead
			-- bodies are left for Core3 to reap; they are simply not counted
			-- and not stood down.
			local pUnit = getSceneObject(oid)
			local alive = false
			if pUnit ~= nil then
				local okd, dead = pcall(function() return CreatureObject(pUnit):isDead() end)
				alive = not (okd and dead)
			end
			local kind = (f[7] == "w") and "w" or nil
			if alive then
				local sl = slots[key]
				sl.alive[faction] = (sl.alive[faction] or 0) + 1
				sl.units[#sl.units + 1] = { oid = oid, faction = faction, kind = kind }
			else
				local ck = tostring(regionId) .. "|" .. tostring(faction)
				-- Slice C: a fallen walker is WALKER_CRATES bodies to the sim.
				casualties[ck] = (casualties[ck] or 0) + ((kind == "w") and WarBattle.WALKER_CRATES or 1)
			end
		end
	end

	local keptRecs, keptOids = {}, {}
	local pendingGarrisons = {}
	local captureSlotsKept = 0

	local function standDown(sl)
		for _, u in ipairs(sl.units) do
			local pObj = getSceneObject(u.oid)
			if pObj ~= nil then
				pcall(function() SceneObject(pObj):destroyObjectFromWorld(false) end)
			end
		end
	end

	-- Pass 1: classify every slot as keep / aged / resolved. Stand-downs are
	-- deferred so that age-outs can be rate-limited (MAX_AGEOUTS_PER_CYCLE)
	-- while resolutions never are.
	local keep, aged, resolved = {}, {}, {}
	for key, sl in pairs(slots) do
		local sides, survivor = 0, nil
		for f, n in pairs(sl.alive) do
			if n > 0 then
				sides = sides + 1
				survivor = f
			end
		end

		local bornKey = "warbattle:born:" .. key
		local born = readData(bornKey)
		if born == nil or born <= 0 then
			born = cycleNo
			writeData(bornKey, born)
		end

		sl.key = key
		sl.sides, sl.survivor = sides, survivor
		sl.bornKey, sl.age = bornKey, cycleNo - born
		sl.isCapture = (string.sub(tostring(sl.site), 1, 1) == "c")
		sl.isGarrison = (sl.site == "0") or sl.isCapture
		-- A garrison is single-faction by definition, so "one side left" is
		-- its healthy state, not a capture.
		local stillContested = sl.isGarrison and (sides >= 1) or (sides >= 2)

		if not stillContested then
			resolved[#resolved + 1] = sl
		elseif sl.age >= WarBattle.MAX_SITE_AGE_CYCLES then
			aged[#aged + 1] = sl
		else
			keep[#keep + 1] = sl
		end
	end

	-- Oldest first, key as the tie-break so the choice is deterministic
	-- (pairs() order is not). Whatever the cap does not take stays held.
	table.sort(aged, function(a, b)
		if a.age ~= b.age then
			return a.age > b.age
		end
		return a.key < b.key
	end)
	for i = 1, #aged do
		if i <= WarBattle.MAX_AGEOUTS_PER_CYCLE then
			resolved[#resolved + 1] = aged[i]
		else
			keep[#keep + 1] = aged[i]
		end
	end

	-- Pass 2a: hold.
	for _, sl in ipairs(keep) do
		if sl.isCapture then
			-- Holds the BATTLE slot it was captured from, so stageBattles()
			-- leaves that ground alone while the garrison stands.
			-- Carries the ORIGIN the NPCs actually stand on, and the fact
			-- that this is captured ground rather than a fight, so that
			-- stageBattles() re-attaches the formup area where the troops
			-- are and does not announce a one-sided garrison as an
			-- engagement.
			heldSites[sl.region .. ":" .. string.sub(tostring(sl.site), 2)] = { ox = sl.ox, oy = sl.oy, capture = true }
			captureSlotsKept = captureSlotsKept + 1
		elseif sl.isGarrison then
			heldGarrisons[sl.region] = true
		else
			-- alive/units ride along so stageBattles() can reinforce a
			-- thinned side (slice A waves) without a second roster walk.
			heldSites[sl.key] = { ox = sl.ox, oy = sl.oy, alive = sl.alive, units = sl.units }
		end

		local oxs = (sl.ox ~= nil) and string.format("%.1f", sl.ox) or ""
		local oys = (sl.oy ~= nil) and string.format("%.1f", sl.oy) or ""
		for _, u in ipairs(sl.units) do
			keptRecs[#keptRecs + 1] = tostring(u.oid) .. "|" .. tostring(sl.region)
				.. "|" .. tostring(sl.site) .. "|" .. tostring(u.faction)
				.. "|" .. oxs .. "|" .. oys .. ((u.kind == "w") and "|w" or "")
			keptOids[#keptOids + 1] = tostring(u.oid)
		end
	end

	-- Pass 2b: resolve (capture, wipe-out, or this cycle's share of age-outs).
	local lostLines = {}
	for _, sl in ipairs(resolved) do
		if (not sl.isGarrison) and sl.sides == 1 and sl.survivor ~= nil then
			captures[#captures + 1] = { region = sl.region, faction = sl.survivor }
			-- D27 slice 2: the other side's line was wiped -- a lost fight.
			for fac, _ in pairs(sl.seen or {}) do
				if fac ~= sl.survivor then
					local lk = tostring(sl.region) .. "|" .. tostring(fac)
					lostLines[lk] = (lostLines[lk] or 0) + 1
				end
			end
			-- The "took a position here" note for WarPresence is written
			-- below, when the winners' garrison actually stands, so that the
			-- garrison aging out can clear it -- a note nothing clears was
			-- "within the hour" for the life of the process.
			-- Spawned AFTER the roster is rewritten below: trackUnit()
			-- appends to ROSTER_KEY, and anything appended before the
			-- rewrite would be thrown away by it.
			pendingGarrisons[#pendingGarrisons + 1] = {
				region = sl.region, site = sl.site, faction = sl.survivor, ox = sl.ox, oy = sl.oy,
			}
		elseif sl.isCapture then
			-- A capture garrison aging out or wiped: the ground is open
			-- again, and the "took a position here" note is stale.
			pcall(function() deleteStringData("warbattle:lastcapture:" .. sl.region) end)
		end
		-- D27 slice 2: a garrison (captured ground or a held town's) with
		-- nobody left standing was wiped: the holder lost a fight here. This
		-- is how a raid on a quiet town becomes a lost fight the sim can
		-- act on when the holder is dry.
		if sl.isGarrison and sl.sides == 0 then
			for fac, _ in pairs(sl.seen or {}) do
				local lk = tostring(sl.region) .. "|" .. tostring(fac)
				lostLines[lk] = (lostLines[lk] or 0) + 1
			end
		end

		standDown(sl)
		writeData(sl.bornKey, 0)
		writeData("warbattle:waves:" .. sl.key .. ":imperial", 0)
		writeData("warbattle:waves:" .. sl.key .. ":rebel", 0)
		for _, fac in ipairs({ "imperial", "rebel" }) do
			writeData("warbattle:retreat:" .. sl.key .. ":" .. fac, 0)
			writeData("warbattle:broke:" .. sl.key .. ":" .. fac, 0)
			writeData("warbattle:sgt:" .. sl.key .. ":" .. fac, 0)
			writeData("warbattle:walkerdown:" .. sl.key .. ":" .. fac, 0)
		end
	end

	writeStringData(WarBattle.ROSTER_KEY, table.concat(keptRecs, ";"))
	writeStringData(WarBattle.OIDS_KEY, table.concat(keptOids, ","))

	-- D27 slice 2: report bodies and lost lines to the sim (warsim/sim/
	-- channels.lua REPORT). No character id: the ground reports, the sim
	-- decides what it costs (economy.lua) and whether a dry town falls
	-- (capture.lua). Sorted so the log reads the same way every cycle.
	WarBattle.report(casualties, "casualty")
	WarBattle.report(lostLines, "site_lost")

	-- Layer 2: the winners hold the ground. Own cap; never touches the front
	-- or spread budgets. Skipped silently when the record predates ox/oy.
	local room = WarBattle.CAPTURE_GARRISON_MAX_SLOTS - captureSlotsKept
	for i = 1, #pendingGarrisons do
		if room <= 0 then
			break
		end
		local pg = pendingGarrisons[i]
		local zone = (WarReport ~= nil) and WarReport.PLANET_OF[pg.region] or nil
		if pg.ox ~= nil and pg.oy ~= nil and zone ~= nil and isZoneEnabled(zone) then
			local n = 0
			pcall(function()
				n = WarBattle.spawnCaptureGarrison(zone, pg.region, pg.faction, pg.ox, pg.oy, pg.site)
			end)
			if n > 0 then
				heldSites[pg.region .. ":" .. tostring(pg.site)] = { ox = pg.ox, oy = pg.oy, capture = true }
				writeData("warbattle:born:" .. pg.region .. ":c" .. tostring(pg.site), cycleNo)
				-- Ground changed hands here and the winners are standing on
				-- it: news on arrival, timestamped so the note expires on its
				-- own (WarPresence.CAPTURE_NOTE_MS) even if this garrison
				-- never reaches its age-out.
				writeStringData("warbattle:lastcapture:" .. pg.region, tostring(pg.faction))
				writeData("warbattle:lastcapture_ms:" .. pg.region, getTimestampMilli())
				room = room - 1
			end
		end
	end

	return heldSites, heldGarrisons, captures
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
--- The furthest of APPROACH_DISTANCE_M, 48 and 24 m along the radial whose
-- point is on the navmesh (isPointWalkable, B21), so the attacking line
-- forms up where an advance can actually be walked. Measured 2026-09-05:
-- Mos Eisley's site ring sits at SITE_RADIUS_MAX (130 m) and 80 m further
-- out is past the city's meshed edge -- its attackers stood at exactly 80 m
-- with following=6 and hurt=0 for three minutes while Kaadara and Doaba,
-- whose approach points are meshed, resolved every site in that time.
-- Logs once per site when it has to pull in. 24 m is still outside the
-- site (the defenders stand on a TROOPER_GAP_M line at the origin) and
-- inside rifle range, so a fight starts even where nothing can path.
function WarBattle.formUpDistance(zone, originX, originY, ux, uy, regionId, siteIndex)
	if type(isPointWalkable) ~= "function" or type(getWorldFloor) ~= "function" then
		return WarBattle.APPROACH_DISTANCE_M
	end
	local candidates = { WarBattle.APPROACH_DISTANCE_M, 48, 24 }
	for i = 1, #candidates do
		local d = candidates[i]
		local x, y = originX + ux * d, originY + uy * d
		local okz, z = pcall(getWorldFloor, x, y, zone)
		if okz and type(z) == "number" then
			local ok, walkable = pcall(isPointWalkable, zone, x, z, y)
			if ok and walkable == true then
				if i > 1 then
					printf(string.format("WarBattle: %s site %s forms up at %d m (the %d m approach point is off the navmesh)\n",
						tostring(regionId), tostring(siteIndex), d, WarBattle.APPROACH_DISTANCE_M))
				end
				return d
			end
		end
	end
	printf(string.format("WarBattle: %s site %s -- no meshed form-up point on the radial; using 24 m\n",
		tostring(regionId), tostring(siteIndex)))
	return 24
end

--- Approach geometry for a site: the outward unit vector ux,uy from the
-- town centre through the site origin, its perpendicular px,py, and the
-- attackers' form-up point along it (formUpDistance). Shared by spawnSite
-- and the wave spawner so reinforcements arrive where the line formed up.
function WarBattle.siteGeometry(zone, regionId, siteIndex, originX, originY)
	local townX, townY = originX, originY
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	if coords ~= nil then
		townX, townY = coords[1], coords[2]
	end
	local ux, uy = originX - townX, originY - townY
	local len = math.sqrt((ux * ux) + (uy * uy))
	if len < 1 then
		ux, uy, len = 1, 0, 1
	end
	ux, uy = ux / len, uy / len
	local approach = WarBattle.formUpDistance(zone, originX, originY, ux, uy, regionId, siteIndex)
	return ux, uy, -uy, ux, approach, originX + (ux * approach), originY + (uy * approach)
end

--- The role the i-th body of a line plays.
local function roleAt(i)
	return WarBattle.LINE_PATTERN[i] or "rifleman"
end

--- Spawn one body of `faction` in `role` at x,y. Tries the war template
-- for the role, then falls back to the stock pool (TROOPS) so a server
-- that has not restarted since the templates landed still fields a line.
--- The world floor at x,y (terrain or the building/bridge on it), or 0
-- when the binding is missing. A body spawned at z=0 under a raised city
-- (Theed's ground is 6 m up) has no line of sight to anything and never
-- fires -- measured 2026-09-05.
function WarBattle.floorAt(zone, x, y)
	if type(getWorldFloor) ~= "function" then
		return 0
	end
	local ok, z = pcall(getWorldFloor, x, y, zone)
	if ok and type(z) == "number" then
		return z
	end
	return 0
end

--- The first of `candidates` (metres along ux,uy from originX,originY)
-- whose point is on the navmesh, as (distance, x, y, z); nil when none is.
function WarBattle.walkableAlong(zone, originX, originY, ux, uy, candidates)
	if type(isPointWalkable) ~= "function" then
		local d = candidates[1]
		local x, y = originX + ux * d, originY + uy * d
		return d, x, y, WarBattle.floorAt(zone, x, y)
	end
	for i = 1, #candidates do
		local d = candidates[i]
		local x, y = originX + ux * d, originY + uy * d
		local z = WarBattle.floorAt(zone, x, y)
		local ok, walkable = pcall(isPointWalkable, zone, x, z, y)
		if ok and walkable == true then
			return d, x, y, z
		end
	end
	return nil
end

local function spawnTroop(zone, faction, role, x, y, heading, salt, i)
	local pool = WarBattle.ROLES[faction]
	local template = (WarBattle.ROLES_ENABLED and pool ~= nil) and pool[role] or nil
	local z = WarBattle.floorAt(zone, x, y)
	local p = template and spawnMobile(zone, template, 0, x, z, y, heading, 0) or nil
	if p == nil then
		local fallback = pickTemplate(faction, i, salt)
		p = fallback and spawnMobile(zone, fallback, 0, x, z, y, heading, 0) or nil
	end
	return p
end

--- A line's sergeant, if one stands. Slot key is "<region>:<site>".
local function sergeantOf(slotKey, faction)
	local oid = readData("warbattle:sgt:" .. slotKey .. ":" .. faction)
	if oid == nil or oid <= 0 then
		return nil
	end
	local p = getSceneObject(oid)
	if p == nil then
		return nil
	end
	local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
	if okd and dead then
		return nil
	end
	return p
end

--- Battle chatter through a body (the sergeant when there is one). Never
-- throws; a missing voice line says nothing.
local function shout(pBody, kind, faction, officer)
	if pBody == nil or WarVoice == nil or WarVoice.battle == nil then
		return
	end
	local line = WarVoice.battle(kind, faction, officer)
	if line ~= nil then
		pcall(function() spatialChat(pBody, line) end)
		printf("WarBattle: " .. tostring(faction) .. " says: " .. line .. "\n")
	end
end

--- The sim's exported officer for the DEFENDING side at a front, by name.
local function officerAt(regionId)
	local st = (WarReport ~= nil) and WarReport.state() or nil
	if st == nil or type(st.fronts) ~= "table" then
		return nil
	end
	for i = 1, #st.fronts do
		local f = st.fronts[i]
		if f ~= nil and f.region == regionId then
			return f.officer
		end
	end
	return nil
end

--- Where the i-th body of a line stands. Defenders form ranks of
-- LINE_RANK along the site's x axis, ranks stepping back in y; attackers
-- form ranks abreast across the radial at the approach point, ranks
-- stepping outward along it.
local function linePosition(i, isAttacker, originX, originY, ux, uy, px, py, approachX, approachY, lineSize)
	local perRank = math.min(WarBattle.LINE_RANK, lineSize)
	local rank = math.floor((i - 1) / perRank)
	local col = (i - 1) % perRank
	if not isAttacker then
		return originX + col * WarBattle.TROOPER_GAP_M, originY + rank * WarBattle.TROOPER_GAP_M
	end
	local halfRow = (perRank - 1) / 2
	local offset = (col - halfRow) * WarBattle.TROOPER_GAP_M
	local back = rank * WarBattle.TROOPER_GAP_M
	return approachX + (offset * px) + (ux * back), approachY + (offset * py) + (uy * back)
end

--- Set `pBody` on `pTarget` and WAKE ITS AI. MEASURED 2026-09-05:
-- AiAgent:setDefender / setFollowObject set the combat state, the follow
-- target and FOLLOWING, but never schedule the agent's behaviour event
-- (AiAgentImplementation::activateAiBehavior does that, and nothing on the
-- setDefender path calls it for an NPC set on an NPC with no player in
-- range). Every "24 in combat, nobody hurt, no weapon drawn" site was that;
-- the sites that resolved were woken by chance (notifyDissapear -- any
-- despawn in range -- calls activateAiBehavior on every agent nearby).
-- LuaAiAgent:executeBehavior() is the wake-up; with a follow object set,
-- the no-players gate passes and the tree runs. `follow` = advance on the
-- target (attackers); defenders stand and fire. The target is set back on
-- the body and woken too, so a standing line answers the first shot.
--- Slice D: is this body under a player's command? war_command.lua keeps
-- the record; waves, retreats and the stuck rule leave such a body alone.
function WarBattle.isCommanded(oid)
	if WarCommand == nil or WarCommand.isCommanded == nil or oid == nil then
		return false
	end
	local ok, c = pcall(WarCommand.isCommanded, oid)
	return ok and c == true
end

function WarBattle.engage(pBody, pTarget, follow)
	if pBody == nil or pTarget == nil then
		return
	end
	pcall(function() AiAgent(pBody):setDefender(pTarget) end)
	if follow then
		pcall(function() AiAgent(pBody):setFollowObject(pTarget) end)
	end
	pcall(function() AiAgent(pBody):executeBehavior() end)
	pcall(function() AiAgent(pTarget):setDefender(pBody) end)
	pcall(function() AiAgent(pTarget):executeBehavior() end)
end

--- Slice A: a reinforcement wave of `count` bodies for `faction` at an
-- existing site -- defenders at the site origin, attackers at the approach
-- point -- set on `enemies` (live enemy bodies from the roster). Returns
-- the number fielded.
local function spawnWave(zone, regionId, siteIndex, faction, isAttacker, originX, originY, count, enemies, friends)
	local ux, uy, px, py, approach, approachX, approachY =
		WarBattle.siteGeometry(zone, regionId, siteIndex, originX, originY)
	local slotKey = regionId .. ":" .. tostring(siteIndex)
	local sergeant = sergeantOf(slotKey, faction)
	local fielded, bodies = 0, {}
	for i = 1, count do
		local role = (i == 1) and "medic" or "rifleman"
		local x, y = linePosition(i, isAttacker, originX, originY, ux, uy, px, py, approachX, approachY, count)
		local p = spawnTroop(zone, faction, role, x, y, isAttacker and 180 or 0,
			regionId .. "s" .. tostring(siteIndex) .. (isAttacker and "wa" or "wd"), i + 50)
		if p ~= nil then
			fielded = fielded + 1
			bodies[#bodies + 1] = p
			trackUnit(SceneObject(p):getObjectID(), regionId, siteIndex, faction, originX, originY)
			if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(p) end
			if WarCommand ~= nil and WarCommand.attach ~= nil then WarCommand.attach(p) end
			if isAttacker then
				pcall(function() AiAgent(p):setHomeLocation(originX, 0, originY, nil) end)
			end
		end
	end
	if #enemies > 0 then
		-- The wave and the survivors alike: set on the enemy (survivors a
		-- player commands excepted -- slice D), attackers following.
		local everyone = {}
		for _, p in ipairs(bodies) do everyone[#everyone + 1] = p end
		for _, p in ipairs(friends or {}) do
			if not WarBattle.isCommanded(SceneObject(p):getObjectID()) then everyone[#everyone + 1] = p end
		end
		for i, p in ipairs(everyone) do
			WarBattle.engage(p, enemies[((i - 1) % #enemies) + 1], isAttacker)
		end
	end
	if fielded > 0 then
		shout(bodies[1], "wave", faction, (not isAttacker) and officerAt(regionId) or nil)
	end
	if isAttacker and fielded > 0 then
		createEvent(WarBattle.STALL_CHECK_MS, "WarBattle", "checkAdvance", nil,
			table.concat({ regionId, tostring(siteIndex), faction,
				string.format("%.2f", originX), string.format("%.2f", originY),
				string.format("%.4f", ux), string.format("%.4f", uy), string.format("%.1f", approach) }, "|"))
	end
	return fielded
end

--- Slice B: every live two-sided battle slot from the roster, with alive
-- counts and live bodies per faction. No roster rewrite, no reports --
-- reconcile() owns those; this is a read for the tend pass.
function WarBattle.liveSlots()
	local slots = {}
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		return slots
	end
	for rec in string.gmatch(raw, "([^;]+)") do
		local f = {}
		for field in string.gmatch(rec .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		local oid, regionId, siteIndex, faction = tonumber(f[1]), f[2], f[3], f[4]
		local ox, oy = tonumber(f[5]), tonumber(f[6])
		if oid ~= nil and regionId ~= nil and regionId ~= "" and siteIndex ~= nil and siteIndex ~= "" then
			local key = regionId .. ":" .. siteIndex
			local sl = slots[key]
			if sl == nil then
				sl = { key = key, region = regionId, site = siteIndex, alive = {}, units = {}, seen = {}, hurt = 0, dead = 0, inCombat = 0, walkerDown = {} }
				slots[key] = sl
			end
			if ox ~= nil and oy ~= nil and sl.ox == nil then sl.ox, sl.oy = ox, oy end
			sl.seen[faction] = true
			local p = getSceneObject(oid)
			if p ~= nil then
				local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
				if okd and dead then
					sl.dead = sl.dead + 1
					if f[7] == "w" then sl.walkerDown[faction] = true end
				else
					sl.alive[faction] = (sl.alive[faction] or 0) + 1
					sl.units[#sl.units + 1] = { oid = oid, faction = faction, p = p, kind = (f[7] == "w") and "w" or nil }
					-- Hurt = health below its maximum. NPCs do not heal in
					-- combat, so "nobody hurt" means "nobody has fired".
					local okh, h = pcall(function()
						local c = CreatureObject(p)
						return c:getHAM(0) < c:getMaxHAM(0)
					end)
					if okh and h then sl.hurt = sl.hurt + 1 end
					local okc, inc = pcall(function() return CreatureObject(p):isInCombat() end)
					if okc and inc then sl.inCombat = sl.inCombat + 1 end
				end
			end
		end
	end
	return slots
end

--- Slice B: fall back and regroup. Survivors of `faction` at a slot are
-- moved to their own form-up ranks and taken out of the fight until the
-- next wave re-engages them. Once per RETREAT_COOLDOWN_MS per side.
local function retreatSide(zone, sl, faction, isAttacker, lineSize)
	local key = "warbattle:retreat:" .. sl.key .. ":" .. faction
	local last = readData(key) or 0
	local nowMs = getTimestampMilli()
	if last > 0 and (nowMs - last) < WarBattle.RETREAT_COOLDOWN_MS then
		return false
	end
	local ux, uy, px, py, approach, approachX, approachY =
		WarBattle.siteGeometry(zone, sl.region, sl.site, sl.ox, sl.oy)
	local i = 0
	for _, u in ipairs(sl.units) do
		if u.faction == faction and not WarBattle.isCommanded(u.oid) then
			i = i + 1
			local x, y = linePosition(i, isAttacker, sl.ox, sl.oy, ux, uy, px, py, approachX, approachY, lineSize)
			local z = 0
			if type(getWorldFloor) == "function" then
				local okz, zz = pcall(getWorldFloor, x, y, zone)
				if okz and type(zz) == "number" then z = zz end
			end
			pcall(function() AiAgent(u.p):removeDefenders() end)
			pcall(function() SceneObject(u.p):teleport(x, z, y, 0) end)
		end
	end
	writeData(key, nowMs)
	shout(sergeantOf(sl.key, faction) or (sl.units[1] and sl.units[1].p), "fallback", faction,
		(not isAttacker) and officerAt(sl.region) or nil)
	printf(string.format("WarBattle: %s fell back at %s site %s (%d left of %d)\n",
		tostring(faction), tostring(sl.region), tostring(sl.site), i, lineSize))
	return true
end

--- Stuck sites. Returns true when the site broke off this pass (its bodies
-- are gone). See STUCK_PASSES.
function WarBattle.tendStuck(zone, sl, holder, attacker)
	-- Quiet: nobody at the site is in combat (verifier, 2026-09-05: the
	-- first rule, "nobody hurt and nobody dead", never fired once a single
	-- wounded body survived, and a line released from a player's command
	-- with no targets stood frozen for good), or the older sign of a line
	-- that never fired at all.
	local quiet = (sl.inCombat == 0) or (sl.hurt == 0 and sl.dead == 0)
	local qkey = "warbattle:quiet:" .. sl.key
	local lkey = "warbattle:stuck:" .. sl.key
	if not quiet then
		writeData(qkey, 0)
		return false
	end
	-- The bodies this rule may move: not the ones a player commands. With
	-- either side entirely commanded there is nothing for the rule to do,
	-- and it must not advance its level (verifier, 2026-09-05).
	local defenders, attackers, commanded = {}, {}, 0
	for _, u in ipairs(sl.units) do
		if WarBattle.isCommanded(u.oid) then
			commanded = commanded + 1
		elseif u.faction == attacker then
			attackers[#attackers + 1] = u.p
		else
			defenders[#defenders + 1] = u.p
		end
	end
	if #attackers == 0 or #defenders == 0 then
		writeData(qkey, 0)
		return false
	end
	local passes = (readData(qkey) or 0) + 1
	writeData(qkey, passes)
	if passes < WarBattle.STUCK_PASSES then
		return false
	end
	writeData(qkey, 0)
	local level = (readData(lkey) or 0) + 1
	-- A site with a commanded body never breaks off: the close is retried.
	if level >= 2 and commanded > 0 then
		level = 1
	end
	writeData(lkey, level)

	if level == 1 then
		-- Close the attackers to STUCK_CLOSE_M of the defenders' line, on
		-- walkable ground, everyone at the floor, and set them on each other.
		local ux, uy, px, py = WarBattle.siteGeometry(zone, sl.region, sl.site, sl.ox, sl.oy)
		local d = WarBattle.walkableAlong(zone, sl.ox, sl.oy, ux, uy, { WarBattle.STUCK_CLOSE_M, 16, 24 })
			or WarBattle.STUCK_CLOSE_M
		local baseX, baseY = sl.ox + ux * d, sl.oy + uy * d
		for i, p in ipairs(defenders) do
			local so = SceneObject(p)
			local x, y = so:getWorldPositionX(), so:getWorldPositionY()
			pcall(function() so:teleport(x, WarBattle.floorAt(zone, x, y), y, 0) end)
		end
		local halfLine = (#attackers - 1) / 2
		for i, p in ipairs(attackers) do
			local offset = (i - 1 - halfLine) * WarBattle.TROOPER_GAP_M
			local x, y = baseX + offset * px, baseY + offset * py
			pcall(function() SceneObject(p):teleport(x, WarBattle.floorAt(zone, x, y), y, 0) end)
		end
		for i, p in ipairs(attackers) do
			WarBattle.engage(p, defenders[((i - 1) % #defenders) + 1], true)
		end
		for i, p in ipairs(defenders) do
			WarBattle.engage(p, attackers[((i - 1) % #attackers) + 1], false)
		end
		shout(sergeantOf(sl.key, attacker) or attackers[1], "contact", attacker, nil)
		printf(string.format("WarBattle: %s site %s quiet for %d passes (nobody hurt); attackers closed to %d m\n",
			tostring(sl.region), tostring(sl.site), WarBattle.STUCK_PASSES, d))
		return false
	end

	-- Still quiet after closing: no ground here. Break the site off (no
	-- capture, no report) and turn the region's ring for the next cycle.
	local turns = ((readData("warbattle:siteturn:" .. sl.region) or 0) + 1) % math.floor(360 / WarBattle.SITE_TURN_DEG)
	writeData("warbattle:siteturn:" .. sl.region, turns)
	writeData(lkey, 0)
	-- Off the roster FIRST: reconcile() reports every roster body that is
	-- dead or gone as a casualty, and nobody died here.
	WarBattle.dropSlot(sl.key)
	local removed = 0
	for _, u in ipairs(sl.units) do
		local ok = pcall(function() SceneObject(u.p):destroyObjectFromWorld(false) end)
		if ok then removed = removed + 1 end
	end
	printf(string.format("WarBattle: %s site %s stuck (nobody hurt after closing); broke off, %d bodies gone, ring turned to %d x %d deg\n",
		tostring(sl.region), tostring(sl.site), removed, turns, WarBattle.SITE_TURN_DEG))
	return true
end

--- Remove one slot's records from the roster and reset its per-slot keys,
-- the way reconcile() does for a resolved slot -- without any report. The
-- bodies stay in OIDS_KEY, so clear() still owns whatever is left of them.
function WarBattle.dropSlot(key)
	local raw = readStringData(WarBattle.ROSTER_KEY)
	local kept = {}
	if raw ~= nil and raw ~= "" then
		for rec in string.gmatch(raw, "([^;]+)") do
			local region, site = string.match(rec, "^%d+|([%w_]+)|([%w_]+)")
			if region == nil or (region .. ":" .. site) ~= key then
				kept[#kept + 1] = rec
			end
		end
	end
	writeStringData(WarBattle.ROSTER_KEY, table.concat(kept, ";"))
	writeData("warbattle:born:" .. key, 0)
	for _, fac in ipairs({ "imperial", "rebel" }) do
		writeData("warbattle:waves:" .. key .. ":" .. fac, 0)
		writeData("warbattle:retreat:" .. key .. ":" .. fac, 0)
		writeData("warbattle:broke:" .. key .. ":" .. fac, 0)
		writeData("warbattle:sgt:" .. key .. ":" .. fac, 0)
		writeData("warbattle:walkerdown:" .. key .. ":" .. fac, 0)
	end
end

--- Slice B: one tend pass over every live battle -- retreats, then waves.
-- Returns bodies spawned. Called by tendSites() on its own timer and by
-- the warTendNow probe.
function WarBattle.tendOnce()
	if not WarBattle.WAVES_ENABLED then
		return 0
	end
	local st = (WarReport ~= nil) and WarReport.state() or nil
	if st == nil then
		return 0
	end
	local fronts = {}
	for _, f in ipairs(WarBattle.fronts()) do fronts[f.id] = f end

	-- Slice D: commanders who died, left or dropped overt lose their squad.
	if WarCommand ~= nil and WarCommand.tickOnce ~= nil then
		local okc, errc = pcall(WarCommand.tickOnce)
		if not okc then printf("WarBattle: WarCommand.tickOnce failed: " .. tostring(errc) .. "\n") end
	end

	local slots = WarBattle.liveSlots()
	local keys = {}
	for k, _ in pairs(slots) do keys[#keys + 1] = k end
	table.sort(keys)

	-- Slice E: barrages at offensives, flares over besieged capitals.
	if WarEffects ~= nil and WarEffects.tickOnce ~= nil then
		local oke, erre = pcall(WarEffects.tickOnce, slots, fronts, false)
		if not oke then printf("WarBattle: WarEffects.tickOnce failed: " .. tostring(erre) .. "\n") end
	end

	local budget = WarBattle.TEND_NPC_BUDGET
	local spawned = 0
	for _, key in ipairs(keys) do
		local sl = slots[key]
		local isGarrison = (sl.site == "0") or (string.sub(tostring(sl.site), 1, 1) == "c")
		local r = st.regions[sl.region]
		local zone = (WarReport ~= nil) and WarReport.PLANET_OF[sl.region] or nil
		if (not isGarrison) and r ~= nil and zone ~= nil and sl.ox ~= nil then
			local holder = r.faction
			local f = fronts[sl.region]
			local attacker = (f ~= nil and f.attacker ~= nil) and f.attacker or ((holder == "rebel") and "imperial" or "rebel")
			local lineSize = (f ~= nil and f.offensive == true) and WarBattle.LINE_SIZE_OFFENSIVE or WarBattle.LINE_SIZE
			local aH, aA = sl.alive[holder] or 0, sl.alive[attacker] or 0
			if aH > 0 and aA > 0 and WarBattle.tendStuck(zone, sl, holder, attacker) then
				aH, aA = 0, 0 -- the site broke off this pass; nothing to reinforce
			end
			if aH > 0 and aA > 0 then
				local sides = {
					{ faction = holder, isAttacker = false, alive = aH, enemy = aA },
					{ faction = attacker, isAttacker = true, alive = aA, enemy = aH },
				}
				for _, side in ipairs(sides) do
					local wkey = "warbattle:waves:" .. sl.key .. ":" .. side.faction
					local used = readData(wkey) or 0
					local wavesLeft = used < WarBattle.WAVES_MAX_PER_SIDE
					-- Slice C: the walker fell -- said once per side per site.
					if sl.walkerDown[side.faction] then
						local dkey = "warbattle:walkerdown:" .. sl.key .. ":" .. side.faction
						if (readData(dkey) or 0) == 0 then
							writeData(dkey, 1)
							shout(sergeantOf(sl.key, side.faction) or (sl.units[1] and sl.units[1].p), "walker_down", side.faction, nil)
							printf(string.format("WarBattle: %s walker down at %s site %s\n",
								tostring(side.faction), tostring(sl.region), tostring(sl.site)))
						end
					end
					-- retreat: thin, outmatched, and a wave still due
					if wavesLeft and side.alive <= WarBattle.RETREAT_FRAC * lineSize
							and side.enemy >= WarBattle.RETREAT_ENEMY_FRAC * lineSize then
						pcall(retreatSide, zone, sl, side.faction, side.isAttacker, lineSize)
					end
					-- breaking: thin and nothing left to send
					if (not wavesLeft) and side.alive <= WarBattle.RETREAT_FRAC * lineSize then
						local bkey = "warbattle:broke:" .. sl.key .. ":" .. side.faction
						if (readData(bkey) or 0) == 0 then
							writeData(bkey, 1)
							shout(sergeantOf(sl.key, side.faction) or (sl.units[1] and sl.units[1].p), "breaking", side.faction, nil)
						end
					end
					-- wave
					if wavesLeft and side.alive <= WarBattle.WAVE_TRIGGER_FRAC * lineSize then
						local waveSize = math.min(math.ceil(WarBattle.WAVE_SIZE_FRAC * lineSize), lineSize - side.alive)
						if waveSize > 0 and budget - spawned >= waveSize then
							local enemies, friends = {}, {}
							for _, u in ipairs(sl.units) do
								if u.faction == side.faction then friends[#friends + 1] = u.p else enemies[#enemies + 1] = u.p end
							end
							local okn, n = pcall(spawnWave, zone, sl.region, sl.site, side.faction, side.isAttacker,
								sl.ox, sl.oy, waveSize, enemies, friends)
							if okn and n and n > 0 then
								writeData(wkey, used + 1)
								spawned = spawned + n
								printf(string.format("WarBattle: wave %d/%d for %s at %s site %s: +%d (had %d of %d)\n",
									used + 1, WarBattle.WAVES_MAX_PER_SIDE, tostring(side.faction), tostring(sl.region),
									tostring(sl.site), n, side.alive, lineSize))
							elseif not okn then
								printf("WarBattle: spawnWave failed: " .. tostring(n) .. "\n")
							end
						end
					end
				end
			end
		end
	end
	return spawned
end

function WarBattle:tendSites()
	local ok, err = pcall(WarBattle.tendOnce)
	if not ok then
		printf("WarBattle: tendSites failed: " .. tostring(err) .. "\n")
	end
	createEvent(WarBattle.TEND_INTERVAL_MS, "WarBattle", "tendSites", nil, "")
end

--- One tend pass, now, without touching the timer chain.
function Tests:warTendNow()
	printf("WARTEND: begin\n")
	local ok, n = pcall(WarBattle.tendOnce)
	printf("WARTEND: " .. (ok and (tostring(n) .. " body(ies) spawned") or ("failed: " .. tostring(n))) .. "\n")
	printf("WARTEND: end\n")
end

--- Slice A: reinforce a held (live) site's thinned sides. `held` is
-- reconcile's slot record (alive/units). Returns bodies spawned.
local function reinforceSite(zone, regionId, siteIndex, holder, attacker, held, lineSize, budgetLeft)
	if not WarBattle.WAVES_ENABLED or type(held) ~= "table" or held.alive == nil or held.units == nil then
		return 0
	end
	local slotKey = regionId .. ":" .. tostring(siteIndex)
	local spawned = 0
	local trigger = WarBattle.WAVE_TRIGGER_FRAC * lineSize
	local waveSize = math.ceil(WarBattle.WAVE_SIZE_FRAC * lineSize)
	for _, side in ipairs({ { faction = holder, isAttacker = false }, { faction = attacker, isAttacker = true } }) do
		local alive = held.alive[side.faction] or 0
		local key = "warbattle:waves:" .. slotKey .. ":" .. side.faction
		local used = readData(key) or 0
		if alive > 0 and alive <= trigger and used < WarBattle.WAVES_MAX_PER_SIDE and budgetLeft - spawned >= waveSize then
			local enemies, friends = {}, {}
			for _, u in ipairs(held.units) do
				local p = getSceneObject(u.oid)
				if p ~= nil then
					if u.faction ~= side.faction then enemies[#enemies + 1] = p else friends[#friends + 1] = p end
				end
			end
			local room = math.min(waveSize, lineSize - alive)
			local n = spawnWave(zone, regionId, siteIndex, side.faction, side.isAttacker, held.ox, held.oy, room, enemies, friends)
			if n > 0 then
				writeData(key, used + 1)
				spawned = spawned + n
				printf(string.format("WarBattle: wave %d/%d for %s at %s site %s: +%d (had %d of %d)\n",
					used + 1, WarBattle.WAVES_MAX_PER_SIDE, tostring(side.faction), tostring(regionId),
					tostring(siteIndex), n, alive, lineSize))
			end
		end
	end
	return spawned
end

--- Slice C: which walker template each side of a front fields, or nil for
-- none. `front` is a WarBattle.fronts() entry.
function WarBattle.walkersFor(front, regionId, defenderFaction, attackerFaction)
	if not WarBattle.WALKERS_ENABLED or front == nil then
		return nil
	end
	local hot = (tonumber(front.intensity) or 0) >= WarBattle.WALKER_INTENSITY or front.offensive == true
	if not hot then
		return nil
	end
	local st = (WarReport ~= nil) and WarReport.state() or nil
	local r = (st ~= nil) and st.regions[regionId] or nil
	local siege = r ~= nil and r.is_capital == true and type(r.siege) == "table" and r.siege.active == true
	local attackerTpl = WarBattle.WALKERS[attackerFaction]
	if siege and attackerFaction == "imperial" then
		attackerTpl = WarBattle.WALKERS.siege
	end
	return { defender = WarBattle.WALKERS[defenderFaction], attacker = attackerTpl }
end

--- Spawn one walker for `faction` WALKER_BACK_M behind its line, set on
-- `enemies`. Tracked with the "w" mark. Returns the pointer or nil.
local function spawnWalker(zone, regionId, siteIndex, faction, isAttacker, template, originX, originY,
		ux, uy, approachX, approachY, enemies)
	if template == nil or template == "" then
		return nil
	end
	local x, y
	if isAttacker then
		x, y = approachX + ux * WarBattle.WALKER_BACK_M, approachY + uy * WarBattle.WALKER_BACK_M
	else
		x, y = originX - ux * WarBattle.WALKER_BACK_M, originY - uy * WarBattle.WALKER_BACK_M
	end
	local p = spawnMobile(zone, template, 0, x, WarBattle.floorAt(zone, x, y), y, isAttacker and 180 or 0, 0)
	if p == nil then
		printf(string.format("WarBattle: walker %s did not spawn at %s site %s (template not loaded?)\n",
			tostring(template), tostring(regionId), tostring(siteIndex)))
		return nil
	end
	trackUnit(SceneObject(p):getObjectID(), regionId, siteIndex, faction, originX, originY, "w")
	if isAttacker then
		pcall(function() AiAgent(p):setHomeLocation(originX, 0, originY, nil) end)
	end
	if enemies ~= nil and #enemies > 0 then
		WarBattle.engage(p, enemies[1], isAttacker)
	end
	return p
end

local function spawnSite(zone, regionId, siteIndex, defenderFaction, attackerFaction, originX, originY, lineSize, walkers)
	lineSize = lineSize or WarBattle.LINE_SIZE
	local defenders, attackers = {}, {}

	-- Approach geometry. The site already sits on a radial out from the town
	-- centre (siteOrigin), so pushing further along that same radial puts the
	-- attackers outside the town rather than in it, on the natural line of
	-- advance. ux,uy is that outward unit vector; px,py is perpendicular to
	-- it, used to spread the attacking line abreast across the approach
	-- instead of strung out along it.
	local townX, townY = originX, originY
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	if coords ~= nil then
		townX, townY = coords[1], coords[2]
	end

	local ux, uy = originX - townX, originY - townY
	local len = math.sqrt((ux * ux) + (uy * uy))
	if len < 1 then
		-- Site sits on the town centre (or no coords): pick an arbitrary but
		-- stable radial so the attackers still come from somewhere outside.
		ux, uy, len = 1, 0, 1
	end
	ux, uy = ux / len, uy / len
	local px, py = -uy, ux

	local approach = WarBattle.formUpDistance(zone, originX, originY, ux, uy, regionId, siteIndex)
	local approachX = originX + (ux * approach)
	local approachY = originY + (uy * approach)

	local slotKey = regionId .. ":" .. tostring(siteIndex)
	for i = 1, lineSize do
		-- Ranks (slice A): defenders in ranks along the site, attackers in
		-- ranks abreast across the approach. Roles (slice B) by position.
		local dx, dy = linePosition(i, false, originX, originY, ux, uy, px, py, approachX, approachY, lineSize)
		local ax, ay = linePosition(i, true, originX, originY, ux, uy, px, py, approachX, approachY, lineSize)
		local role = roleAt(i)

		local pD = spawnTroop(zone, defenderFaction, role, dx, dy, 0, regionId .. "s" .. siteIndex .. "d", i)
		local pA = spawnTroop(zone, attackerFaction, role, ax, ay, 180, regionId .. "s" .. siteIndex .. "a", i)
		if i == 1 then
			if pD ~= nil then writeData("warbattle:sgt:" .. slotKey .. ":" .. defenderFaction, SceneObject(pD):getObjectID()) end
			if pA ~= nil then writeData("warbattle:sgt:" .. slotKey .. ":" .. attackerFaction, SceneObject(pA):getObjectID()) end
		end

		if WarCommand ~= nil and WarCommand.attach ~= nil then
			WarCommand.attach(pD)
			WarCommand.attach(pA)
		end
		if pD ~= nil then
			defenders[#defenders + 1] = pD
			trackUnit(SceneObject(pD):getObjectID(), regionId, siteIndex, defenderFaction, originX, originY)
			-- Healing this NPC feeds war materiel: B11's ruling wants a path
			-- for non-combatants, and a Medic had none. See war_heal.lua.
			-- The observer dies with the object, which cleanup already reaps.
			if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(pD) end
		end
		if pA ~= nil then
			attackers[#attackers + 1] = pA
			trackUnit(SceneObject(pA):getObjectID(), regionId, siteIndex, attackerFaction, originX, originY)
			-- Home is the objective, not the form-up point -- see
			-- APPROACH_DISTANCE_M for the leash rule this satisfies.
			pcall(function() AiAgent(pA):setHomeLocation(originX, 0, originY, nil) end)
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
	for i = 1, #attackers do
		-- Each attacker follows its own target (the advance); the defender
		-- is set back on it. Both woken -- see WarBattle.engage.
		WarBattle.engage(attackers[i], defenders[((i - 1) % #defenders) + 1], true)
	end
	-- And every defender on an attacker, so a line longer than the one
	-- facing it has nobody left asleep (verifier, 2026-09-05).
	for i = 1, #defenders do
		WarBattle.engage(defenders[i], attackers[((i - 1) % #attackers) + 1], false)
	end
	shout(attackers[1], "contact", attackerFaction, nil)
	shout(defenders[1], "hold", defenderFaction, officerAt(regionId))

	-- Slice C: walkers behind the lines.
	local walkersUp = 0
	if type(walkers) == "table" then
		local pW = spawnWalker(zone, regionId, siteIndex, defenderFaction, false, walkers.defender,
			originX, originY, ux, uy, approachX, approachY, attackers)
		if pW ~= nil then
			walkersUp = walkersUp + 1
			shout(defenders[1], "walker", defenderFaction, nil)
		end
		pW = spawnWalker(zone, regionId, siteIndex, attackerFaction, true, walkers.attacker,
			originX, originY, ux, uy, approachX, approachY, defenders)
		if pW ~= nil then
			walkersUp = walkersUp + 1
			shout(attackers[1], "walker", attackerFaction, nil)
		end
		if walkersUp > 0 then
			printf(string.format("WarBattle: %s site %s fields %d walker(s)\n",
				tostring(regionId), tostring(siteIndex), walkersUp))
		end
	end

	-- One-shot: did they actually advance? See STALL_CHECK_MS.
	createEvent(WarBattle.STALL_CHECK_MS, "WarBattle", "checkAdvance", nil,
		table.concat({ regionId, tostring(siteIndex), attackerFaction,
			string.format("%.2f", originX), string.format("%.2f", originY),
			string.format("%.4f", ux), string.format("%.4f", uy), string.format("%.1f", approach) }, "|"))

	return #defenders + #attackers + walkersUp
end

--- Scheduled STALL_CHECK_MS after a site is staged. If most of the attacking
-- line is still at its form-up distance, it is moved to STALL_FALLBACK_M
-- along the same radial, spread abreast, and set on the defenders again.
function WarBattle:checkAdvance(pObj, args)
	local ok, err = pcall(function()
		local f = {}
		for field in string.gmatch(tostring(args) .. "|", "([^|]*)|") do
			f[#f + 1] = field
		end
		local regionId, siteIndex, attackerFaction = f[1], f[2], f[3]
		local originX, originY = tonumber(f[4]), tonumber(f[5])
		local ux, uy, approach = tonumber(f[6]), tonumber(f[7]), tonumber(f[8])
		if regionId == nil or originX == nil or ux == nil or approach == nil then
			return
		end
		local zone = (WarReport ~= nil) and WarReport.PLANET_OF[regionId] or nil
		if zone == nil then
			return
		end

		local raw = readStringData(WarBattle.ROSTER_KEY)
		if raw == nil or raw == "" then
			return
		end
		local attackers, defenders = {}, {}
		for rec in string.gmatch(raw, "([^;]+)") do
			local oid, region, site, fac = string.match(rec, "^(%d+)|([%w_]+)|([%w_]+)|([%w_]+)")
			if oid ~= nil and region == regionId and site == siteIndex then
				local p = getSceneObject(tonumber(oid))
				if p ~= nil then
					local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
					if not (okd and dead) then
						if fac == attackerFaction then
							attackers[#attackers + 1] = p
						else
							defenders[#defenders + 1] = p
						end
					end
				end
			end
		end
		if #attackers == 0 or #defenders == 0 then
			return
		end

		local stalled = 0
		for _, p in ipairs(attackers) do
			-- Guarded per unit (verifier, 2026-09-05): one bad body must
			-- skip one unit, not abort the whole site's fix-up.
			local okp, far = pcall(function()
				local so = SceneObject(p)
				local dx, dy = so:getWorldPositionX() - originX, so:getWorldPositionY() - originY
				return math.sqrt(dx * dx + dy * dy) >= (approach - WarBattle.STALL_TOLERANCE_M)
			end)
			if okp and far then
				stalled = stalled + 1
			end
		end
		if stalled * 2 < #attackers then
			return -- most of the line moved; it is advancing
		end

		local px, py = -uy, ux
		local halfLine = (#attackers - 1) / 2
		-- The fallback point must itself be walkable: at Theed the 24 m point
		-- is a canal and a line dropped there never fired (2026-09-05).
		local fallbackM = WarBattle.walkableAlong(zone, originX, originY, ux, uy,
			{ WarBattle.STALL_FALLBACK_M, 16, 12 }) or WarBattle.STALL_FALLBACK_M
		local baseX = originX + ux * fallbackM
		local baseY = originY + uy * fallbackM
		for i, p in ipairs(attackers) do
			local offset = (i - 1 - halfLine) * WarBattle.TROOPER_GAP_M
			local x, y = baseX + offset * px, baseY + offset * py
			local z = WarBattle.floorAt(zone, x, y)
			pcall(function() SceneObject(p):teleport(x, z, y, 0) end)
			WarBattle.engage(p, defenders[((i - 1) % #defenders) + 1], true)
		end
		printf(string.format("WarBattle: %s site %s -- assault stalled at %d m (%d/%d unmoved); line moved to %d m\n",
			tostring(regionId), tostring(siteIndex), math.floor(approach), stalled, #attackers, fallbackM))
	end)
	if not ok then
		printf("WarBattle: checkAdvance failed: " .. tostring(err) .. "\n")
	end
end

--- Stage every site at every qualifying front region, in strict
-- hottest-first priority, spending WarBattle.TOTAL_NPC_BUDGET as it goes.
-- See BUDGET above. Returns the number of sites actually staged and the
-- number of NPCs spawned, for the caller's log line.
--- Spawn a single-faction garrison patrol. Unlike spawnSite() this sets
-- nobody on anybody: there is no opposing line, so no fight starts. Tracked
-- through the same trackOid() list as everything else, so the existing
-- clear-then-restage cycle owns its lifetime and this can leak nothing.
local function spawnGarrison(zone, regionId, faction, originX, originY, slotTag)
	local spawned = 0
	slotTag = slotTag or 0

	for i = 1, WarBattle.SPREAD_SQUAD_SIZE do
		local template = pickTemplate(faction, i, regionId .. "g")
		if template ~= nil then
			-- Spread along one line only; a garrison reads as a patrol
			-- standing about, not as two ranks squaring up.
			local gx = originX + (i - 1) * WarBattle.TROOPER_GAP_M
			local pG = spawnMobile(zone, template, 0, gx, WarBattle.floorAt(zone, gx, originY), originY, 0, 0)

			if pG ~= nil then
				spawned = spawned + 1
				trackUnit(SceneObject(pG):getObjectID(), regionId, slotTag, faction, originX, originY)
				-- Same materiel path as a battle NPC (see spawnSite).
				if WarHeal ~= nil and WarHeal.attach ~= nil then WarHeal.attach(pG) end
			end
		end
	end

	return spawned
end

--- Called from reconcile(), which is defined above spawnGarrison in this
-- file: a global method resolves its callee when invoked, where a direct
-- reference to the local would have bound to a nil global at definition time.
function WarBattle.spawnCaptureGarrison(zone, regionId, faction, originX, originY, siteIndex)
	return spawnGarrison(zone, regionId, faction, originX, originY, "c" .. tostring(siteIndex))
end

function WarBattle:stageBattles(heldSites, heldGarrisons)
	heldSites = heldSites or {}
	heldGarrisons = heldGarrisons or {}
	if WarReport == nil or WarReport.state() == nil then
		printf("WarBattle: war state not readable on this thread -- no battles staged\n")
		return 0, 0
	end

	local front = WarBattle.fronts()
	if #front == 0 then
		printf("WarBattle: the war reports no fronts -- nothing to stage\n")
		return 0, 0
	end

	local npcBudgetLeft = WarBattle.TOTAL_NPC_BUDGET
	-- Slice A: a site costs a line per side; the offensive front's line is
	-- longer. perSiteCost is the floor used for the "any budget left" break.
	local perSiteCost = WarBattle.LINE_SIZE * 2
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
			local attacker = front[r].attacker or ((holder == "rebel") and "imperial" or "rebel")
			-- Slice A (owner ruling): ONE site per front, a full line per side.
			local wanted = 1
			local lineSize = (front[r].offensive == true) and WarBattle.LINE_SIZE_OFFENSIVE or WarBattle.LINE_SIZE
			local siteCost = lineSize * 2

			local regionSitesStaged = 0
			local regionHeldSlots = 0
			stagedRegions[regionId] = true
			for s = 1, wanted do
				local slotKey = regionId .. ":" .. tostring(s)

				local held = heldSites[slotKey]
				if held then
					-- A live engagement from an earlier cycle is still
					-- standing here. Leaving the NPCs entirely alone IS the
					-- feature: the fight a player is in must not be deleted
					-- underneath them. It still counts toward the region total
					-- so the presence message and the log report the truth --
					-- unless it is captured ground held by ONE side, which is
					-- not an engagement and must not be announced as one.
					local isCaptureGround = (type(held) == "table" and held.capture == true)
					if not isCaptureGround then
						sitesStaged = sitesStaged + 1
						regionSitesStaged = regionSitesStaged + 1
					end
					regionHeldSlots = regionHeldSlots + 1

					-- But the site's bookkeeping is NOT persistent and must be
					-- redone every cycle, because the reaps at the top of this
					-- function are unconditional:
					--   1. WarSquad's formup area was destroyed by clearAreas()
					--      and was previously only re-attached for freshly
					--      spawned sites -- so on the first fully-persisted
					--      cycle every held fight lost its area and B27 squad
					--      attachment silently stopped. Measured: formup
					--      areas went 10 -> 0 while 10 fights stood.
					--   2. The recruiter anchor (REGION_KEY) was likewise only
					--      written on a fresh spawn, so a held anchor site left
					--      it empty and markBattle() pointed at nothing.
					local isRecruiterAnchor = (not primaryRegionWritten) and (s == 1)
					-- Where the NPCs ACTUALLY stand, from the roster -- not
					-- siteOrigin() recomputed with this cycle's `wanted`,
					-- which spreads bearings by 360/wanted and so put a held
					-- site's formup area on empty ground whenever the contest
					-- (and with it `wanted`) changed between cycles.
					local ox, oy
					if type(held) == "table" and held.ox ~= nil and held.oy ~= nil then
						ox, oy = held.ox, held.oy
					else
						ox, oy = WarBattle.siteOrigin(coords, regionId, s, wanted, isRecruiterAnchor)
					end
					if WarSquad ~= nil and WarSquad.attachSite ~= nil then
						WarSquad.attachSite(zone, ox, oy)
					end
					if isRecruiterAnchor then
						writeStringData(WarBattle.REGION_KEY, regionId)
						primaryRegionWritten = true
					end
					-- Slice A: reinforce a thinned side of a live fight.
					if not isCaptureGround then
						local okw, waved = pcall(reinforceSite, zone, regionId, s, defender, attacker, held, lineSize, npcBudgetLeft)
						if okw and waved and waved > 0 then
							npcBudgetLeft = npcBudgetLeft - waved
							npcsSpawned = npcsSpawned + waved
						elseif not okw then
							printf("WarBattle: reinforceSite failed: " .. tostring(waved) .. "\n")
						end
					end
				elseif npcBudgetLeft >= siteCost then

				local isRecruiterAnchor = (not primaryRegionWritten) and (s == 1)
				local ox, oy = WarBattle.siteOrigin(coords, regionId, s, wanted, isRecruiterAnchor)
				local walkers = WarBattle.walkersFor(front[r], regionId, defender, attacker)
				local fielded = spawnSite(zone, regionId, s, defender, attacker, ox, oy, lineSize, walkers)

				-- B27 slice 1: the proximity area an overt player has to be inside
				-- for troops to fall in. Spawned per site, alongside the site, so
				-- there is no second source of truth about where a battle is.
				if fielded > 0 and WarSquad ~= nil and WarSquad.attachSite ~= nil then
					WarSquad.attachSite(zone, ox, oy)
				end

				if fielded > 0 then
					npcBudgetLeft = npcBudgetLeft - siteCost
					npcsSpawned = npcsSpawned + fielded
					sitesStaged = sitesStaged + 1
					regionSitesStaged = regionSitesStaged + 1
					if isRecruiterAnchor then
						writeStringData(WarBattle.REGION_KEY, regionId)
						primaryRegionWritten = true
					end
				end
				end
			end

			-- One town-sized presence area per region that actually got
			-- sites, so a player arriving in a contested town is TOLD the war
			-- is here and gets a waypoint. Before this, the only in-world
			-- pointer at a live battle was war_recruiter.lua's markBattle(),
			-- which fires solely from a recruiter conversation -- i.e. only
			-- for players who already knew to go asking.
			-- Also when the region's only standing slots are captured ground
			-- (regionSitesStaged 0): the arrival line is then the held-town
			-- one plus the capture note, not "N engagements underway".
			if (regionSitesStaged > 0 or regionHeldSlots > 0) and WarPresence ~= nil and WarPresence.attachRegion ~= nil then
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
				local present = heldGarrisons[regionId] == true

				if not present then
					-- Reuse the normal site placement so a garrison stands
					-- where a battle would, rather than on top of the town
					-- centre.
					local ox, oy = WarBattle.siteOrigin(coords, regionId, 1, 1, false)
					local n = spawnGarrison(zone, regionId, r.faction, ox, oy)

					if n > 0 then
						garrisonBudget = garrisonBudget - n
						garrisonsSpawned = garrisonsSpawned + n
						garrisonRegions = garrisonRegions + 1
						present = true
					end
				end

				-- Supply visibility + courier hand-in: a HELD town speaks on
				-- arrival too. Attached whether the garrison was spawned this
				-- cycle or is persisting -- the areas are reaped every cycle,
				-- so a held region must re-attach or go silent (the same trap
				-- the formup areas hit).
				if present and WarPresence ~= nil and WarPresence.attachRegion ~= nil then
					pcall(function() WarPresence.attachRegion(zone, regionId, 0) end)
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
	local heldSites, heldGarrisons, captures = {}, {}, {}

	-- Reconcile, do NOT clear. See PERSISTENCE above for why this is no longer
	-- a blanket teardown and what carries the leak guarantee instead.
	local ok = pcall(function()
		heldSites, heldGarrisons, captures = WarBattle:reconcile(true)
	end)
	if not ok then
		-- Never let a reconcile fault strand the war: fall back to the old
		-- raze-and-restage, which is always safe if less satisfying.
		printf("WarBattle: reconcile failed -- falling back to full clear\n")
		pcall(function() WarBattle:clear() end)
		heldSites, heldGarrisons, captures = {}, {}, {}
	end

	-- A held key is either a live fight or captured ground (the winners'
	-- garrison, value.capture == true). Count them apart: with captures
	-- resolving every cycle, "kept 12 live engagement(s)" was eight
	-- garrisons and four fights.
	local heldCount, capturedCount = 0, 0
	for _, v in pairs(heldSites) do
		if type(v) == "table" and v.capture then
			capturedCount = capturedCount + 1
		else
			heldCount = heldCount + 1
		end
	end

	for i = 1, #captures do
		printf(string.format("WarBattle: %s forces took a position at %s\n",
			tostring(captures[i].faction), tostring(captures[i].region)))
	end

	printf(string.format("WarBattle: reconcile kept %d live engagement(s), %d captured ground, %d capture(s) this cycle\n",
		heldCount, capturedCount, #captures))

	pcall(function() WarBattle:stageBattles(heldSites, heldGarrisons) end)
	createEvent(WarBattle.BATTLE_INTERVAL_MS, "WarBattle", "cycle", nil, "")
end

--- Exercise exactly the path WarBattle:cycle() takes -- reconcile, then stage
-- into whatever it did not keep -- WITHOUT rescheduling the recurring event,
-- which calling cycle() directly would do (leaving two timer chains running).
-- Run it twice: the first pass stages fresh, the second should report live
-- engagements KEPT rather than restaging them. The probe does NOT advance the
-- age clock, so running it any number of times never ages the front; only
-- the periodic cycle does, and that retires at most MAX_AGEOUTS_PER_CYCLE
-- slots per pass.
function Tests:warReconcileNow()
	printf("WARRECONCILE: begin\n")

	local held, heldG, caps = WarBattle:reconcile(false)

	local n, c, g = 0, 0, 0
	for _, v in pairs(held) do
		if type(v) == "table" and v.capture then c = c + 1 else n = n + 1 end
	end
	for _ in pairs(heldG) do g = g + 1 end

	printf("WARRECONCILE: kept " .. tostring(n) .. " live engagement(s), " .. tostring(c)
		.. " captured ground, " .. tostring(g) .. " garrison(s), " .. tostring(#caps) .. " capture(s)\n")

	for i = 1, #caps do
		printf("WARRECONCILE: capture " .. tostring(caps[i].faction)
			.. " took " .. tostring(caps[i].region) .. "\n")
	end

	local keys = {}
	for k, _ in pairs(held) do keys[#keys + 1] = k end
	table.sort(keys)
	printf("WARRECONCILE: held sites: " .. table.concat(keys, " ") .. "\n")
	keys = {}
	for k, _ in pairs(heldG) do keys[#keys + 1] = k end
	table.sort(keys)
	printf("WARRECONCILE: held garrisons: " .. table.concat(keys, " ") .. "\n")

	WarBattle:stageBattles(held, heldG)
	printf("WARRECONCILE: end\n")
end
