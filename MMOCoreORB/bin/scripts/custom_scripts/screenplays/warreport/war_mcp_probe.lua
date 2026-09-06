--[[
  custom_scripts/screenplays/warreport/war_mcp_probe.lua

  THE SERVER-SIDE ACTION CHANNEL for tools/swgclient-mcp (B35): the console's
  `test <name>` takes no arguments (ServerCore.cpp builds the function name
  from the whole argument string), and `runLuaFunction` is compiled out of
  this build, so a tool that wants the server to DO something with
  parameters -- teleport a player by name, spawn a war NPC at a town, set a
  faction, read a region's coordinates -- needs one more hop: the MCP
  writes the request to a file the server can read, then injects
  `test mcpLua`, which runs it and prints the result under a marker the MCP
  greps. The file lives under the server's own cwd (bin/): log/mcp/request.lua,
  the same directory tree the contribution spool uses, owned by the user the
  server runs as.

  REQUEST FORMAT. First line `-- id: <token>` (the MCP's correlation id, echoed
  on every output line so a stale block can never be mistaken for this run),
  then Lua. The chunk runs in an environment that falls through to the globals
  (WarReport, WarLines, WarBattle, getPlayerByName, spawnMobile ...) with one
  extra: `out(...)` prints a line under the marker. A `return` value is printed
  too. Errors are caught and printed as `MCPLUA <id>: ERROR | ...`; the file is
  deleted after the run so the same request cannot run twice.

  THIS IS ARBITRARY LUA ON THE GAME SERVER. It exists for a local development
  server driven by one tool on the same machine; the only writer of the
  request file is that tool. It is not a player-facing feature and must never
  be reachable from the game.
]]

WarMcp = WarMcp or {}
WarMcp.REQUEST_PATH = "log/mcp/request.lua"
WarMcp.MAX_LINES = 400

local function say(id, kind, text)
	printf("MCPLUA " .. tostring(id) .. ": " .. kind .. " | " .. tostring(text) .. "\n")
end

