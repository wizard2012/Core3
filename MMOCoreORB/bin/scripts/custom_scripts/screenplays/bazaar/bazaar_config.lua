--[[
  custom_scripts/screenplays/bazaar/bazaar_config.lua

  Tunables + depot data for bazaar_stock.lua (stage S2, see docs/DECISIONS.md and
  the owner ruling that overrules DESIGN-POPULATION.md S3.11 -- "we don't have
  enough players to populate it so we should add things to it to help"). Pure
  data plus a couple of pure helpers -- bazaar_stock.lua owns all the actual
  listing/creation logic.

  VANILLA SAFETY RAILS THIS FILE MIRRORS (verified against the submodule, not
  assumed -- see the cited line numbers)
  -----------------------------------------------------------------------
    AuctionManager.idl:36  MAXBAZAARPRICE       = 20000
    AuctionManager.idl:37  MAXSALES             = 25   (bazaar listing cap, per seller)
    AuctionManager.idl:45  COMMODITYEXPIREPERIOD = 604800 (7 days; bazaar listings are
                            "commodity" sales, not vendor sales -- VENDOREXPIREPERIOD
                            at idl:44 is the 30-day vendor-terminal constant, NOT this)
  Neither MAXSALES nor MAXBAZAARPRICE nor COMMODITYEXPIREPERIOD is exposed to Lua --
  DirectorManager::bazaarBotList enforces MAXBAZAARPRICE natively (returns
  INVALIDSALEPRICE outside that range) and checkSaleItem enforces MAXSALES natively
  (returns TOOMANYITEMS at the cap); COMMODITYEXPIREPERIOD is enforced by
  AuctionManagerImplementation's own hourly sweep. This file's own SAFETY_CAP below
  is an independent, smaller ceiling BazaarStock applies to itself so a restock never
  gets anywhere near the native TOOMANYITEMS wall.
]]

BAZAAR_CONFIG = BAZAAR_CONFIG or {}

-- Master off-switch. Mirrors STREET_CONFIG.ENABLED's role (population/street_config.lua):
-- false stops new listings from being created on future ticks, but does NOT
-- retroactively cancel anything already listed -- use a probe/manual bazaarBotCancel
-- pass for that, same caveat street_life.lua documents for its own switch.
BAZAAR_CONFIG.ENABLED = true

-- Independent of AuctionManager.idl's MAXSALES=25 (see file header) -- this is how
-- close to that native wall BazaarStock is willing to let ITSELF get, per seller.
-- Kept well under 25 so a restock pass never risks TOOMANYITEMS, and so the bazaar
-- always reads as "stocked" rather than "full to the brim, obviously curated by a
-- machine".
BAZAAR_CONFIG.SAFETY_CAP = 20

-- Self-rescheduling tick jitter (mirrors STREET_CONFIG.TICK_MIN_MS/MAX_MS) -- long
-- enough that a depot's stock visibly ages between passes, short enough that six
-- players restocking the whole galaxy's demand still see movement inside a session.
BAZAAR_CONFIG.TICK_MIN_MS = 8 * 60 * 1000
BAZAAR_CONFIG.TICK_MAX_MS = 15 * 60 * 1000

-- Per-tick, per-depot: how many NEW listings a single pass is allowed to add.
-- Never a refill -- see bazaar_stock.lua's restockOnce() for the "roll nothing"
-- and "at most this many" logic that keeps ages staggered.
BAZAAR_CONFIG.MIN_ADD_PER_TICK = 1
BAZAAR_CONFIG.MAX_ADD_PER_TICK = 3

-- Chance (0-100) that a depot's tick adds nothing at all this pass, even when it
-- has room -- so a depot is not visibly topped up on a fixed cadence.
BAZAAR_CONFIG.SKIP_TICK_CHANCE_PCT = 25

-- Price jitter applied to every listing's configured base price.
BAZAAR_CONFIG.PRICE_JITTER_PCT = 15

-- ===================================================== faction-perk deny-list ==
--
-- Never list anything from screenplays/gcw/recruiters/factionPerkData.lua (owner
-- ruling: those are priced in materiel by design; selling them for credits would
-- gut the war economy). Built by walking rebelRewardData/imperialRewardData at
-- runtime rather than hand-copying their ~65 "item=" template paths here a second
-- time, which would silently drift the moment that file's own list changes.
-- factionPerkData.lua is normally pulled in by recruiterScreenplay.lua earlier in
-- screenplays.lua's include chain, but includeFile() is a plain re-run (not
-- idempotent-guarded -- confirmed by reading DirectorManager::includeFile), and
-- factionPerkData.lua only assigns two global tables, so including it again here
-- is harmless and removes any ordering dependency on where this file's own
-- includeFile line ends up relative to recruiterScreenplay.lua's.
includeFile("gcw/recruiters/factionPerkData.lua")

