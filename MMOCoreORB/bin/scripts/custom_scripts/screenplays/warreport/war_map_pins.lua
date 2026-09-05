--[[
  custom_scripts/screenplays/warreport/war_map_pins.lua

  Surface 6: the war on the PLANETARY MAP itself -- not waypoints on the
  radar (war_map.lua, surface 5), the map screen a player opens with the
  planet button. One entry per war city, under the map's "Points of
  Interest" category, whose NAME carries the picture:

      Bestine: Rebel-held | supply CUT | Contested
      Coronet: Imperial-held | supply ok | Quiet

  HOW (research 2026-09-05, docs/research/planet-map-overlay.md): the client
  draws whatever the server has registered with the zone's MapLocationTable
  (GetMapLocationsResponseMessage): object id, displayed name, world x/y, a
  category index, an icon. Categories come from the client's own
  datatables/player/planet_map_cat.iff, read out of the TREs: "poi" (54) is a
  primary category visible to EVERY faction; "rebel"/"imperial" (45/46) are
  factionVisibleOnly, so a marker in those would show to one side only. The
  overlay therefore uses "poi" and puts the faction in the name.

  The marker object is an ordinary active area (invisible, radius 2) with a
  custom name, given the category and registered through three small Lua
  bindings added to LuaSceneObject (setPlanetMapCategory,
  registerWithPlanetaryMap, unregisterWithPlanetaryMap). A MapLocationEntry
  snapshots the name at registration, so a change of holder or supply is
  unregister -> rename -> register. Refreshed every REFRESH_MS; the map is
  fetched by the client when it opens, so a change shows on the next open.

  This file spawns nothing at include time (CLAUDE.md rule): the tail only
  schedules a gated kick, exactly as war_courier.lua and sim_players.lua do.
  If the bindings are absent (server binary older than this file) every
  pcall below fails closed and the probe says so.
]]

WarMapPins = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "WarMapPins",
}

registerScreenPlay("WarMapPins", true)

WarMapPins.CATEGORY   = "poi"
WarMapPins.REFRESH_MS = 5 * 60 * 1000
WarMapPins.OIDS_KEY   = "warmappins:oids"      -- region=oid,region=oid,...
WarMapPins.CHAIN_KEY  = "warmappins:chain_ms"
WarMapPins.KICK_KEY   = "warmappins:kick_ms"
WarMapPins.KICK_GAP_MS = 60 * 1000

local function now()
	return getTimestampMilli()
end

local function labelKey(regionId)
	return "warmappins:label:" .. regionId
end

-- ------------------------------------------------------------ registry ----

function WarMapPins.registry()
	local out = {}
	local raw = readStringData(WarMapPins.OIDS_KEY)
	if raw == nil or raw == "" then
		return out
	end
	for region, oid in string.gmatch(raw, "([%w_]+)=(%d+)") do
		out[region] = tonumber(oid)
	end
	return out
end

