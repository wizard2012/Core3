--[[
  custom_scripts/screenplays/simplayers/sim_config.lua

  SimPlayers (docs/DESIGN-SIMPLAYERS.md): the roster and every tunable for
  the Erenshor-style NPC "players" -- persistent, named characters who live
  in the war the way a player would: rest in a cantina, ship out to a front,
  fight there, clone when they die, rank up, talk to you, and fall in behind
  you if you ask. Pure data; sim_players.lua holds the behaviour.

  Hot-reloads with deploy/scripts/reload-lua.sh. Nothing here is read by the
  war sim (warsim/) and nothing here writes to it: SimPlayers touch the
  GROUND war (they kill and die at fronts) and never the ledger, the
  population count, or supply -- Contract P / Contract L in
  docs/DESIGN-POPULATION.md, restated in the design doc.
]]

SIM_CONFIG = SIM_CONFIG or {}

-- Off-switch. false -> every SimPlayer is despawned on the next tick and
-- nothing is scheduled beyond the tick chain itself (which keeps polling
-- this flag, so flipping it back on needs no restart).
SIM_CONFIG.ENABLED = true

-- The loop. One global tick walks the whole roster; every duration below is
-- a window in that loop, not a promise to the millisecond.
SIM_CONFIG.TICK_MS          = 30 * 1000
SIM_CONFIG.TRAVEL_MS        = 3 * 60 * 1000    -- despawned "on the shuttle"
SIM_CONFIG.FIGHT_MIN_MS     = 8 * 60 * 1000
SIM_CONFIG.FIGHT_MAX_MS     = 16 * 60 * 1000
SIM_CONFIG.REST_MIN_MS      = 4 * 60 * 1000
SIM_CONFIG.REST_MAX_MS      = 10 * 60 * 1000
SIM_CONFIG.CLONE_MS         = 2 * 60 * 1000    -- dead -> back at a friendly city
SIM_CONFIG.ESCORT_MS        = 20 * 60 * 1000   -- following a player, at most
SIM_CONFIG.ESCORT_LEASH_M   = 120              -- further than this from the player...
SIM_CONFIG.ESCORT_LEASH_TICKS = 3              -- ...for this many ticks = left behind

-- An unresolvable OID is not proof of death (cross-thread miss); it is
-- after this many consecutive ticks.
SIM_CONFIG.MISSES_BEFORE_DEAD = 2

-- Talk. Lines fire only with a player this close, this often, per character.
SIM_CONFIG.CHAT_RANGE_M     = 24
SIM_CONFIG.CHAT_MIN_GAP_MS  = 45 * 1000
SIM_CONFIG.INVITE_RANGE_M   = 24

-- Progression. XP accrues per tick spent alive at a front; the rank ladder
-- picks the body (SIM_CONFIG.TEMPLATES) and the title. Deliberately slow:
-- a promotion is news, and news that comes hourly is noise.
SIM_CONFIG.XP_PER_FIGHT_TICK = 1

-- Couriers (Supply War slice 6, DESIGN-WAR-V2 2.4 / 6; D27 reversed D26's
-- "they write nothing to the sim"): when a SimPlayer's stint ends it may
-- ship out to run a crate to a friendly town that needs one. The run is a
-- real materiel_delivery row worth WarCourier.POINTS crates -- exactly a
-- player's run -- announced where it lands, never galaxy-wide. Per
-- SimPlayer at most one run per COURIER_MIN_GAP_MS; the chance is by style
-- (a runner runs, a brawler rarely does). Twelve SimPlayers, six a side,
-- at most one run each per 90 min is under 40 crates an hour galaxy-wide.
SIM_CONFIG.COURIER_ENABLED     = true
SIM_CONFIG.COURIER_MIN_GAP_MS  = 90 * 60 * 1000
SIM_CONFIG.COURIER_CHANCE      = { runner = 60, scout = 40, homebody = 30, defender = 25, grinder = 15, brawler = 10 } -- percent
SIM_CONFIG.RANKS = {
	{ xp = 0,   imperial = "Recruit",    rebel = "Recruit"    },
	{ xp = 12,  imperial = "Private",    rebel = "Trooper"    },
	{ xp = 36,  imperial = "Corporal",   rebel = "Corporal"   },
	{ xp = 80,  imperial = "Sergeant",   rebel = "Sergeant"   },
	{ xp = 160, imperial = "Lieutenant", rebel = "Lieutenant" },
}

-- The body worn at each rank (index = rank). All faction-flagged and
-- ATTACKABLE, the same pool war_battle.lua fields, so a SimPlayer is
-- killable by the other side -- players included -- exactly as a player is.
SIM_CONFIG.TEMPLATES = {
	imperial = { "imperial_trooper", "stormtrooper", "stormtrooper_rifleman", "imperial_master_sergeant", "sand_trooper" },
	rebel    = { "rebel_trooper", "rebel_scout", "rebel_commando", "specforce_heavy_weapons_specialist", "rebel_commando" },
}