local function walkForItemPaths(node, out, depth)
	if depth > 6 or type(node) ~= "table" then
		return
	end
	for k, v in pairs(node) do
		if k == "item" and type(v) == "string" then
			out[v] = true
		elseif type(v) == "table" then
			walkForItemPaths(v, out, depth + 1)
		end
	end
end

local function buildFactionPerkDenyList()
	local out = {}
	if type(rebelRewardData) == "table" then
		walkForItemPaths(rebelRewardData, out, 1)
	end
	if type(imperialRewardData) == "table" then
		walkForItemPaths(imperialRewardData, out, 1)
	end
	return out
end

-- Rebuilt once at include time. A reload-lua.sh re-runs this whole file (and
-- factionPerkData.lua just above it), so this stays correct across reloads --
-- it is NOT cached across the reload boundary the way shared-memory state is.
BAZAAR_CONFIG.FACTION_PERK_DENY_LIST = buildFactionPerkDenyList()

-- =============================================================== depots ==
--
-- CATEGORY DISCIPLINE (owner ruling): each depot has one coherent supply story
-- and never lists outside it -- "The items added have to make sense as though
-- they were added by one of the ai players". See bazaar_stock.lua's header for
-- how templates are turned into actual listings (giveItem for consumables,
-- staged createLoot for resources).
--
-- sellerName is CONFIGURABLE and points at a character that does not exist yet
-- (stage S3, a human step -- see docs/AGENTS.md S10.1 and this stage's brief).
-- Institutional names only (owner ruling) -- never person-style.
--
-- homeRegion/x/y are an EXISTING, already-reviewed war-region coordinate from
-- warreport/war_report.lua's own COORDS table (never a new x/y invented here),
-- used only to resolve a live CityRegion -> bazaar terminal via getCityRegionAt
-- + CityRegion:getBazaar(idx), the exact mechanism bazaar_probe.lua already
-- proved live in S1. It does not need to match wherever the seller character
-- physically stands (bazaarBotList takes an explicit terminal argument, not the
-- seller's location) -- it only needs a zone with a live bazaar terminal.
--
-- pool entries:
--   { kind = "consumable", template = "<.iff path>", basePrice = N }
--   { kind = "resource",   lootItem = "resource_container_<type>", basePrice = N }
-- "template" for consumables is an exact object template path created fresh via
-- giveItem() (never a random loot roll) -- see bazaar_stock.lua's ELIGIBILITY
-- guard for why that keeps getCraftersName()/getJunkValue() safe by construction.
-- "lootItem" for resources must be one of the vanilla resource_container_<type>
-- names this stage overrode in custom_scripts/loot/serverobjects.lua (see that
-- file's header for why the name literally cannot be anything else).

BAZAAR_CONFIG.DEPOTS = {

	-- Depot A: freight / raw-materials depot. One story -- bulk resource
	-- shipments received and forwarded, the full spread of what a general
	-- freight operation would plausibly move, not a themed subset.
	{
		id = "quartermaster",
		sellerName = "Quartermaster",
		homeRegion = "cor_coronet", homeZone = "corellia", homeX = -178, homeY = -4504,
		target = 12,
		pool = {
			{ kind = "resource", lootItem = "resource_container_metal",    basePrice = 4500 },
			{ kind = "resource", lootItem = "resource_container_ore",      basePrice = 4200 },
			{ kind = "resource", lootItem = "resource_container_chemical", basePrice = 5200 },
			{ kind = "resource", lootItem = "resource_container_water",    basePrice = 2600 },
			{ kind = "resource", lootItem = "resource_container_wood",     basePrice = 2800 },
			{ kind = "resource", lootItem = "resource_container_gemstone", basePrice = 6800 },
			{ kind = "resource", lootItem = "resource_container_hide",     basePrice = 3200 },
			{ kind = "resource", lootItem = "resource_container_bone",     basePrice = 1400 },
			{ kind = "resource", lootItem = "resource_container_bone_horn",basePrice = 1600 },
			{ kind = "resource", lootItem = "resource_container_cereal",   basePrice = 1200 },
			{ kind = "resource", lootItem = "resource_container_meat",     basePrice = 1300 },
			{ kind = "resource", lootItem = "resource_container_milk",     basePrice = 1100 },
			{ kind = "resource", lootItem = "resource_container_seeds",    basePrice = 1000 },
		},
	},

	-- Depot B: relief / medical & subsistence station. One story -- field
	-- medicine and rations, nothing combat-oriented.
	{
		id = "relief",
		sellerName = "Relief",
		homeRegion = "tat_mos_eisley", homeZone = "tatooine", homeX = 3460, homeY = -4768,
		target = 12,
		pool = {
			{ kind = "consumable", template = "object/tangible/medicine/medpack_wound_health.iff",   basePrice = 220 },
			{ kind = "consumable", template = "object/tangible/medicine/medpack_enhance_health.iff", basePrice = 260 },
			{ kind = "consumable", template = "object/tangible/medicine/medpack_disease_health.iff", basePrice = 240 },
			{ kind = "consumable", template = "object/tangible/medicine/medpack_cure_poison.iff",     basePrice = 240 },
			{ kind = "consumable", template = "object/tangible/medicine/medpack_wound.iff",           basePrice = 200 },
			{ kind = "consumable", template = "object/tangible/medicine/antidote_sm_s1.iff",          basePrice = 150 },
			{ kind = "consumable", template = "object/tangible/medicine/stimpack_sm_s1.iff",          basePrice = 180 },
			{ kind = "consumable", template = "object/tangible/medicine/medikit_tool_basic.iff",      basePrice = 350 },
			{ kind = "consumable", template = "object/tangible/food/meat_kabob.iff",                  basePrice = 60 },
			{ kind = "consumable", template = "object/tangible/food/nectar.iff",                      basePrice = 50 },
			{ kind = "consumable", template = "object/tangible/food/fruit_melon.iff",                 basePrice = 45 },
			{ kind = "consumable", template = "object/tangible/food/bread_loaf_full_s1.iff",          basePrice = 55 },
			{ kind = "consumable", template = "object/tangible/food/meat_object.iff",                 basePrice = 65 },
			{ kind = "consumable", template = "object/tangible/food/crafted/drink_spiced_tea.iff",    basePrice = 70 },
			{ kind = "consumable", template = "object/tangible/food/crafted/drink_jawa_beer.iff",     basePrice = 80 },
			{ kind = "consumable", template = "object/tangible/food/crafted/drink_corellian_ale.iff", basePrice = 90 },
		},
	},

	-- Depot C: field outfitter. One story -- weapon upgrade components and
	-- portable field gear, the kind of surplus an outfitter posted near a
	-- population centre would carry.
	{
		id = "salvage",
		sellerName = "Salvage",
		homeRegion = "nab_theed", homeZone = "naboo", homeX = -5320, homeY = 4368,
		target = 11,
		pool = {
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_power.iff",  basePrice = 550 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_scope.iff",  basePrice = 500 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_barrel.iff", basePrice = 480 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_stock.iff",  basePrice = 420 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_grip.iff",   basePrice = 400 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/ranged_muzzle.iff", basePrice = 420 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/melee.iff",         basePrice = 450 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/heavy.iff",         basePrice = 600 },
			{ kind = "consumable", template = "object/tangible/powerup/weapon/thrown.iff",        basePrice = 380 },
			{ kind = "consumable", template = "object/tangible/scout/camp/camp_basic.iff",        basePrice = 900 },
			{ kind = "consumable", template = "object/tangible/scout/camp/camp_improved.iff",     basePrice = 1400 },
			{ kind = "consumable", template = "object/tangible/scout/camp/camp_quality.iff",      basePrice = 1900 },
			{ kind = "consumable", template = "object/tangible/medicine/healing_grenade.iff",     basePrice = 260 },
			{ kind = "consumable", template = "object/tangible/medicine/medpack_grenade_area.iff",basePrice = 300 },
		},
	},
}

-- ===================================================================== staging ==
--
-- The one live zone + far-corner coordinate bazaar_stock.lua spawns a transient
-- loot_crate.iff staging container at, to work around the offline-seller resource
-- hazard (see bazaar_stock.lua header). Deliberately empty desert, far from any
-- war-mapped city coordinate above, so the sub-second spawn/despawn is never near
-- a player. Not a new invented coordinate in the sense street_life.lua's rule
-- means (no NPC is placed here, nothing persists), but flagged plainly for the
-- same reason that rule exists.
BAZAAR_CONFIG.STAGING_ZONE = "tatooine"
BAZAAR_CONFIG.STAGING_X = 6800
BAZAAR_CONFIG.STAGING_Y = 6800
BAZAAR_CONFIG.STAGING_Z = 0
