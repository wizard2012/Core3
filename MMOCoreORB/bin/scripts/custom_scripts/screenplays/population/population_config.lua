--[[
  custom_scripts/screenplays/population/population_config.lua

  Phase 1 of the synthetic population (docs/DESIGN-POPULATION.md S4.7,
  D15 in docs/DECISIONS.md): every tunable for the two scarce, mobile NPC
  service providers -- the field medic and the travelling performer.

  Lives entirely under custom_scripts/screenplays/, so it hot-reloads with
  deploy/scripts/reload-lua.sh (~1.2-1.6s). Nothing here is a war-sim
  tunable: no key here is read by anything under warsim/sim/, nothing here
  is added to warsim/config.lua, and T7's pinned tunable count (76) and
  T9's per-file literal allowlists are untouched (docs/DESIGN-POPULATION.md
  S4.7.4). This file is a pure data table with no logic.
]]

-- The off-switch (amendment R3). Flip either to false and reload
-- (reload-lua.sh, ~1.2-1.6s -- population_config.lua is screenplay-tree
-- Lua, not managers/ Lua, so no restart.sh is needed). The matching
-- providers are sent home with an in-fiction line and despawned within
-- PopulationServices.REFRESH_INTERVAL_MS (10 minutes) of the reload, since
-- an already-started screenplay's start() does not re-run on reload
-- (docs/AGENTS.md trap 13) -- the change is picked up by the next
-- self-rescheduling PopulationServices:circuitCheck() tick instead. Call
-- PopulationServices:refreshAll() directly (console `runLuaFunction
-- PopulationServices:refreshAll`, or the Tests hook) for an immediate
-- effect instead of waiting.
POPULATION_SERVICES = {
	medic = true,
	performer = true,
}

-- The roster (docs/DESIGN-POPULATION.md S4.7.1). D15's scarcity choice
-- (two of each, roaming with bias) is UNCHANGED for the ambient pool -- the
-- reasoning still holds: one would make a single bad roll strand the only
-- medic on the far side of the map, and ubiquitous placement is the design
-- D15 explicitly rejected.
--
-- SUPERSEDING RULING (owner, 2026-09-02, overriding D15 for this one case):
-- "In cities where there are active battles we need both an NPC entertainer
-- and medic/doctor to heal all wounds." `guaranteed` below adds exactly
-- that on top of the D15 pool, not instead of it: the first `guaranteed`
-- provider ids of each kind are pinned to the current front regions
-- (WarReport.frontRegions() -- the same signal war_battle.lua stages
-- fights at), capped at WarReport.MAX_FRONT_REGIONS (3), see
-- standing_services.lua refreshKind(). `count` is therefore
-- `guaranteed` (one slot per possible simultaneous front, so all 3 fronts
-- are covered even if they land on the same planet -- see min_separation
-- note below) plus 2 ambient roamers retained for coverage away from the
-- front, same as before.
--
-- min_separation = "planet" is deliberately NOT enough by itself to cover
-- 3 simultaneous fronts: if all 3 ranked front regions happen to be on the
-- same planet (e.g. every Tatooine city hot at once), "two of a kind never
-- share a planet" would leave 2 of the 3 fronts unguaranteed no matter how
-- high `count` is raised, since a third same-planet slot would always be
-- rejected. Raising the count further does not fix this -- the constraint
-- itself has to give. So guaranteed slots (only) are placed directly by
-- rank and are exempt from min_separation; only the ambient roamers still
-- enforce it among themselves. This is a deliberate, narrow relaxation of
-- D15's spread rule for guaranteed slots only, not a removal of it.
--
-- KNOWN GAP: tat_anchorhead has no cantina at all in this build (see
-- POPULATION_CANTINAS below -- 12 of 13 regions, verified asymmetry, not a
-- bug). If tat_anchorhead becomes a front region, the performer guarantee
-- cannot be met there by placement alone; refreshKind() logs this rather
-- than failing silently. Fixing it for real needs a hand-picked interior
-- cantina-equivalent spot for Anchorhead, which is out of scope here (no
-- such coordinate exists in this codebase to reuse).
POPULATION_PROVIDERS = {
	medic     = { count = 5, guaranteed = 3, kind = "aid_post", bias = "toward_front" },
	performer = { count = 5, guaranteed = 3, kind = "cantina",  bias = "away_from_front" },

	circuit_ticks   = 72,   -- war ticks between moves (~3 days at the hourly tick)
	salt            = "swgwar-population-v1", -- game-side only, NOT war_seed (S4.7.4)
	min_separation  = "planet", -- two of a kind never share a planet
	settle_radius_m = 64,   -- never relocate a provider with a player this close
}

