--[[
  custom_scripts/screenplays/bazaar/bazaar_stock.lua

  Bazaar stocking, stage S2 (see docs/DECISIONS.md and this stage's brief). Stage
  S1 (merged, live) gave us three DirectorManager bindings --
  bazaarBotList/bazaarBotCancel/bazaarBotCounts -- and nothing else. This file is
  the actual policy that decides WHAT to list, WHEN, and how much, for three
  ghost-seller depots. It does not touch AuctionManager/AuctionsMap directly and
  never will (owner ruling, carried over from S1).

  OWNER RULING THIS BUILDS TO (overrules DESIGN-POPULATION.md S3.11 -- settled,
  not re-litigated here): "we don't have enough players to populate it so we
  should add things to it to help." A synthetic seller cannot be a fiction --
  Core3 destroys any bazaar listing whose owner is not a real characters row
  (AuctionManagerImplementation.cpp:117-123 at boot, :375-396 hourly) -- so every
  depot's sellerName below must resolve to a REAL character, created by hand in
  stage S3 (a human step; this file assumes nothing about that having happened
  yet and fails safe when it hasn't -- see resolveSeller()).

  ==========================================================================
  THE OFFLINE-SELLER RESOURCE HAZARD -- WHAT WAS FOUND AND HOW IT'S HANDLED
  ==========================================================================
  Both givePlayerResource (DirectorManager.cpp:1134, confirmed via
  `Zone* zone = player->getZone(); ... if (zone == nullptr) return 0;`) and
  createLoot's isRandomResourceContainer() path
  (LootManagerImplementation.cpp:784-789, confirmed via
  `auto zone = container->getZone(); if (zone == nullptr) return 0;`) bail out
  silently the moment the destination container has no zone -- which is exactly
  the state of a ghost seller's inventory: SceneObjectImplementation::getZone()
  walks up the parent chain to find a root zone, and a character that has never
  logged in (or is simply offline) has none. A resource crate can never be
  created directly into an offline seller's inventory.

  Consumables do NOT have this problem. giveItem (DirectorManager.cpp:2441) uses
  `ZoneServer* zoneServer = obj->getZoneServer();` -- a static server-wide
  reference, not the object's own zone -- and `obj->transferObject(item, slot,
  true, overload)`; ContainerComponent::transferObject
  (ContainerComponent.cpp:206) has no zone-null check anywhere in its body (only
  removes-from-old-zone-if-any / adds-to-new-zone-if-any). giveItem's own
  post-transfer `item->sendTo(parent, true)` is likewise safe offline --
  SceneObjectImplementation::sendTo (SceneObjectImplementation.cpp:364) returns
  immediately when `player->getClient() == nullptr`. So every consumable listing
  below is created with a single giveItem() call straight into the seller's
  inventory -- no special handling needed.

  RESOURCES: STAGING THROUGH A ZONED TRANSIENT CONTAINER (verified by reading
  the mechanism, not by assuming it -- this worktree cannot deploy to prove it
  live; see the S3 probe section below for the exact live check to run once a
  seller exists)
  --------------------------------------------------------------------------
  createLoot's zone check is on the CONTAINER PASSED IN, not on the resource's
  eventual owner. So:
    1. spawnSceneObject() a plain object/tangible/container/loot/loot_crate.iff
       (a stock, zero-risk ContainerComponent template -- see
       object/tangible/container/loot/loot_crate.lua) into a real zone, at a
       coordinate far from every war-mapped city (BAZAAR_CONFIG.STAGING_*).
       This container has a zone.
    2. createLoot(stagingContainer, "resource_container_<type>", 0, false) --
       container->getZone() now succeeds, createLootResource runs normally at
       the VANILLA quantity band (5-50, untouched -- see the QUANTITY note
       below), and the resulting resource crate is transferred into the
       STAGING container (LootManagerImplementation.cpp:804's own
       container->transferObject call).
    3. setResourceContainerQuantity(crate, depotEntry.qtyMin..qtyMax roll) --
       a new, narrow DirectorManager Lua binding added this stage (see its own
       header comment in DirectorManager.cpp for the full guard/ignoreMax
       writeup) wrapping the existing native
       ResourceContainer::setQuantity(newQuantity, notifyClient=true,
       ignoreMax=false, destroyEmpty=true) (ResourceContainer.idl) -- real,
       already shipped, simply never bound to Lua before now. This is what
       actually gives the crate a bigger-than-vanilla quantity, scoped to
       exactly this one crate.
    4. Fetch/keep the crate reference, then call
       sellerInventory:transferObject(crate, -1, false) -- the SAME
       LuaSceneObject::transferObject binding used everywhere else in this
       codebase (LuaSceneObject.cpp:567), which goes through the same
       ContainerComponent::transferObject already shown above to have no zone
       requirement. The crate ends up in the (zoneless) seller's inventory.
    5. Destroy the now-empty staging container (destroyObjectFromWorld(), the
       same one-line cleanup screenplays/tools/firework_event.lua and
       helperfuncs.lua's despawnMobileTask already use for transient spawns).
  Steps 1-5 happen inside one function call on one screenplay tick -- nothing
  is ever visible near a player, and nothing persists if any step fails
  (createStagedResource() below cleans up and returns nil rather than leaving
  a stray crate or staging container behind).

  QUANTITY: NOT a global template override any more. An earlier version of
  this stage overrode the vanilla resource_container_<type> LOOT ITEM
  TEMPLATES directly (custom_scripts/loot/serverobjects.lua) to get a bigger
  band. That was reverted per owner ruling once it was measured that those
  templates are referenced by 598 groupTemplate entries across mob loot
  tables galaxy-wide (loot/groups/npc/**) -- the override silently buffed
  every mob resource drop in the game 6-18x, not just the bazaar's own
  crates. custom_scripts/loot/serverobjects.lua is back to empty; vanilla
  resource_container_<type> loot items stay at their stock 5-50 band for
  everything except what this file explicitly resizes via
  setResourceContainerQuantity AFTER creation, scoped to exactly the one
  crate just created in the staging container -- nothing else in the game is
  touched.

  THE resource_container_<type> NAME ITSELF STILL CANNOT CHANGE -- see
  bazaar_config.lua's pool-entry doc comment: LootManagerImplementation.cpp
  strips the literal "resource_container_" prefix to match a currently-spawned
  ResourceSpawn's type, so createLoot must still be called with one of the 13
  vanilla names, just at its own (now irrelevant, since step 3 resizes it
  immediately after) vanilla quantity.

  CONCLUSION: resources ARE achievable for an offline ghost seller, via the
  staging + resize mechanism above. This is a source-level conclusion, not a
  live-verified one (see the S3 verification section near the end of this
  file for the exact console probe to run once a seller exists) --
  createStagedResource() is written to fail loud and safe (log, return nil,
  never error into the screenplay tick) if any step of it doesn't behave as
  traced, so a wrong assumption here degrades to "this depot's resource
  entries never list, or list at the vanilla 5-50 if only the resize call
  itself misbehaves" rather than a crash or a corrupted bazaar.

  ==========================================================================
  ELIGIBILITY GUARDS (owner-specified, applied to every created item just
  before listing, not just trusted from the pool tables above it)
  ==========================================================================
    - getJunkValue() > 0        -- the junk dealer (screenplays/junk_dealer/
                                    junk_dealer.lua) already buys items for
                                    cash; anything worth more as junk than as
                                    a listing is a conversion loop.
    - getCraftersName() ~= ""   -- never resell player work. Always empty for
                                    everything this file creates (giveItem/
                                    createLoot never set a crafter), but
                                    checked anyway, not just assumed.
    - isNoTrade()                -- never list a no-trade item.
    - template on the faction-perk deny list (bazaar_config.lua, built from
      screenplays/gcw/recruiters/factionPerkData.lua at include time) --
      never overlaps this file's own pools, checked anyway.
    - price clamped into AuctionManager's own native range -- bazaarBotList
      itself already rejects out-of-range prices (INVALIDSALEPRICE), so this
      is belt-and-braces, not the only guard.

  ==========================================================================
  TAPER FORMULA (owner ruling: "automatic taper ... no manual switch-off
  needed")
  ==========================================================================
    playerListings   = totalBazaarForSale (galaxy-wide, bazaarBotCounts) minus
                        the sum of all three depots' OWN ownerListings (so real
                        player listings are isolated from our own bot noise).
    desired(depot)    = clamp(depot.target - playerListings, 0, SAFETY_CAP)
    gap               = desired - (this depot's own currently-tracked active
                        listings)
  A tick adds up to gap, capped again by a small per-tick jitter
  (MIN/MAX_ADD_PER_TICK) and by how many pool templates aren't already active,
  so a depot never refills in one shot. Worked examples (depot.target=12,
  SAFETY_CAP=20):
    playerListings=0   -> desired = clamp(12-0,  0,20) = 12  (full story, no
                          real competition yet)
    playerListings=5   -> desired = clamp(12-5,  0,20) = 7   (tapering as
                          players list things)
    playerListings=40  -> desired = clamp(12-40, 0,20) = 0   (real players have
                          long since out-listed this depot; it goes quiet on
                          its own, no switch needed)

  A slot only frees up once its own tracking record expires (mirroring
  AuctionManager's native COMMODITYEXPIREPERIOD = 7 days,
  AuctionManager.idl:45) or the underlying object is confirmed gone
  (getSceneObject returns nil) -- see sweepDepot()'s header note for why an
  early real-player purchase is deliberately NOT detected any faster than
  that: S1 exposes no per-item sold/cancelled signal, only aggregate counts,
  so this stage conservatively under-restocks rather than risk a duplicate
  listing of the same template.
]]

BazaarStock = ScreenPlay:new{
	numberOfActs = 1,
	screenplayName = "BazaarStock",
}

registerScreenPlay("BazaarStock", true)

-- ============================================================== constants ==

-- AuctionManager.idl:36 -- not exposed to Lua, mirrored here as a belt-and-
-- braces clamp; bazaarBotList itself already enforces the real one natively.
local MAXBAZAARPRICE = 20000

-- AuctionManager.idl:45 (COMMODITYEXPIREPERIOD, seconds) -- bazaar listings are
-- "commodity" sales, not vendor sales (VENDOREXPIREPERIOD at idl:44 is the
-- 30-day vendor-terminal constant and does not apply here). Mirrored so this
-- file's own tracking records expire in step with the native listing, not
-- before or after it.
local COMMODITY_EXPIRE_MS = 604800 * 1000

local HEARTBEAT_KEY = "bazaarstock:heartbeat"

local function recordsKey(depotId)
	return "bazaarstock:records:" .. depotId
end

-- Reset on every reload -- worst case one extra "seller missing" log line
-- right after a reload-lua.sh, never a functional problem (see resolveSeller).
local sellerWarnAt = {}
local terminalWarnAt = {}

-- =========================================================== record store ==
--
-- One entry per currently-tracked listing: objectID, the pool key it was
-- listed from (a template path or a resource_container_<type> name -- see
-- bazaar_config.lua's DEPOTS pool shape), and the tick-local expiry mirroring
-- COMMODITY_EXPIRE_MS. Serialized as "oid|expiresAtMs|key" entries joined by
-- ";", same STRING-shared-memory approach population/street_life.lua uses for
-- its own per-city tracked-oid lists (survives reloadscreenplays, visible
-- from every VM/thread).

function BazaarStock:parseRecords(depotId)
	local raw = readStringSharedMemory(recordsKey(depotId))
	local out = {}
	if raw == nil or raw == "" then
		return out
	end
	for token in string.gmatch(raw, "([^;]+)") do
		local oidStr, expiresStr, key = token:match("^(%d+)|(%d+)|(.+)$")
		if oidStr ~= nil then
			out[#out + 1] = { oid = tonumber(oidStr), expiresAt = tonumber(expiresStr), key = key }
		end
	end
	return out
end

function BazaarStock:serializeRecords(depotId, records)
	local parts = {}
	for i = 1, #records do
		local r = records[i]
		parts[#parts + 1] = tostring(r.oid) .. "|" .. tostring(r.expiresAt) .. "|" .. r.key
	end
	writeStringSharedMemory(recordsKey(depotId), table.concat(parts, ";"))
end

function BazaarStock:trackRecord(depotId, oid, key, listedAtMs)
	local records = self:parseRecords(depotId)
	records[#records + 1] = { oid = oid, expiresAt = listedAtMs + COMMODITY_EXPIRE_MS, key = key }
	self:serializeRecords(depotId, records)
end

--- Drops any record past its own mirrored expiry, or whose object is
-- confirmed gone (getSceneObject nil). Deliberately does NOT try to detect an
-- early real-player purchase (S1's bindings expose no per-item sold signal) --
-- see this file's TAPER FORMULA header note. Returns the surviving list, which
-- callers use both to compute "how many do we currently have" and to build the
-- "which templates are already active" set for the at-most-one-per-template
-- rule.
function BazaarStock:sweepDepot(depot)
	local records = self:parseRecords(depot.id)
	local kept = {}
	local now = getTimestampMilli()

	for i = 1, #records do
		local r = records[i]
		if now >= r.expiresAt then
			-- expired by our own mirrored TTL; nothing to destroy, the native
			-- 7-day sweep either already removed the listing or will shortly.
		elseif getSceneObject(r.oid) == nil then
			-- object confirmed gone by some other means; drop silently.
		else
			kept[#kept + 1] = r
		end
	end

	self:serializeRecords(depot.id, kept)
	return kept
end

-- ============================================================= resolution ==

--- getPlayerByName resolves an OFFLINE character just as well as an online
-- one (PlayerManagerImplementation::getPlayer looks the name up in nameMap
-- and fetches the object by oid -- no online check at all), which is the
-- entire basis this design rests on. Logs at most once an hour per depot when
-- the configured seller does not resolve, rather than once a tick, so an
-- un-created S3 seller degrades to "list nothing, log occasionally" and never
-- spams the log or errors into the screenplay tick. Pass quiet=true for an
-- internal cross-depot lookup (taper math) that should not itself warn --
-- the depot's own tick already warns once for its own seller.
function BazaarStock:resolveSeller(depot, quiet)
	local pSeller = getPlayerByName(depot.sellerName)

	if pSeller == nil and not quiet then
		local now = getTimestampMilli()
		local last = sellerWarnAt[depot.id] or 0
		if now - last > 60 * 60 * 1000 then
			printf("BazaarStock: seller '" .. depot.sellerName .. "' for depot '" .. depot.id
				.. "' does not resolve (getPlayerByName returned nil) -- listing NOTHING for this "
				.. "depot until that character exists (stage S3, a human step).\n")
			sellerWarnAt[depot.id] = now
		end
	end

	return pSeller
end

--- Resolves a live bazaar terminal for depot.homeRegion via the exact
-- getCityRegionAt + CityRegion:getBazaar(idx) mechanism bazaar_probe.lua
-- already proved live in S1. Logs at most once an hour per depot on failure.
function BazaarStock:resolveTerminal(depot)
	local pRegion = getCityRegionAt(depot.homeZone, depot.homeX, depot.homeY)

	if pRegion == nil then
		local now = getTimestampMilli()
		local last = terminalWarnAt[depot.id] or 0
		if now - last > 60 * 60 * 1000 then
			printf("BazaarStock: getCityRegionAt failed for depot '" .. depot.id .. "' (" .. depot.homeZone
				.. " " .. tostring(depot.homeX) .. "," .. tostring(depot.homeY) .. ") -- listing nothing this pass.\n")
			terminalWarnAt[depot.id] = now
		end
		return nil
	end

	local region = CityRegion(pRegion)
	local count = region:getBazaarCount()

	if count <= 0 then
		local now = getTimestampMilli()
		local last = terminalWarnAt[depot.id] or 0
		if now - last > 60 * 60 * 1000 then
			printf("BazaarStock: depot '" .. depot.id .. "' region has getBazaarCount()=0 -- listing nothing this pass.\n")
			terminalWarnAt[depot.id] = now
		end
		return nil
	end

	return region:getBazaar(0)
end

function BazaarStock:depotById(depotId)
	for i = 1, #BAZAAR_CONFIG.DEPOTS do
		if BAZAAR_CONFIG.DEPOTS[i].id == depotId then
			return BAZAAR_CONFIG.DEPOTS[i]
		end
	end
	return nil
end

-- ============================================================== guards ==

--- Returns true, nil on success or false, reason on rejection. See file
-- header for why each check exists.
function BazaarStock:isEligible(pItem)
	local okJunk, junkValue = pcall(function() return TangibleObject(pItem):getJunkValue() end)
	if okJunk and junkValue ~= nil and junkValue > 0 then
		return false, "junk value " .. tostring(junkValue) .. " > 0 (junk dealer conversion loop)"
	end

	local okCrafter, crafter = pcall(function() return TangibleObject(pItem):getCraftersName() end)
	if okCrafter and crafter ~= nil and crafter ~= "" then
		return false, "has a crafter's name ('" .. crafter .. "')"
	end

	local okTrade, noTrade = pcall(function() return TangibleObject(pItem):isNoTrade() end)
	if okTrade and noTrade == true then
		return false, "no-trade flag set"
	end

	local okPath, templatePath = pcall(function() return SceneObject(pItem):getTemplateObjectPath() end)
	if okPath and templatePath ~= nil and BAZAAR_CONFIG.FACTION_PERK_DENY_LIST[templatePath] then
		return false, "on the faction-perk deny-list ('" .. templatePath .. "')"
	end

	return true, nil
end

--- +/- BAZAAR_CONFIG.PRICE_JITTER_PCT around basePrice, clamped into
-- AuctionManager's own native [1, MAXBAZAARPRICE] range (belt-and-braces --
-- bazaarBotList enforces the real one natively).
function BazaarStock:jitterPrice(basePrice)
	local pct = BAZAAR_CONFIG.PRICE_JITTER_PCT
	local low = math.floor(basePrice * (100 - pct) / 100)
	local high = math.ceil(basePrice * (100 + pct) / 100)

	if low < 1 then
		low = 1
	end
	if high < low then
		high = low
	end

	local price = getRandomNumber(low, high)

	if price < 1 then
		price = 1
	elseif price > MAXBAZAARPRICE then
		price = MAXBAZAARPRICE
	end

	return price
end

-- ============================================================ resource path ==

--- See file header (THE OFFLINE-SELLER RESOURCE HAZARD) for the full
-- mechanism and why each step is safe. qtyMin/qtyMax are the depot pool
-- entry's own band (bazaar_config.lua) -- a random quantity in that range is
-- rolled and applied via setResourceContainerQuantity() after the crate is
-- created, since createLoot() itself only ever produces the vanilla 5-50
-- (see the QUANTITY note in the file header for why that's now deliberate).
-- Returns the resource item, already inside pSellerInventory, or nil (having
-- logged why and cleaned up after itself) on any failure.
function BazaarStock:createStagedResource(lootItemName, qtyMin, qtyMax, pSellerInventory)
	local pStaging = spawnSceneObject(
		BAZAAR_CONFIG.STAGING_ZONE,
		"object/tangible/container/loot/loot_crate.iff",
		BAZAAR_CONFIG.STAGING_X, BAZAAR_CONFIG.STAGING_Z, BAZAAR_CONFIG.STAGING_Y,
		0, 0
	)

	if pStaging == nil then
		printf("BazaarStock: staging container spawn FAILED (zone='" .. tostring(BAZAAR_CONFIG.STAGING_ZONE)
			.. "') -- resource listing '" .. lootItemName .. "' skipped this pass.\n")
		return nil
	end

	local lootOid = createLoot(pStaging, lootItemName, 0, false)

	if lootOid == nil or lootOid == 0 then
		printf("BazaarStock: createLoot FAILED for resource '" .. lootItemName .. "' -- most likely no active "
			.. "resource spawn of this type in '" .. tostring(BAZAAR_CONFIG.STAGING_ZONE) .. "' right now "
			.. "(resource spawns rotate). Skipped this pass, will retry on a later tick.\n")
		pcall(function() SceneObject(pStaging):destroyObjectFromWorld() end)
		return nil
	end

	local pResource = getSceneObject(lootOid)

	if pResource == nil then
		printf("BazaarStock: getSceneObject could not resolve freshly-created resource oid="
			.. tostring(lootOid) .. " -- skipped this pass.\n")
		pcall(function() SceneObject(pStaging):destroyObjectFromWorld() end)
		return nil
	end

	-- Resize BEFORE transferring out of the staging container -- doesn't
	-- matter which container the crate sits in for this call (setQuantity
	-- doesn't touch containment), but keeping it staged until every step has
	-- either succeeded or been decided means a hard failure below still
	-- cleans up in one place (destroy the staging container, which takes the
	-- crate with it).
	local wantedQty = getRandomNumber(qtyMin, qtyMax)
	local resized = setResourceContainerQuantity(pResource, wantedQty)

	if not resized then
		-- Not fatal: the crate is still a perfectly valid resource item, just
		-- at whatever createLoot's own vanilla roll (5-50) gave it. Listing a
		-- smaller-than-intended crate is a minor loss; destroying a good item
		-- and skipping this depot's resource lane entirely over a resize
		-- failure would be a worse outcome for a single degraded call.
		printf("BazaarStock: setResourceContainerQuantity FAILED for '" .. lootItemName
			.. "' oid=" .. tostring(lootOid) .. " (wanted " .. tostring(wantedQty)
			.. ") -- listing it at its vanilla quantity instead of failing the whole listing.\n")
	end

	local transferred = SceneObject(pSellerInventory):transferObject(pResource, -1, false)

	if not transferred then
		printf("BazaarStock: transferObject FAILED moving resource oid=" .. tostring(lootOid)
			.. " into the seller's inventory -- destroying the staging container (and the orphaned "
			.. "resource with it) rather than leaving anything behind.\n")
		pcall(function() SceneObject(pStaging):destroyObjectFromWorld() end)
		return nil
	end

	pcall(function() SceneObject(pStaging):destroyObjectFromWorld() end)

	return pResource
end

-- ================================================================ listing ==

function BazaarStock:tryListEntry(depot, pSeller, pInventory, pTerminal, entry)
	local key = entry.template or entry.lootItem
	local pItem = nil

	if entry.kind == "consumable" then
		pItem = giveItem(pInventory, entry.template, -1)
		if pItem == nil then
			printf("BazaarStock: giveItem FAILED for '" .. entry.template .. "' (depot '" .. depot.id .. "')\n")
			return
		end
	elseif entry.kind == "resource" then
		pItem = self:createStagedResource(entry.lootItem, entry.qtyMin, entry.qtyMax, pInventory)
		if pItem == nil then
			return -- createStagedResource already logged why
		end
	else
		printf("BazaarStock: unknown pool entry kind '" .. tostring(entry.kind) .. "' for depot '" .. depot.id .. "'\n")
		return
	end

	local eligible, reason = self:isEligible(pItem)
	if not eligible then
		printf("BazaarStock: REFUSED listing '" .. key .. "' (depot '" .. depot.id .. "') -- " .. tostring(reason) .. "\n")
		pcall(function() SceneObject(pItem):destroyObjectFromDatabase(true) end)
		return
	end

	local price = self:jitterPrice(entry.basePrice)
	local itemOid = SceneObject(pItem):getObjectID()
	local code = bazaarBotList(pSeller, itemOid, pTerminal, depot.listingNote or "", price)

	if code ~= 0 then
		printf("BazaarStock: bazaarBotList FAILED code=" .. tostring(code) .. " for '" .. key
			.. "' (depot '" .. depot.id .. "', price=" .. tostring(price) .. ") -- destroying the item.\n")
		pcall(function() SceneObject(pItem):destroyObjectFromDatabase(true) end)
		return
	end

	self:trackRecord(depot.id, itemOid, key, getTimestampMilli())
end

-- ========================================================== taper + tick ==

--- Sums every OTHER depot's own ownerListings (quiet -- does not warn on a
-- missing seller here, the depot's own tick already will) and returns
-- max(0, totalBazaarForSale - sumOfAllOwnerListings). Falls back to
-- currentSeller's own totalBazaarForSale reading if every other seller is
-- unresolved (e.g. only one of three characters exists yet) since
-- totalBazaarForSale is galaxy-wide and identical from any seller's call.
function BazaarStock:computePlayerListings(currentSeller)
	local sumOwner = 0
	local total = 0
	local gotTotal = false

	for i = 1, #BAZAAR_CONFIG.DEPOTS do
		local d = BAZAAR_CONFIG.DEPOTS[i]
		local pS = self:resolveSeller(d, true)
		if pS ~= nil then
			local owner, tot = bazaarBotCounts(pS)
			sumOwner = sumOwner + (owner or 0)
			if not gotTotal then
				total = tot or 0
				gotTotal = true
			end
		end
	end

	if not gotTotal and currentSeller ~= nil then
		local owner, tot = bazaarBotCounts(currentSeller)
		total = tot or 0
	end

	local playerListings = total - sumOwner
	if playerListings < 0 then
		playerListings = 0
	end

	return playerListings
end

--- The actual per-depot per-tick work. No reschedule of its own (mirrors
-- population/street_life.lua's tickOnce()/cityTick() split) so a probe can
-- call this directly, repeatably, without ever creating a second parallel
-- timer chain for a depot.
function BazaarStock:restockOnce(depot)
	writeSharedMemory(HEARTBEAT_KEY, getTimestampMilli())

	local kept = self:sweepDepot(depot)

	if not BAZAAR_CONFIG.ENABLED then
		return
	end

	local pSeller = self:resolveSeller(depot, false)
	if pSeller == nil then
		return
	end

	local pTerminal = self:resolveTerminal(depot)
	if pTerminal == nil then
		return
	end

	local ownerListings = bazaarBotCounts(pSeller)

	-- Hard ceiling independent of the tracked-record gap math below, in case
	-- tracking ever drifts from reality (e.g. this file's own bug, or a manual
	-- bazaarBotList call from outside this screenplay) -- never let a restock
	-- push this seller anywhere near AuctionManager's native MAXSALES=25 wall.
	if ownerListings >= BAZAAR_CONFIG.SAFETY_CAP then
		return
	end

	local playerListings = self:computePlayerListings(pSeller)
	local desired = depot.target - playerListings

	if desired < 0 then
		desired = 0
	elseif desired > BAZAAR_CONFIG.SAFETY_CAP then
		desired = BAZAAR_CONFIG.SAFETY_CAP
	end

	local trackedActive = #kept
	local gap = desired - trackedActive

	if gap <= 0 then
		return
	end

	-- Occasionally stock nothing this pass even with room, so restocking
	-- doesn't read as a metronome (owner constraint: "let it occasionally
	-- roll nothing").
	if getRandomNumber(1, 100) <= BAZAAR_CONFIG.SKIP_TICK_CHANCE_PCT then
		return
	end

	local activeKeys = {}
	for i = 1, #kept do
		activeKeys[kept[i].key] = true
	end

	-- At most one listing per template per depot at a time (owner
	-- constraint): only pool entries not already active are candidates.
	local candidates = {}
	for i = 1, #depot.pool do
		local entry = depot.pool[i]
		local key = entry.template or entry.lootItem
		if not activeKeys[key] then
			candidates[#candidates + 1] = entry
		end
	end

	if #candidates == 0 then
		return
	end

	local pInventory = CreatureObject(pSeller):getSlottedObject("inventory")
	if pInventory == nil then
		printf("BazaarStock: seller '" .. depot.sellerName .. "' has no inventory slot -- skipping this pass.\n")
		return
	end

	-- 1-3 new listings a pass, never a refill -- ages stay staggered.
	local wanted = getRandomNumber(BAZAAR_CONFIG.MIN_ADD_PER_TICK, BAZAAR_CONFIG.MAX_ADD_PER_TICK)
	local addCount = math.min(gap, wanted, #candidates)

	for i = 1, addCount do
		local idx = getRandomNumber(1, #candidates)
		local entry = table.remove(candidates, idx)
		self:tryListEntry(depot, pSeller, pInventory, pTerminal, entry)
	end
end

function BazaarStock:jitterMs()
	return getRandomNumber(BAZAAR_CONFIG.TICK_MIN_MS, BAZAAR_CONFIG.TICK_MAX_MS)
end

--- Self-rescheduling timer entry point. Whole tick body in pcall; the
-- reschedule below is OUTSIDE that pcall and unconditional, so a mid-tick
-- error in one depot can never stop that depot's own loop (copied from
-- warreport/war_battle.lua's WarBattle:cycle(), same pattern
-- population/street_life.lua's StreetLife:cityTick() uses).
function BazaarStock:depotTick(pObj, depotId)
	local depot = self:depotById(depotId)

	if depot ~= nil then
		pcall(function() self:restockOnce(depot) end)
	end

	createEvent(self:jitterMs(), "BazaarStock", "depotTick", nil, depotId)
end

-- Delay before the first tick, same reasoning as
-- population/street_life.lua's StreetLife.BOOT_DELAY_MS: isZoneEnabled/the
-- zone server generally is not ready yet at true start() time.
BazaarStock.BOOT_DELAY_MS = 60000

function BazaarStock:start()
	if not BAZAAR_CONFIG.ENABLED then
		return
	end

	for i = 1, #BAZAAR_CONFIG.DEPOTS do
		createEvent(self.BOOT_DELAY_MS, "BazaarStock", "depotTick", nil, BAZAAR_CONFIG.DEPOTS[i].id)
	end
end