function WarMapPins.saveRegistry(reg)
	local parts, keys = {}, {}
	for region, _ in pairs(reg) do keys[#keys + 1] = region end
	table.sort(keys)
	for _, region in ipairs(keys) do
		parts[#parts + 1] = region .. "=" .. tostring(reg[region])
	end
	writeStringData(WarMapPins.OIDS_KEY, table.concat(parts, ","))
end

-- --------------------------------------------------------------- label ----

function WarMapPins.label(regionId)
	local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	local r = (st ~= nil and st.regions ~= nil) and st.regions[regionId] or nil
	local name = (WarReport ~= nil and WarReport.regionName ~= nil) and WarReport.regionName(regionId) or regionId
	if r == nil then
		return name .. ": no report"
	end
	-- "Imperial-held", not "the Empire-held": the adjective, not the noun.
	local holder = (WarReport ~= nil and WarReport.factionAdjective ~= nil) and WarReport.factionAdjective(r.faction) or tostring(r.faction)
	local supply = tostring(r.supply_status or "unknown")
	if supply == "connected" then supply = "ok" else supply = string.upper(supply) end
	local tier = ""
	if WarMap ~= nil and WarMap.contestTier ~= nil then
		tier = WarMap:contestTier(r.contest)
	end
	local stock = ""
	if type(r.supply_stock) == "table" and r.faction ~= nil and r.supply_stock[r.faction] ~= nil then
		stock = string.format(" ~%d", math.floor(tonumber(r.supply_stock[r.faction]) or 0))
	end
	return string.format("%s: %s-held | supply %s%s | %s", name, holder, supply, stock, tier)
end

-- ---------------------------------------------------------------- pins ----

local function register(pArea, label)
	local so = SceneObject(pArea)
	local ok1, catOk = pcall(function() return so:setPlanetMapCategory(WarMapPins.CATEGORY) end)
	if not ok1 or not catOk then
		return false, "no binding or unknown category"
	end
	pcall(function() so:setCustomObjectName(label) end)
	local ok2, regOk = pcall(function() return so:registerWithPlanetaryMap() end)
	if not ok2 or not regOk then
		return false, "register failed"
	end
	return true
end

--- Make sure `regionId` has a live, correctly-labelled pin. Returns one of
-- "kept" / "renamed" / "spawned" / "skipped" / "failed".
function WarMapPins.ensure(regionId, reg)
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	local zone = (WarReport ~= nil) and WarReport.PLANET_OF[regionId] or nil
	if coords == nil or zone == nil or not isZoneEnabled(zone) then
		return "skipped"
	end

	local label = WarMapPins.label(regionId)
	local oid = reg[regionId]
	local p = (oid ~= nil and oid ~= 0) and getSceneObject(oid) or nil

	if p ~= nil then
		if readStringData(labelKey(regionId)) == label then
			return "kept"
		end
		pcall(function() SceneObject(p):unregisterWithPlanetaryMap() end)
		local ok, why = register(p, label)
		if not ok then
			return "failed"
		end
		writeStringData(labelKey(regionId), label)
		return "renamed"
	end

	local pArea = spawnActiveArea(zone, "object/active_area.iff", coords[1], 0, coords[2], 2, 0)
	if pArea == nil then
		return "failed"
	end
	local ok, why = register(pArea, label)
	if not ok then
		pcall(function() SceneObject(pArea):destroyObjectFromWorld(false) end)
		return "failed"
	end
	reg[regionId] = SceneObject(pArea):getObjectID()
	writeStringData(labelKey(regionId), label)
	return "spawned"
end

function WarMapPins.refresh()
	if WarReport == nil or WarReport.COORDS == nil then
		return { skipped = 0 }
	end
	local reg = WarMapPins.registry()
	local counts = { kept = 0, renamed = 0, spawned = 0, skipped = 0, failed = 0 }
	local ids = {}
	for id, _ in pairs(WarReport.COORDS) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local ok, result = pcall(WarMapPins.ensure, id, reg)
		local key = ok and result or "failed"
		counts[key] = (counts[key] or 0) + 1
	end
	WarMapPins.saveRegistry(reg)
	return counts
end

function WarMapPins.clear()
	local reg = WarMapPins.registry()
	local n = 0
	for region, oid in pairs(reg) do
		local p = getSceneObject(oid)
		if p ~= nil then
			pcall(function() SceneObject(p):unregisterWithPlanetaryMap() end)
			pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
			n = n + 1
		end
		pcall(function() deleteStringData(labelKey(region)) end)
	end
	writeStringData(WarMapPins.OIDS_KEY, "")
	return n
end

-- ---------------------------------------------------------------- loop ----

function WarMapPins:tick()
	writeSharedMemory(WarMapPins.CHAIN_KEY, now())
	pcall(function()
		local c = WarMapPins.refresh()
		if (c.spawned or 0) + (c.renamed or 0) + (c.failed or 0) > 0 then
			printf(string.format("WarMapPins: refresh -- kept %d, renamed %d, spawned %d, failed %d, skipped %d\n",
				c.kept or 0, c.renamed or 0, c.spawned or 0, c.failed or 0, c.skipped or 0))
		end
	end)
	createEvent(WarMapPins.REFRESH_MS, "WarMapPins", "tick", nil, "")
end

function WarMapPins:ensureChain()
	local last = readSharedMemory(WarMapPins.CHAIN_KEY) or 0
	if last ~= 0 and (now() - last) < (3 * WarMapPins.REFRESH_MS) then
		return false
	end
	writeSharedMemory(WarMapPins.CHAIN_KEY, now())
	createEvent(5000, "WarMapPins", "tick", nil, "")
	return true
end

function WarMapPins:kick()
	self:ensureChain()
end

function WarMapPins:start()
	self:ensureChain()
end

-- ------------------------------------------------------------- probes -----

function Tests:warMapPinsCheck()
	printf("WARMAPPINS: begin\n")
	local reg = WarMapPins.registry()
	local alive, total = 0, 0
	local ids = {}
	for id, _ in pairs(reg) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		total = total + 1
		local p = getSceneObject(reg[id])
		if p ~= nil then alive = alive + 1 end
		printf(string.format("WARMAPPINS: %-16s oid=%s alive=%s label=%s\n", id, tostring(reg[id]), tostring(p ~= nil),
			tostring(readStringData(labelKey(id)))))
	end
	local chain = readSharedMemory(WarMapPins.CHAIN_KEY) or 0
	printf(string.format("WARMAPPINS: %d/%d pins alive, chain heartbeat %ds ago\n", alive, total,
		(chain > 0) and math.floor((now() - chain) / 1000) or -1))
	printf("WARMAPPINS: end\n")
end

function Tests:warMapPinsRefresh()
	printf("WARMAPPINS: refresh begin\n")
	local c = WarMapPins.refresh()
	printf(string.format("WARMAPPINS: refresh -- kept %d, renamed %d, spawned %d, failed %d, skipped %d\n",
		c.kept or 0, c.renamed or 0, c.spawned or 0, c.failed or 0, c.skipped or 0))
	printf("WARMAPPINS: refresh end\n")
end

function Tests:warMapPinsClear()
	printf("WARMAPPINS: cleared " .. tostring(WarMapPins.clear()) .. " pin(s)\n")
end

-- ===================================================== include-time kick ==
pcall(function()
	local last = readSharedMemory(WarMapPins.KICK_KEY) or 0
	local t = getTimestampMilli()
	if last == 0 or (t - last) >= WarMapPins.KICK_GAP_MS then
		writeSharedMemory(WarMapPins.KICK_KEY, t)
		createEvent(4000, "WarMapPins", "kick", nil, "")
	end
end)