-- Withdrawal threshold on the SAME 0..100 contest axis
-- warsim/config.lua's contest_flip_threshold (100.0) uses. This is a
-- GAME-SIDE tunable (placement.lua only reads WAR_STATE, never writes it),
-- not a warsim one -- it does not touch warsim/config.lua or its pinned
-- tunable count.
POPULATION_WITHDRAW_THRESHOLD = 50.0

-- Credits (docs/DESIGN-POPULATION.md S4.4). Placeholders pending live
-- players; err high on purpose (a sink that's too large is merely
-- annoying, one that's too small is invisible). The medic's frontier price
-- is its NORMAL price -- S4.7.3 sites it toward the front on purpose.
POPULATION_FEES = {
	medic     = { base = 1500, frontier_mult = 1.5 },
	performer = { base = 500,  frontier_mult = 1.5 },
}

-- Cooldown length MUST equal the buff's own duration
-- (managers/player_manager.lua medicalDuration / performanceDuration,
-- both 7200s stock, unchanged by this design) -- that identity is what
-- makes the fee honest given S4.2's "cannot read whether it landed"
-- limitation (S4.3): you literally cannot re-buy a buff that has not
-- expired yet. If those two durations are ever changed in
-- managers/player_manager.lua (restart.sh), update these to match.
POPULATION_COOLDOWN_MS = {
	medic     = 7200 * 1000,
	performer = 7200 * 1000,
}

-- Which planet each of the 13 war-mapped regions is on
-- (bridge/generated/region_map.lua names the regions; this is the
-- game-side planet lookup min_separation = "planet" needs).
POPULATION_REGION_PLANET = {
	cor_bela_vistal = "corellia",
	cor_coronet     = "corellia",
	cor_doaba       = "corellia",
	cor_kor_vella   = "corellia",
	cor_tyrena      = "corellia",
	nab_kaadara     = "naboo",
	nab_keren       = "naboo",
	nab_moenia      = "naboo",
	nab_theed       = "naboo",
	tat_anchorhead  = "tatooine",
	tat_bestine     = "tatooine",
	tat_mos_eisley  = "tatooine",
	tat_mos_espa    = "tatooine",
}

-- Outdoor aid-post coordinates, one per war-mapped region, all 13.
-- enhanceCharacter() has no medical-rating/building/location term
-- (verified: PlayerManagerImplementation.cpp:6666-6684), so the medic
-- needs no interior at all (docs/DESIGN-POPULATION.md S4.1, S4.7.2).
-- Coordinates are each city's real starport/shuttleport
-- (managers/planet/planet_manager.lua planetTravelPoints, read directly
-- out of the checkout -- not guessed), offset +15m on X so the medic
-- isn't standing on the landing pad itself. Bela Vistal and Anchorhead
-- have no starport in this build, so their nearest shuttleport is used
-- instead (same source table).
POPULATION_AID_POSTS = {
	cor_bela_vistal = { zone = "corellia", x = 6659.269,   z = 330,        y = -5922.5225, heading = 0, cell = 0 },
	cor_coronet     = { zone = "corellia", x = -51.760902, z = 28,         y = -4711.3281, heading = 0, cell = 0 },
	cor_doaba       = { zone = "corellia", x = 3364.8933,  z = 308,        y = 5598.1362,  heading = 0, cell = 0 },
	cor_kor_vella   = { zone = "corellia", x = -3142.2834, z = 31,         y = 2876.2029,  heading = 0, cell = 0 },
	cor_tyrena      = { zone = "corellia", x = -4988.0649, z = 21,         y = -2228.3665, heading = 0, cell = 0 },
	nab_kaadara     = { zone = "naboo",    x = 5295.2002,  z = -192,       y = 6688.0498,  heading = 0, cell = 0 },
	nab_keren       = { zone = "naboo",    x = 1386.5938,  z = 13,         y = 2747.9043,  heading = 0, cell = 0 },
	nab_moenia      = { zone = "naboo",    x = 4976.9409,  z = 3.75,       y = -4892.6997, heading = 0, cell = 0 },
	nab_theed       = { zone = "naboo",    x = -4843.834,  z = 5.9483199,  y = 4164.0679,  heading = 0, cell = 0 },
	tat_anchorhead  = { zone = "tatooine", x = 62.565128,  z = 52,         y = -5338.9072, heading = 0, cell = 0 },
	tat_bestine     = { zone = "tatooine", x = -1346.1917, z = 12,         y = -3600.0254, heading = 0, cell = 0 },
	tat_mos_eisley  = { zone = "tatooine", x = 3614.894,   z = 5,          y = -4780.4487, heading = 0, cell = 0 },
	tat_mos_espa    = { zone = "tatooine", x = -2818.1609, z = 5,          y = 2107.3787,  heading = 0, cell = 0 },
}

-- Cantina cell IDs -- lifted directly from
-- screenplays/cities/cantinas/bartenders.lua's bartenderSpawns table,
-- intersected with the 13 war-mapped regions
-- (bridge/generated/region_map.lua). Twelve of the seventeen bartender
-- cantinas are in mapped cities; tat_anchorhead has none, which is why it
-- is medic-only (docs/DESIGN-POPULATION.md S4.7.2 -- this is the verified
-- asymmetry, not a special case in code). x/z/y reuse a safe interior spot
-- from bartenders.lua's own patrolLocations table (patrolLocations[2],
-- deliberately not patrolLocations[1] where the bartender itself stands).
POPULATION_CANTINAS = {
	cor_bela_vistal = { zone = "corellia", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 3375355 },
	cor_coronet     = { zone = "corellia", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 8105496 },
	cor_doaba       = { zone = "corellia", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 3075429 },
	cor_kor_vella   = { zone = "corellia", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 3005399 },
	cor_tyrena      = { zone = "corellia", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 2625355 },
	nab_kaadara     = { zone = "naboo",    x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 64 },
	nab_keren       = { zone = "naboo",    x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 5 },
	nab_moenia      = { zone = "naboo",    x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 111 },
	nab_theed       = { zone = "naboo",    x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 91 },
	tat_bestine     = { zone = "tatooine", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 1028647 },
	tat_mos_eisley  = { zone = "tatooine", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 1082877 },
	tat_mos_espa    = { zone = "tatooine", x = 3.0, z = -0.9, y = 3.4, heading = 0, cell = 1256058 },
}

-- Canonical, hand-fixed region ordering (matches
-- bridge/generated/region_map.lua's own alphabetical listing). Used
-- wherever a stable index is needed instead of a name -- specifically the
-- shared-memory deferral state in placement.lua, since writeSharedMemory
-- only stores integers (DirectorManager.cpp:1424). NOT used for iteration
-- order inside placement math (that always sorts explicitly); this is
-- purely a name<->index lookup table.
POPULATION_REGION_IDS = {
	"cor_bela_vistal", "cor_coronet", "cor_doaba", "cor_kor_vella", "cor_tyrena",
	"nab_kaadara", "nab_keren", "nab_moenia", "nab_theed",
	"tat_anchorhead", "tat_bestine", "tat_mos_eisley", "tat_mos_espa",
}
