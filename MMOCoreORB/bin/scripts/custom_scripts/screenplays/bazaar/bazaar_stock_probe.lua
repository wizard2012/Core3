--[[
  custom_scripts/screenplays/bazaar/bazaar_stock_probe.lua

  Stage S2 console-callable proof for bazaar_stock.lua. Follows the same
  pattern as custom_scripts/screenplays/bazaar/bazaar_probe.lua (S1),
  warreport/war_probe.lua and starterpack/starter_pack_probe.lua.

  IMPORTANT -- none of the three depot sellers exist yet (stage S3, a human
  step). Every test below is written to behave correctly in that state:
  bazaarStockConfigProbe never touches a seller or the bazaar at all, and
  bazaarStockDryRun calls the real restockOnce() for each configured depot
  and simply reports what resolveSeller()/resolveTerminal() see -- against a
  real 0-seller galaxy this is expected to print "seller does not resolve"
  for all three and list nothing, which is the fail-safe/fail-loud behaviour
  itself being verified, not a failure of the probe.

  RUN (after at least one seller character exists, to see it actually try to
  list something -- see docs/DECISIONS.md for the S3 handoff):
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test bazaarStockConfigProbe\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test bazaarStockDryRun\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep BAZAARSTOCKPROBE ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -60"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports No Sockets found even on a healthy server.

  bazaarStockDryRun calls BazaarStock:restockOnce() directly (no reschedule),
  the same tickOnce()-not-cityTick() split street_probe.lua relies on for
  StreetLife -- safe to call repeatedly without spinning up a second parallel
  timer chain for a depot.
]]

--- Pure data/shape checks -- no seller, no terminal, no bazaar touched at
-- all. Confirms bazaar_config.lua loaded, the deny-list built (non-empty --
-- factionPerkData.lua has ~65 item= paths), every pool entry has a resolvable
-- key, and that pool size >= target for each depot (the "at most one listing
-- per template" rule can only ever reach `target` active listings if the
-- pool has at least that many distinct templates).
function Tests:bazaarStockConfigProbe()
	printf("BAZAARSTOCKPROBE: begin config probe\n")

	if BAZAAR_CONFIG == nil then
		printf("BAZAARSTOCKPROBE: FAIL -- BAZAAR_CONFIG is nil (bazaar_config.lua did not load)\n")
		return
	end

	local denyCount = 0
	for _ in pairs(BAZAAR_CONFIG.FACTION_PERK_DENY_LIST or {}) do
		denyCount = denyCount + 1
	end
	printf("BAZAARSTOCKPROBE: faction-perk deny-list size = " .. tostring(denyCount) .. " (expect > 0)\n")

	for i = 1, #BAZAAR_CONFIG.DEPOTS do
		local depot = BAZAAR_CONFIG.DEPOTS[i]
		local poolSize = #depot.pool
		local ok = poolSize >= depot.target

		printf("BAZAARSTOCKPROBE: depot '" .. depot.id .. "' sellerName='" .. depot.sellerName
			.. "' target=" .. tostring(depot.target) .. " poolSize=" .. tostring(poolSize)
			.. " (pool>=target: " .. tostring(ok) .. ")\n")

		for j = 1, poolSize do
			local entry = depot.pool[j]
			local key = entry.template or entry.lootItem
			if key == nil then
				printf("BAZAARSTOCKPROBE: FAIL -- depot '" .. depot.id .. "' pool entry " .. j .. " has no template/lootItem\n")
			end
			if entry.kind ~= "consumable" and entry.kind ~= "resource" then
				printf("BAZAARSTOCKPROBE: FAIL -- depot '" .. depot.id .. "' pool entry " .. j .. " has unknown kind '" .. tostring(entry.kind) .. "'\n")
			end
			if BAZAAR_CONFIG.FACTION_PERK_DENY_LIST[key] then
				printf("BAZAARSTOCKPROBE: FAIL -- depot '" .. depot.id .. "' pool entry '" .. tostring(key) .. "' is on the faction-perk deny-list\n")
			end
		end
	end

	printf("BAZAARSTOCKPROBE: end config probe\n")
end

--- Calls the real per-depot tick logic once per depot, with NO reschedule.
-- Against zero real sellers this proves the fail-safe/fail-loud path (logs
-- "does not resolve", lists nothing, does not error). Once a seller exists,
-- this becomes the live proof that it actually lists something -- check
-- ownerListings/totalBazaarForSale before and after via bazaarBotCounts.
function Tests:bazaarStockDryRun()
	printf("BAZAARSTOCKPROBE: begin dry run (calls the real restockOnce() per depot)\n")

	for i = 1, #BAZAAR_CONFIG.DEPOTS do
		local depot = BAZAAR_CONFIG.DEPOTS[i]

		local pSellerBefore = getPlayerByName(depot.sellerName)
		local ownerBefore, totalBefore = 0, 0
		if pSellerBefore ~= nil then
			ownerBefore, totalBefore = bazaarBotCounts(pSellerBefore)
		end

		printf("BAZAARSTOCKPROBE: depot '" .. depot.id .. "' BEFORE sellerResolved=" .. tostring(pSellerBefore ~= nil)
			.. " ownerListings=" .. tostring(ownerBefore) .. " totalBazaarForSale=" .. tostring(totalBefore) .. "\n")

		local ok, err = pcall(function() BazaarStock:restockOnce(depot) end)
		if not ok then
			printf("BAZAARSTOCKPROBE: FAIL -- restockOnce() threw for depot '" .. depot.id .. "': " .. tostring(err) .. "\n")
		end

		local pSellerAfter = getPlayerByName(depot.sellerName)
		local ownerAfter, totalAfter = 0, 0
		if pSellerAfter ~= nil then
			ownerAfter, totalAfter = bazaarBotCounts(pSellerAfter)
		end

		printf("BAZAARSTOCKPROBE: depot '" .. depot.id .. "' AFTER  sellerResolved=" .. tostring(pSellerAfter ~= nil)
			.. " ownerListings=" .. tostring(ownerAfter) .. " totalBazaarForSale=" .. tostring(totalAfter) .. "\n")
	end

	printf("BAZAARSTOCKPROBE: end dry run\n")