-- Personality decides where they go when they are free to choose
-- (sim_players.lua decide()):
--   brawler   the hottest front in the galaxy, always
--   grinder   any front, long stints
--   defender  the most-contested town their own side still holds
--   runner    a friendly town whose supply is thin or cut (a courier by trade)
--   scout     a different city every time; a travelling reporter
--   homebody  home, unless home's planet has a front
SIM_CONFIG.ROSTER = {
	-- Rebel Alliance
	{ id = "kessa",  name = "Kessa Varn",     faction = "rebel",    style = "brawler",  home = "tat_anchorhead" },
	{ id = "dorn",   name = "Dorn Ashvale",   faction = "rebel",    style = "runner",   home = "nab_keren" },
	{ id = "tal",    name = "Tal Merrick",    faction = "rebel",    style = "defender", home = "nab_kaadara" },
	{ id = "rue",    name = "Rue Sandrider",  faction = "rebel",    style = "scout",    home = "tat_mos_espa" },
	{ id = "bren",   name = "Bren Okast",     faction = "rebel",    style = "grinder",  home = "cor_doaba" },
	{ id = "ilo",    name = "Ilo Vess",       faction = "rebel",    style = "homebody", home = "nab_moenia" },
	-- Galactic Empire
	{ id = "reya",   name = "Reya Thal",      faction = "imperial", style = "brawler",  home = "cor_coronet" },
	{ id = "marek",  name = "Marek Voss",     faction = "imperial", style = "defender", home = "nab_theed" },
	{ id = "ilsa",   name = "Ilsa Corvane",   faction = "imperial", style = "runner",   home = "tat_mos_eisley" },
	{ id = "dax",    name = "Dax Fenner",     faction = "imperial", style = "scout",    home = "tat_bestine" },
	{ id = "oren",   name = "Oren Halcyon",   faction = "imperial", style = "grinder",  home = "cor_tyrena" },
	{ id = "vell",   name = "Vell Quorin",    faction = "imperial", style = "homebody", home = "cor_kor_vella" },
}

-- Where a SimPlayer stands when they arrive in a city "off the shuttle":
-- each city's real starport/shuttleport (managers/planet/planet_manager.lua
-- planetTravelPoints, +15 m on X so they are not on the pad). These are the
-- rows population_config.lua's aid posts used to carry before the medics
-- moved indoors; kept here because arrivals are exactly what they describe.
SIM_CONFIG.ARRIVALS = {
	cor_bela_vistal = { zone = "corellia", x = 6659.269,   z = 330,       y = -5922.5225 },
	cor_coronet     = { zone = "corellia", x = -51.760902, z = 28,        y = -4711.3281 },
	cor_doaba       = { zone = "corellia", x = 3364.8933,  z = 308,       y = 5598.1362  },
	cor_kor_vella   = { zone = "corellia", x = -3142.2834, z = 31,        y = 2876.2029  },
	cor_tyrena      = { zone = "corellia", x = -4988.0649, z = 21,        y = -2228.3665 },
	nab_kaadara     = { zone = "naboo",    x = 5295.2002,  z = -192,      y = 6688.0498  },
	nab_keren       = { zone = "naboo",    x = 1386.5938,  z = 13,        y = 2747.9043  },
	nab_moenia      = { zone = "naboo",    x = 4976.9409,  z = 3.75,      y = -4892.6997 },
	nab_theed       = { zone = "naboo",    x = -4843.834,  z = 5.9483199, y = 4164.0679  },
	tat_anchorhead  = { zone = "tatooine", x = 62.565128,  z = 52,        y = -5338.9072 },
	tat_bestine     = { zone = "tatooine", x = -1346.1917, z = 12,        y = -3600.0254 },
	tat_mos_eisley  = { zone = "tatooine", x = 3614.894,   z = 5,         y = -4780.4487 },
	tat_mos_espa    = { zone = "tatooine", x = -2818.1609, z = 5,         y = 2107.3787  },
}

-- Resting happens in the cantina where one exists (population_config.lua's
-- POPULATION_CANTINAS, the same rows the performer uses) so a SimPlayer at
-- rest is where a player would look for one; otherwise at the arrival point.
SIM_CONFIG.REST_IN_CANTINA = true

-- Radial ids. Officer uses 20, courier 30.
SIM_CONFIG.RADIAL_ROOT    = 40
SIM_CONFIG.RADIAL_ASK     = 41
SIM_CONFIG.RADIAL_RECRUIT = 42
SIM_CONFIG.RADIAL_WHERE   = 43