local function render(v)
	local t = type(v)
	if t == "table" then
		local keys = {}
		for k, _ in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			local val = v[k]
			if val == nil then val = v[tonumber(k)] end
			parts[#parts + 1] = k .. "=" .. tostring(val)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

--- test mcpLua: run log/mcp/request.lua once and print the result.
function Tests:mcpLua()
	local f = io.open(WarMcp.REQUEST_PATH, "r")
	if f == nil then
		printf("MCPLUA -: ERROR | no request at " .. WarMcp.REQUEST_PATH .. "\n")
		return
	end
	local src = f:read("a")
	f:close()
	os.remove(WarMcp.REQUEST_PATH)
	local id = string.match(src, "^%-%-%s*id:%s*([%w_%-]+)") or "?"
	say(id, "begin", string.format("%d bytes", #src))
	local lines = 0
	local env = setmetatable({
		out = function(...)
			local parts = {}
			for i = 1, select("#", ...) do parts[#parts + 1] = render((select(i, ...))) end
			lines = lines + 1
			if lines <= WarMcp.MAX_LINES then
				say(id, "out", table.concat(parts, "\t"))
			end
		end,
	}, { __index = _G })
	local chunk, err = load(src, "mcp:" .. id, "t", env)
	if chunk == nil then
		say(id, "ERROR", "load: " .. tostring(err))
		say(id, "end", "load failed")
		return
	end
	local ok, res = pcall(chunk)
	if not ok then
		say(id, "ERROR", tostring(res))
	elseif res ~= nil then
		say(id, "return", render(res))
	end
	if lines > WarMcp.MAX_LINES then
		say(id, "out", string.format("... %d more line(s) dropped", lines - WarMcp.MAX_LINES))
	end
	say(id, "end", ok and "ok" or "error")
end

-- ------------------------------------------------------------ helpers --
-- Small, named actions the MCP composes, so a request is one line and the
-- lock/zone handling lives here once.

--- Move a player (by first name) to a war region's town centre or to x, y on
-- a planet. Cross-planet through switchZone. Returns what it did.
function WarMcp.teleportPlayer(name, regionId, x, y, planet)
	local p = getPlayerByName(name)
	if p == nil then
		return "no player named " .. tostring(name) .. " (offline, or not in the name map until a restart)"
	end
	if regionId ~= nil then
		local c = WarReport.COORDS[regionId]
		local pl = WarReport.PLANET_OF[regionId]
		if c == nil or pl == nil then
			return "no ground for region " .. tostring(regionId)
		end
		x, y, planet = c[1], c[2], pl
	end
	if x == nil or y == nil or planet == nil then
		return "need a region, or x, y and a planet"
	end
	local z = getWorldFloor(x, y, planet) or 0
	SceneObject(p):switchZone(planet, x, z, y, 0)
	return string.format("%s -> %s (%.0f, %.0f, z %.1f)", name, planet, x, y, z)
end

--- Set a player's faction and status: faction "rebel"|"imperial"|"neutral",
-- status "overt"|"covert"|"onleave". Uses the same constants the recruiter uses.
function WarMcp.setFaction(name, faction, status)
	local p = getPlayerByName(name)
	if p == nil then
		return "no player named " .. tostring(name)
	end
	local creo = CreatureObject(p)
	-- FACTIONREBEL / FACTIONIMPERIAL are globals the director sets from C++
	-- (Factions::FACTIONREBEL ...); the status values are Core3's FactionStatus
	-- (ONLEAVE 0, COVERT 1, OVERT 2), with the globals used when present.
	local crc = { rebel = FACTIONREBEL or 0x16148850, imperial = FACTIONIMPERIAL or 0xDB4ACC54, neutral = 0 }
	local st = { onleave = FACTIONSTATUS_ONLEAVE or 0, covert = FACTIONSTATUS_COVERT or 1, overt = FACTIONSTATUS_OVERT or 2 }
	if faction ~= nil then
		if crc[faction] == nil then return "unknown faction " .. tostring(faction) end
		creo:setFaction(crc[faction])
	end
	if status ~= nil then
		if st[status] == nil then return "unknown status " .. tostring(status) end
		creo:setFactionStatus(st[status])
	end
	return string.format("%s: faction=%s status=%s overt=%s", name, tostring(creo:getFaction()), tostring(status), tostring(creo:isOvert()))
end

--- Spawn a creature template at x, y on a planet (or at a region's centre
-- plus an offset). Returns the object id, or why not.
function WarMcp.spawn(template, planet, x, y, regionId, dx, dy)
	if regionId ~= nil then
		local c = WarReport.COORDS[regionId]
		planet = WarReport.PLANET_OF[regionId]
		if c == nil or planet == nil then return "no ground for region " .. tostring(regionId) end
		x, y = c[1] + (dx or 0), c[2] + (dy or 0)
	end
	local z = getWorldFloor(x, y, planet) or 0
	local p = spawnMobile(planet, template, 0, x, z, y, 0, 0)
	if p == nil then
		return "spawnMobile returned nil for " .. tostring(template) .. " (unknown template, or a mobile/ file not loaded)"
	end
	return string.format("oid=%d %s at %s (%.0f, %.0f, z %.1f)", SceneObject(p):getObjectID(), template, planet, x, y, z)
end

--- Same-zone move by (dx, dy) metres: SceneObject:teleport, no loading screen.
function WarMcp.nudge(name, dx, dy)
	local p = getPlayerByName(name)
	if p == nil then
		return "no player named " .. tostring(name)
	end
	local so = SceneObject(p)
	local zone, x, y = so:getZoneName(), so:getWorldPositionX() + (dx or 0), so:getWorldPositionY() + (dy or 0)
	local z = getWorldFloor(x, y, zone) or so:getWorldPositionZ()
	so:teleport(x, z, y, 0)
	return string.format("%s nudged to (%.0f, %.0f, z %.1f) on %s", name, x, y, z, zone)
end

--- Re-enter a war town so its arrival lines fire with the client fully
-- loaded: a cross-zone switch drops the player inside the presence area
-- while the client is still on its loading screen, and the lines sent then
-- are lost (measured 2026-09-06 at Anchorhead: the cooldown key was
-- stamped, nothing reached the chat log). Clears the per-player cooldown,
-- steps 500 m out of the 400 m presence radius and back, both same-zone.
-- Call it ~10 s after a switchZone.
function WarMcp.walkIn(name, regionId)
	local p = getPlayerByName(name)
	if p == nil then
		return "no player named " .. tostring(name)
	end
	local c = WarReport.COORDS[regionId]
	local planet = WarReport.PLANET_OF[regionId]
	if c == nil or planet == nil then
		return "no ground for region " .. tostring(regionId)
	end
	local so = SceneObject(p)
	if so:getZoneName() ~= planet then
		return "player is on " .. tostring(so:getZoneName()) .. ", not " .. planet .. "; switch zones first"
	end
	deleteData(so:getObjectID() .. ":war:presence:" .. regionId)
	local ox, oy = c[1] + 500, c[2]
	so:teleport(ox, getWorldFloor(ox, oy, planet) or 0, oy, 0)
	local z = getWorldFloor(c[1], c[2], planet) or 0
	so:teleport(c[1], z, c[2], 0)
	return string.format("%s stepped out to (%.0f, %.0f) and back into %s at (%.0f, %.0f, z %.1f); cooldown cleared", name, ox, oy, regionId, c[1], c[2], z)
end

--- Where a player is: planet, x, y, z, and the war region if inside one.
function WarMcp.whereIs(name)
	local p = getPlayerByName(name)
	if p == nil then
		return "no player named " .. tostring(name)
	end
	local so = SceneObject(p)
	local zone, x, y, z = so:getZoneName(), so:getWorldPositionX(), so:getWorldPositionY(), so:getWorldPositionZ()
	local region = WarReport.regionAt(zone, x, y)
	return string.format("%s on %s at (%.0f, %.0f, z %.1f) region=%s dead=%s overt=%s", name, tostring(zone), x, y, z,
		tostring(region), tostring(CreatureObject(p):isDead()), tostring(CreatureObject(p):isOvert()))
end