end

--- Isolated proof of the offline-seller resource staging mechanism AND the
-- new setResourceContainerQuantity binding (stage S2's C++ addition), against
-- a specific resource_container_<type> loot item name, independent of any
-- seller (creates the crate, resizes it, then immediately destroys the
-- staging container and the crate itself -- does NOT list or transfer to any
-- seller). This is now the ONLY live check of the quantity-setting path:
-- no Lua binding exposes ResourceContainer::getQuantity() (no
-- LuaResourceContainer class exists in this codebase, and this stage
-- deliberately added only the setter, not a getter), so the setter's own
-- return value -- and the guard cases below -- are as much as can be checked
-- from a console probe. Also useful, independent of the quantity binding, to
-- confirm createLoot's zone-dependent path actually works in THIS galaxy's
-- current resource spawn state before blaming bazaar_stock.lua's own logic
-- for a depot never listing its resource entries.
function Tests:bazaarStockResourceProbe()
	printf("BAZAARSTOCKPROBE: begin resource staging + quantity probe\n")

	local pStaging = spawnSceneObject(
		BAZAAR_CONFIG.STAGING_ZONE,
		"object/tangible/container/loot/loot_crate.iff",
		BAZAAR_CONFIG.STAGING_X, BAZAAR_CONFIG.STAGING_Z, BAZAAR_CONFIG.STAGING_Y,
		0, 0
	)

	if pStaging == nil then
		printf("BAZAARSTOCKPROBE: FAIL -- spawnSceneObject returned nil for staging container in zone '"
			.. tostring(BAZAAR_CONFIG.STAGING_ZONE) .. "'\n")
		return
	end

	printf("BAZAARSTOCKPROBE: staging container spawned oid=" .. tostring(SceneObject(pStaging):getObjectID()) .. "\n")

	-- Guard case 1: nil object. Must return false, not crash.
	local nilCase = setResourceContainerQuantity(nil, 500)
	printf("BAZAARSTOCKPROBE: setResourceContainerQuantity(nil, 500) = " .. tostring(nilCase) .. " (expect false)\n")

	-- Guard case 2: wrong-type object (the staging container itself is a
	-- plain TangibleObject/ContainerComponent, not a ResourceContainer).
	-- Must return false, not crash.
	local wrongTypeCase = setResourceContainerQuantity(pStaging, 500)
	printf("BAZAARSTOCKPROBE: setResourceContainerQuantity(non-resource object, 500) = "
		.. tostring(wrongTypeCase) .. " (expect false)\n")

	local lootOid = createLoot(pStaging, "resource_container_metal", 0, false)
	printf("BAZAARSTOCKPROBE: createLoot(resource_container_metal) = " .. tostring(lootOid)
		.. " (0 or nil means no active metal spawn in this zone right now -- not necessarily a bug)\n")

	if lootOid ~= nil and lootOid ~= 0 then
		local pResource = getSceneObject(lootOid)
		if pResource ~= nil then
			-- Guard case 3: absurd/negative quantity on a REAL resource
			-- container. Must clamp and return true, not crash or silently
			-- accept the absurd value (unverifiable from Lua which value it
			-- actually landed on -- see file header -- but the return value
			-- and "did the server survive" are still meaningful).
			local negCase = setResourceContainerQuantity(pResource, -50)
			printf("BAZAARSTOCKPROBE: setResourceContainerQuantity(real crate, -50) = "
				.. tostring(negCase) .. " (expect true -- clamped to 1 internally)\n")

			-- The actual depot band this crate's real type would use.
			local band = { qtyMin = 300, qtyMax = 900 }
			local wantedQty = getRandomNumber(band.qtyMin, band.qtyMax)
			local realCase = setResourceContainerQuantity(pResource, wantedQty)
			printf("BAZAARSTOCKPROBE: setResourceContainerQuantity(real crate, " .. tostring(wantedQty)
				.. ") = " .. tostring(realCase) .. " (expect true)\n")

			pcall(function() SceneObject(pResource):destroyObjectFromDatabase(true) end)
		end
	end

	pcall(function() SceneObject(pStaging):destroyObjectFromWorld() end)

	printf("BAZAARSTOCKPROBE: end resource staging + quantity probe\n")
end
