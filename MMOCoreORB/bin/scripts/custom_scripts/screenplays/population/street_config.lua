--[[
  custom_scripts/screenplays/population/street_config.lua

  Tunables for street_life.lua. Pure data (numbers/tables/booleans) plus one
  derived helper (screenplayNameFor) that only reads WAR_REGION_MAP -- no
  coordinates are invented here. Every coordinate street_life.lua ever spawns
  at is read at runtime from the live CityScreenPlay instance
  (screenplays/cities/*.lua's own stationaryMobiles/patrolPoints) or from
  population_config.lua's POPULATION_AID_POSTS/POPULATION_CANTINAS -- both
  already-shipped, already-reviewed data. This file only says HOW MANY and
  HOW OFTEN.
]]

STREET_CONFIG = STREET_CONFIG or {}

-- Master off-switch. Setting this false and reload-lua.sh-ing does NOT
-- retroactively despawn anything already up (start() only runs at boot,
-- same trap standing_services.lua's own header documents) -- use the
-- populationStreetOff probe for that.
STREET_CONFIG.ENABLED = true

-- All 13 war-mapped cities (owner ruling: all 13, affordable only because of
-- the presence gate -- see street_life.lua). Keyed by war region id, same
-- ids WAR_REGION_MAP's values use.
STREET_CONFIG.CITIES = {
	cor_bela_vistal = true,
	cor_coronet     = true,
	cor_doaba       = true,
	cor_kor_vella   = true,
	cor_tyrena      = true,
	nab_kaadara     = true,
	nab_keren       = true,
	nab_moenia      = true,
	nab_theed       = true,
	tat_anchorhead  = true,
	tat_bestine     = true,
	tat_mos_eisley  = true,
	tat_mos_espa    = true,
}

-- Extra stationary background figures spawned per city at start(), on top of
-- whatever CityScreenPlay:spawnStationaryMobiles() already put there -- a
-- nudge, not a crowd rebuild. Scaled by WarBridge.civilianFlightFraction the
-- same way the city's own civilian rows are (see street_life.lua's
-- scaledCount). One of a city's stationaryMobiles rows (index 1) is always
-- reserved for the anchor NPC instead -- see EXTRA_STATIONARY_PER_CITY's
-- comment in street_life.lua's pickStationarySlots.
STREET_CONFIG.EXTRA_STATIONARY_PER_CITY = 2

-- Cantina patrons spawned per city at start(), only for cities with a
-- POPULATION_CANTINAS entry (population_config.lua) -- tat_anchorhead has
-- none and gets 0, same as standing_services.lua's performer placement.
STREET_CONFIG.CANTINA_PATRONS_PER_CITY = 2

-- Self-rescheduling tick jitter, per city, so 13 cities' timers do not run
-- in lockstep.
STREET_CONFIG.TICK_MIN_MS = 20 * 1000
STREET_CONFIG.TICK_MAX_MS = 40 * 1000

-- Presence gate: radius (metres) around a city's anchor NPC that counts as
-- "someone is here". Nil/no-zone from getPlayersInRange is treated as zero.
STREET_CONFIG.PRESENCE_RADIUS_M = 60

-- Chatter: how close a player must be to a SPECIFIC talker for that talker
-- to be eligible to speak this tick, the minimum gap (ms) between two lines
-- spoken in the same city regardless of who says them, and how many recently
-- spoken line keys ("pool:index") that city remembers to avoid repeats.
STREET_CONFIG.CHATTER_RANGE_M = 40
STREET_CONFIG.CHATTER_MIN_GAP_MS = 15 * 1000
STREET_CONFIG.CHATTER_RING_SIZE = 12

-- region.threat (0..1, see war_hook.lua) at or above which a city's chatter
-- draws from plaza_contested instead of plaza_frontier/plaza_quiet.
STREET_CONFIG.CONTESTED_THREAT = 0.5

-- Travellers: spawned at the city's own shuttleport/starport coordinate
-- (population_config.lua's POPULATION_AID_POSTS -- "each city's real
-- starport/shuttleport", already vetted, not invented here) and walked one
-- of that city's own patrolPoints routes (screenplays/cities/*.lua) before
-- despawning. Capped per city and globally; TTL is a hard backstop in case
-- a traveller's route never reports DESTINATIONREACHED (stuck in geometry --
-- see war_battle.lua's own PLACEMENT note on this exact risk class).
STREET_CONFIG.TRAVELLER_PER_CITY_CAP = 1
STREET_CONFIG.TRAVELLER_GLOBAL_CAP = 6
STREET_CONFIG.TRAVELLER_TTL_MS = 5 * 60 * 1000
STREET_CONFIG.TRAVELLER_SPAWN_CHANCE_PCT = 40

--- screenplayName -> regionId is WAR_REGION_MAP already; this is the reverse
-- (regionId -> screenplayName), built once and cached, since street_life.lua
-- only ever has the regionId (from STREET_CONFIG.CITIES) and needs the live
-- CityScreenPlay global to read its stationaryMobiles/patrolPoints/etc.
-- Returns nil if WAR_REGION_MAP is missing/malformed or has no entry mapping
-- to regionId -- same fail-safe contract as WarBridge's own readers.
local reverseMap = nil

function STREET_CONFIG.screenplayNameFor(regionId)
	-- Core3 gives every thread its own Lua VM, and WAR_REGION_MAP is only
	-- populated on a thread that actually ran WarBridge.load() (war_hook.lua
	-- calls it at include time). A reader on any other thread sees nil --
	-- the same failure warreport/war_report.lua's WarReport.state() documents
	-- and works around the same way. VERIFIED LIVE here: the console `test`
	-- VM had WarBridge present but WAR_STATE/WAR_REGION_MAP nil, which made
	-- every lookup below return nil; a street-life tick landing on such a
	-- thread would silently do nothing for that city forever. So reload on
	-- demand rather than assuming some other thread already did it.
	if type(WAR_REGION_MAP) ~= "table" and WarBridge ~= nil and WarBridge.load ~= nil then
		pcall(function() WarBridge.load() end)
		reverseMap = nil
	end

	if type(WAR_REGION_MAP) ~= "table" then
		return nil
	end

	if reverseMap == nil then
		reverseMap = {}
		for screenplayName, mappedRegion in pairs(WAR_REGION_MAP) do
			reverseMap[mappedRegion] = screenplayName
		end
	end

	return reverseMap[regionId]
end
