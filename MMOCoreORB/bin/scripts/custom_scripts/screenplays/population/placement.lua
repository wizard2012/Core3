--[[
  custom_scripts/screenplays/population/placement.lua

  Phase 1/2 combined per D15: the pure placement function
  (docs/DESIGN-POPULATION.md S4.7.3) plus the shared-memory deferral seam
  (S4.7.6) both the spawner (standing_services.lua) and the bartender
  rumour (bartender_rumor.lua) call into, so they can never disagree.

  PURITY AND THE FIREWALL (S4.7.4) -- read this before editing.
  ----------------------------------------------------------------
  PopulationPlacement.computeSite() is a pure function of (a) the numbers
  it is handed and (b) POPULATION_* config -- no math.random, no os.time,
  no server-load-dependent input. It is deliberately NOT part of the war
  sim's own determinism contract (docs/AGENTS.md invariant 1) -- that
  contract lives entirely under warsim/sim/ and is enforced by
  warsim/sim/sandbox.lua; this file is game-side Lua running in Core3's
  DirectorManager Lua state, a different language runtime with no sandbox
  and no obligation to it. What this file DOES promise, on its own and for
  its own reasons (S4.7.4's actual requirement: the spawner and the
  bartender's rumour must never disagree about where a provider is), is
  that the SAME (war tick, provider id) always produces the SAME computed
  site, so a restart.sh puts every provider back where it was.

  This file only READS custom_scripts/war/war_state.lua and
  custom_scripts/war/region_map.lua (the same generated, read-only
  hand-off bridge/war_hook.lua reads -- see that file's own header) and
  custom_scripts/screenplays/population/population_config.lua. It WRITES
  nothing to swgwar, the ledger, or any bridge input, and it adds no key to
  warsim/config.lua. The war_seed is never read here (S4.7.4) -- the salt
  is population_config.lua's own game-side constant.

  FAIL-SAFE CONTRACT
  -------------------
  Every function below returns nil (never throws) on a missing or
  malformed war-state file, an empty eligible pool, or any other
  unexpected shape. Every call site in standing_services.lua and
  bartender_rumor.lua treats nil as "leave things as they are" -- a
  missing/malformed war_state.lua freezes providers at their last-known
  good placement rather than crashing or despawning anything.
]]

PopulationPlacement = PopulationPlacement or {}

-- ============================================================ hashing ====

-- A small, deliberately NOT-bit-for-bit-FNV-1a stable string hash.
-- docs/DESIGN-POPULATION.md S4.7.3's pseudocode names fnv1a as an example
-- algorithm; nothing outside this file ever needs to reproduce this exact
-- value, so bit-for-bit fidelity to FNV-1a buys nothing here. True FNV-1a
-- needs XOR, and this Core3 checkout's embedded Lua version is not
-- confirmed to expose bit32/native bitwise operators (docs/AGENTS.md logs
-- both 5.1 and 5.3 behaviour being tested elsewhere in this project) --
-- reaching for XOR would risk a load-time error on whichever Lua dialect
-- this server actually embeds. A multiply-add polynomial hash needs only
-- +, * and % and is exactly as good for "pick a stable pseudo-random
-- index into a pool of at most 13 sites". HASH_MOD/HASH_MUL are kept
-- small enough (max intermediate ~= 1.31e11) that this is exact under
-- IEEE-754 double arithmetic (53 bits ~= 9.007e15) regardless of whether
-- Lua numbers here are doubles or 64-bit integers.
local HASH_MOD = 1000000007
local HASH_MUL = 131

local function stableHash(str)
	local h = 0
	for i = 1, #str do
		h = (h * HASH_MUL + string.byte(str, i)) % HASH_MOD
	end
	return h
end

-- ========================================================= war state ====

--- Load WAR_STATE/WAR_REGION_MAP fresh and capture them into a local
-- table, exactly as bridge/war_hook.lua's own WarBridge.load() does (this
-- is the same file, read a second time -- there is no divergence risk,
-- and this file never mutates the shared WAR_STATE/WAR_REGION_MAP
-- globals war_hook.lua also uses). Returns nil on any failure.
function PopulationPlacement.loadWarState()
	WAR_STATE = nil
	WAR_REGION_MAP = nil

	-- includeFile paths resolve relative to scripts/screenplays/
	-- (DirectorManager::includeFile) regardless of which file calls it.
	includeFile("../custom_scripts/war/region_map.lua")
	includeFile("../custom_scripts/war/war_state.lua")

	if type(WAR_STATE) ~= "table" or type(WAR_STATE.regions) ~= "table"
			or type(WAR_STATE.generated_at_tick) ~= "number" then
		return nil
	end

	local state = WAR_STATE
	WAR_STATE = nil
	WAR_REGION_MAP = nil

	return state
end

-- ========================================================= region set ===

--- All region ids that have a site of `kind` ("aid_post" or "cantina") in
-- population_config.lua's pools, and whose contest is below the
-- withdrawal threshold right now. Sorted so ties are never table-order
-- dependent.
local function sitePool(kind)
	if kind == "aid_post" then
		return POPULATION_AID_POSTS
	elseif kind == "cantina" then
		return POPULATION_CANTINAS
	end
	return nil
end

local function eligibleRegions(kind, warState)
	local pool = sitePool(kind)
	if pool == nil then
		return nil
	end

	local eligible = {}
	for i = 1, #POPULATION_REGION_IDS do
		local regionId = POPULATION_REGION_IDS[i]
		local site = pool[regionId]
		local region = warState.regions[regionId]

		if site ~= nil and type(region) == "table" and type(region.contest) == "number"
				and region.contest < POPULATION_WITHDRAW_THRESHOLD then
			eligible[#eligible + 1] = regionId
		end
	end

	if #eligible == 0 then
		return nil
	end

	table.sort(eligible)

	return eligible
end

--- The bias-ordering key for one region, as three independently comparable
-- values (docs/DESIGN-POPULATION.md S4.7.3): medic prefers frontier=true
-- ("toward the front"), performer prefers frontier=false ("away from the
-- front"); both then prefer lower threat; the region id breaks any
-- remaining tie so the order never depends on table iteration.
local function sortKey(bias, regionId, region)
	local frontier = region.frontier == true
	local threat = region.threat
	if type(threat) ~= "number" then
		threat = 0
	end

	local primary
	if bias == "toward_front" then
		primary = frontier and 0 or 1
	else -- "away_from_front"
		primary = frontier and 1 or 0
	end

	return primary, threat, regionId
end

local function keyLess(a, b)
	if a[1] ~= b[1] then return a[1] < b[1] end
	if a[2] ~= b[2] then return a[2] < b[2] end
	return a[3] < b[3]
end

--- Order-then-halve pool (S4.7.3): a probability weighted by contest would
-- thrash near a threshold; a sort-then-halve pool only changes when a
-- region actually crosses the boundary, matching S6.4's deadband
-- discipline.
local function biasedHalfPool(kind, bias, warState)
	local eligible = eligibleRegions(kind, warState)
	if eligible == nil then
		return nil
	end

	local keyed = {}
	for i = 1, #eligible do
		local regionId = eligible[i]
		local region = warState.regions[regionId]
		local p1, p2, p3 = sortKey(bias, regionId, region)
		keyed[#keyed + 1] = { p1, p2, p3, regionId }
	end

	table.sort(keyed, keyLess)

	local half = math.ceil(#keyed / 2)
	local pool = {}
	for i = 1, half do
		pool[#pool + 1] = keyed[i][4]
	end

	return pool
end

-- ========================================================= placement ====

--- The pure function itself. Returns the region id (or nil, fail-safe)
-- `providerId` (e.g. "medic_1") should occupy at `warState`'s tick, given
-- `alreadyPlacedPlanets` -- a set of planet names already used by earlier
-- providers of the SAME kind THIS cycle (min_separation = "planet",
-- S4.7.1). Callers place providers of one kind in fixed id order and pass
-- the growing set forward so two of a kind never share a planet.
--
-- `excludedRegions` (optional, a set of region ids) is skipped the same way
-- a used planet is: standing_services.lua passes the regions its GUARANTEED
-- slots already occupy, so an ambient roamer is never drawn to a front that
-- already has a provider of its kind -- which put two identical NPCs on the
-- same coordinates whenever a front's contest sat below the withdrawal
-- threshold.
function PopulationPlacement.computeSite(kind, providerId, warState, alreadyPlacedPlanets, excludedRegions)
	if warState == nil then
		return nil
	end

	local providerCfg = POPULATION_PROVIDERS[kind]
	if providerCfg == nil then
		return nil
	end

	-- providerCfg.kind is the SITE kind ("aid_post"/"cantina"); `kind`
	-- itself is the PROVIDER kind ("medic"/"performer") -- sitePool()
	-- keys on the former.
	local pool = biasedHalfPool(providerCfg.kind, providerCfg.bias, warState)
	if pool == nil then
		return nil
	end

	local cycle = math.floor(warState.generated_at_tick / POPULATION_PROVIDERS.circuit_ticks)
	local hashInput = POPULATION_PROVIDERS.salt .. ":" .. providerId .. ":" .. cycle
	local idx = stableHash(hashInput) % #pool

	alreadyPlacedPlanets = alreadyPlacedPlanets or {}
	excludedRegions = excludedRegions or {}

	-- Advance past any site on an already-used planet or in an excluded
	-- region, bounded by pool size so a pool that is genuinely all one
	-- planet (fail-safe, not an infinite loop) just accepts the collision
	-- rather than hanging.
	local attempts = 0
	while attempts < #pool do
		local regionId = pool[idx + 1]
		local planet = POPULATION_REGION_PLANET[regionId]

		if (planet == nil or not alreadyPlacedPlanets[planet]) and not excludedRegions[regionId] then
			return regionId
		end

		idx = (idx + 1) % #pool
		attempts = attempts + 1
	end

	-- Every candidate site is on an already-used planet (e.g. the pool
	-- collapsed to one planet under heavy contest withdrawal). Accept the
	-- collision rather than returning nil -- a provider that is somewhere,
	-- even sharing a planet with its twin, beats one that fails to place.
	return pool[(idx % #pool) + 1]
end

--- How many war ticks remain before `regionId`'s placement (for this
-- providerId at this warState) is next reconsidered -- the bartender
-- rumour's "she'll be there another day or so" line (S4.7.5).
function PopulationPlacement.ticksUntilNextCycle(warState)
	if warState == nil then
		return nil
	end

	local ticks = POPULATION_PROVIDERS.circuit_ticks
	local intoThisCycle = warState.generated_at_tick % ticks

	return ticks - intoThisCycle
end

-- ==================================================== front regions ====
--
-- The owner's front-region guarantee (superseding D15's scarcity-only
-- design for active-battle cities specifically -- see standing_services.lua
-- refreshKind()) reuses war_battle.lua's own "active battle" signal
-- (WarReport.frontRegions(): contest >= WarBattle.MIN_CONTEST (1.0), ranked,
-- capped at WarReport.MAX_FRONT_REGIONS (3)) rather than deriving a second
-- definition from WAR_STATE here. This thin wrapper just makes the call
-- fail-safe the same way every other function in this file is: missing
-- WarReport (not loaded into this Lua state, or a malformed war state
-- underneath it) degrades to "no guaranteed slots this pass", never a
-- Lua error.

function PopulationPlacement.frontRegions()
	if type(WarReport) ~= "table" or type(WarReport.frontRegions) ~= "function" then
		return {}
	end

	local ok, result = pcall(WarReport.frontRegions)
	if not ok or type(result) ~= "table" then
		return {}
	end

	return result
end

-- =================================================== index <-> region ===

function PopulationPlacement.regionIndex(regionId)
	for i = 1, #POPULATION_REGION_IDS do
		if POPULATION_REGION_IDS[i] == regionId then
			return i
		end
	end
	return nil
end

function PopulationPlacement.regionById(index)
	if index == nil or index < 1 or index > #POPULATION_REGION_IDS then
		return nil
	end
	return POPULATION_REGION_IDS[index]
end

-- ================================================= shared-memory state ==
--
-- The ONLY state this file carries (S4.7.6): one applied-region index per
-- provider id, written by the spawner whenever it actually places or
-- relocates a provider (including the first placement), read by both the
-- spawner (to decide "am I already there") and the bartender rumour (to
-- report the REAL site, which can lag the pure computed one while a
-- player is standing near the provider -- the deferral case). Integer
-- only, per writeSharedMemory's own contract (DirectorManager.cpp:1424).

local function sharedKey(providerId)
	return "population:" .. providerId .. ":appliedRegionIdx"
end

function PopulationPlacement.getAppliedRegion(providerId)
	local idx = readSharedMemory(sharedKey(providerId))
	if idx == nil or idx == 0 then
		return nil
	end
	return PopulationPlacement.regionById(idx)
end

function PopulationPlacement.setAppliedRegion(providerId, regionId)
	local idx = PopulationPlacement.regionIndex(regionId)
	if idx == nil then
		return
	end
	writeSharedMemory(sharedKey(providerId), idx)
end

--- What a reader (the bartender rumour, primarily) should say `providerId`
-- is doing right now: the actually-applied region if one has been
-- recorded, falling back to the pure computed site (S4.7.6's fallback
-- rule). Never throws; returns nil if nothing can be determined.
function PopulationPlacement.currentRegion(kind, providerId, warState, alreadyPlacedPlanets)
	local applied = PopulationPlacement.getAppliedRegion(providerId)
	if applied ~= nil then
		return applied
	end

	return PopulationPlacement.computeSite(kind, providerId, warState, alreadyPlacedPlanets)
end
