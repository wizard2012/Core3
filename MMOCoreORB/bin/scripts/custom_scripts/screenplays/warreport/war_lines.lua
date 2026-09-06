--[[
  custom_scripts/screenplays/warreport/war_lines.lua

  THE SUPPLY WAR, slice 3 (docs/DESIGN-WAR-V2.md section 4, B33): the one
  place every player-facing line about the war is shaped. Section 4's rule
  is that every surface uses the same three facts per town -- crates and
  trend, road state, time to fall -- and the same two per faction -- days of
  reserve, roads held into the enemy capital. This module turns the exported
  war state (custom_scripts/war/war_state.lua, schema 4) into those lines and
  nothing else; the surfaces (map pins and radar labels in war_map*.lua, the
  arrival line in war_presence.lua, the login report in war_login.lua, the
  officer in war_officer*.lua, the dispatches in war_announce.lua) only
  choose which lines to send and to whom.

  PURE ON PURPOSE. No server binding is touched here: every function takes
  the state table (or a region record) and returns strings, so
  bridge/tests/t_readouts.lua can load this file into plain lua5.3 with a
  fixture state and assert every section-4 line byte for byte. If you need a
  server call, it belongs in the surface, not here. The only globals read
  are WarReport (display names, optional) and WarCourier.POINTS (how many
  crates one courier run is worth, optional), both nil-safe.

  SCHEMA 3 FALLBACK: a state without `crates` (an older export) still gets a
  sentence -- the old contest/supply_status words -- so nothing goes blank
  if the exporter and the game are ever one deploy apart.

  VOCABULARY (section 4's): "Empire" / "Alliance" as the sides,
  "Imperial-held" / "Rebel-held" for a town, "Imperial capital" / "Rebel
  capital" for a capital. Hours are "~N h" (under an hour: "under an hour";
  0: "now"); days are "N days" (under one: "under a day"). Crates are whole
  numbers. A capital's crates ARE its faction's reserve.
]]

WarLines = WarLines or {}

WarLines.SIDE = { imperial = "Empire", rebel = "Alliance" }
WarLines.HELD = { imperial = "Imperial-held", rebel = "Rebel-held" }
WarLines.ADJ  = { imperial = "Imperial", rebel = "Rebel" }
WarLines.LINE_BODIES = 12            -- a line at a front (DESIGN-BATTLES); the "wiped line" number
WarLines.DEFAULT_TICK_SECONDS = 900
WarLines.SUDDEN_DEATH_WARN_TICKS = 192 -- two days at 900 s
WarLines.FAR_TICKS = 3840 -- a countdown past the season's own horizon (40 days) is noise, not a fact

-- Sim regions with no city on the game side (no coords, no officer, no
-- battle) still exist in the war and must be readable. WarReport.PLANET_OF
-- stays the list of GROUND; this is the list for words only.
WarLines.PLANET_OF_EXTRA = {
	nab_lianorm  = "naboo",
	tat_jundland = "tatooine",
	cor_agrilat  = "corellia",
}

local function num(x)
	return tonumber(x)
end

local function round(x)
	return math.floor(x + 0.5)
end

local function other(faction)
	if faction == "imperial" then return "rebel" end
	if faction == "rebel" then return "imperial" end
	return nil
end

function WarLines.side(faction)
	return WarLines.SIDE[faction] or "no one"
end

function WarLines.name(regionId)
	if WarReport ~= nil and WarReport.regionName ~= nil then
		return WarReport.regionName(regionId)
	end
	local bare = tostring(regionId):gsub("^[a-z]+_", ""):gsub("_", " ")
	return (bare:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

function WarLines.planetOf(regionId)
	if WarReport ~= nil and WarReport.PLANET_OF ~= nil and WarReport.PLANET_OF[regionId] ~= nil then
		return WarReport.PLANET_OF[regionId]
	end
	return WarLines.PLANET_OF_EXTRA[regionId]
end

function WarLines.planetName(planet)
	if WarReport ~= nil and WarReport.planetName ~= nil then
		return WarReport.planetName(planet)
	end
	return tostring(planet)
end

function WarLines.tickSeconds(st)
	return (st ~= nil and num(st.tick_seconds)) or WarLines.DEFAULT_TICK_SECONDS
end

--- "~4 h" / "under an hour" / "now" / "~3 days". nil for nil.
function WarLines.hoursText(ticks, st)
	ticks = num(ticks)
	if ticks == nil then
		return nil
	end
	if ticks <= 0 then
		return "now"
	end
	local h = ticks * WarLines.tickSeconds(st) / 3600
	if h < 1 then
		return "under an hour"
	end
	if h >= 48 then
		return "~" .. round(h / 24) .. " days"
	end
	return "~" .. round(h) .. " h"
end

--- "19 days" / "1 day" / "under a day". nil for nil.
function WarLines.daysText(days)
	days = num(days)
	if days == nil then
		return nil
	end
	if days < 1 then
		return "under a day"
	end
	local d = round(days)
	return d .. (d == 1 and " day" or " days")
end

--- Is this a schema-4 record (crates present)?
function WarLines.isSupply(r)
	return r ~= nil and num(r.crates) ~= nil
end

function WarLines.crates(r)
	local c = num(r and r.crates)
	if c == nil then
		return nil
	end
	if c < 0 then c = 0 end
	return round(c)
end

--- "losing 9/h" / "gaining 12/h" / "holding". nil when unknown.
function WarLines.trendText(r)
	local cph = num(r and r.crates_per_hour)
	if cph == nil then
		return nil
	end
	if cph <= -0.5 then
		return "losing " .. round(-cph) .. "/h"
	elseif cph >= 0.5 then
		return "gaining " .. round(cph) .. "/h"
	end
	return "holding"
end

function WarLines.roadState(r)
	if r == nil then
		return nil
	end
	if r.road == "open" or r.road == "strained" or r.road == "cut" then
		return r.road
	end
	-- schema 3
	if r.supply_status == "connected" then return "open" end
	if r.supply_status == "degraded" then return "strained" end
	if r.supply_status == "cut" then return "cut" end
	return nil
end

--- "road open" / "road strained" / "road cut". nil when unknown.
function WarLines.roadText(r)
	local s = WarLines.roadState(r)
	if s == nil then
		return nil
	end
	return "road " .. s
end

--- "falls in ~4 h" / "falls at the next lost fight". nil when not losing.
function WarLines.fallText(r, st)
	local t = num(r and r.falls_in_ticks)
	if t == nil or t > WarLines.FAR_TICKS then
		return nil
	end
	if t <= 0 then
		return "falls at the next lost fight"
	end
	return "falls in " .. WarLines.hoursText(t, st)
end

--- A capital's countdown: "falls in ~7 h" under siege, "reserve dry in
-- ~2 days" otherwise -- the exporter's falls_in_ticks on a capital is the
-- reserve running out, and a capital that is not besieged does not fall
-- with it (DESIGN-WAR-V2 2.8), so the word must not say it does.
function WarLines.capitalFallText(r, st)
	local fall = WarLines.fallText(r, st)
	if fall == nil then
		return nil
	end
	if type(r.siege) == "table" and r.siege.active then
		return fall
	end
	return (fall:gsub("^falls in ", "reserve dry in "):gsub("^falls at the next lost fight", "reserve dry"))
end

--- Is the region a front (a fight staged against it)?
function WarLines.isFront(r)
	if r == nil then
		return false
	end
	if type(r.front) == "table" then
		return true
	end
	return (num(r.contest) or 0) >= 1.0
end

--- The status word every surface ends with: the fall, else "holding" at a
-- front, else "quiet".
function WarLines.statusText(r, st)
	local fall = WarLines.fallText(r, st)
	if fall ~= nil then
		return fall
	end
	if (num(r and r.grace_remaining) or 0) > 0 then
		return "grace " .. WarLines.hoursText(r.grace_remaining, st)
	end
	if WarLines.isFront(r) then
		return "holding"
	end
	return "quiet"
end

--- The faction record, or nil.
function WarLines.factionOf(st, faction)
	if st == nil or type(st.factions) ~= "table" then
		return nil
	end
	return st.factions[faction]
end

--- "reserve 19 days" / "reserve 10310 crates, steady" / nil.
function WarLines.reserveText(st, faction)
	local f = WarLines.factionOf(st, faction)
	if f == nil then
		return nil
	end
	local days = WarLines.daysText(f.reserve_days)
	if days ~= nil then
		return "reserve " .. days
	end
	local crates = num(f.reserve)
	if crates ~= nil then
		return "reserve " .. round(crates) .. " crates, steady"
	end
	return nil
end

--- "2 of 2 roads lost" / "3 roads open" / nil. A capital's siege block
-- counts the roads the ATTACKER holds into it.
function WarLines.siegeRoadsText(r)
	local s = r and r.siege
	if type(s) ~= "table" then
		return nil
	end
	local held, total = num(s.held) or 0, num(s.total) or 0
	if held <= 0 then
		return total .. (total == 1 and " road open" or " roads open")
	end
	return held .. " of " .. total .. (total == 1 and " road lost" or " roads lost")
end

--- The holder's capital on this region's planet, by id, or nil. The enemy's
-- roads_into lists exactly the holder's capitals.
function WarLines.capitalOf(st, faction, planet)
	local enemy = WarLines.factionOf(st, other(faction))
	if enemy == nil or type(enemy.roads_into) ~= "table" then
		return nil
	end
	local ids = {}
	for id, _ in pairs(enemy.roads_into) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if planet == nil or WarLines.planetOf(id) == planet then
			return id
		end
	end
	return nil
end

-- ------------------------------------------------------------ 4.1 pins --

--- Section 4.1, one line per town; identical on the planetary map and the
-- radar overlay.
--   Bestine: 37 crates, losing 9/h | falls in ~4 h | Rebel-held | road cut
--   Theed: UNDER SIEGE, 2 of 2 roads lost | reserve 19 days | falls in ~7 h | Imperial capital
--   Coronet: reserve 19 days | 1 of 3 roads lost | Imperial capital
-- FIELD ORDER (2026-09-06): the client's waypoint panel shows about 30
-- characters of a label (measured through the client MCP: "Mos Eisley:
-- Rebel-held | 0 crat..."), so the facts that CHANGE go first -- crates and
-- trend, then the countdown -- and the holder and road, which a pin's colour
-- already tells, go last. The section-4.1 example put the holder first.
function WarLines.pin(st, regionId)
	local r = st and st.regions and st.regions[regionId]
	local name = WarLines.name(regionId)
	if r == nil then
		return name .. ": no report"
	end
	if not WarLines.isSupply(r) then
		return WarLines.legacyPin(r, name)
	end
	local parts = {}
	if r.is_capital then
		local siege = r.siege
		local roads = WarLines.siegeRoadsText(r)
		if type(siege) == "table" and siege.active then
			parts[#parts + 1] = name .. ": UNDER SIEGE, " .. (roads or "roads lost")
			parts[#parts + 1] = WarLines.reserveText(st, r.faction) or "reserve unknown"
			parts[#parts + 1] = WarLines.fallText(r, st) or "holding"
		else
			parts[#parts + 1] = name .. ": " .. (WarLines.reserveText(st, r.faction) or "reserve unknown")
			if roads ~= nil then
				parts[#parts + 1] = roads
			end
			local fall = WarLines.capitalFallText(r, st)
			if fall ~= nil then
				parts[#parts + 1] = fall
			end
		end
		parts[#parts + 1] = (WarLines.ADJ[r.faction] or "Neutral") .. " capital"
	else
		local crates = WarLines.crates(r)
		local trend = WarLines.trendText(r)
		parts[#parts + 1] = name .. ": " .. crates .. " crates" .. (trend and (", " .. trend) or "")
		parts[#parts + 1] = WarLines.statusText(r, st)
		parts[#parts + 1] = WarLines.HELD[r.faction] or "unheld"
		local road = WarLines.roadText(r)
		if road ~= nil then
			parts[#parts + 1] = road
		end
	end
	return table.concat(parts, " | ")
end

--- The schema-3 pin, kept for an older export.
function WarLines.legacyPin(r, name)
	local held = WarLines.HELD[r.faction] or "unheld"
	local supply = tostring(r.supply_status or "unknown")
	if supply == "connected" then supply = "ok" else supply = string.upper(supply) end
	local contest = num(r.contest) or 0
	local tier = "Quiet"
	if contest >= 75 then tier = "HEAVY" elseif contest >= 25 then tier = "Contested" elseif contest >= 1 then tier = "Skirmish" end
	return string.format("%s: %s | supply %s | %s", name, held, supply, tier)
end

-- ------------------------------------------------------ 4.3 town lines --

--- Section 4.3's per-town line for the login report and the officer.
--   Bestine -- Rebel-held, 37 crates, road cut, falls in ~4 h.
--   Theed -- Imperial capital, under siege (2 of 2 roads lost), reserve 3 days, falls in ~7 h.
--   Coronet -- Imperial capital, reserve 19 days, 1 of 3 roads lost.
function WarLines.townLine(st, regionId)
	local r = st and st.regions and st.regions[regionId]
	if r == nil then
		return nil
	end
	local name = WarLines.name(regionId)
	if not WarLines.isSupply(r) then
		return WarLines.legacyTownLine(r, name)
	end
	local parts = {}
	if r.is_capital then
		parts[#parts + 1] = name .. " -- " .. (WarLines.ADJ[r.faction] or "Neutral") .. " capital"
		local siege = r.siege
		local roads = WarLines.siegeRoadsText(r)
		if type(siege) == "table" and siege.active then
			parts[#parts + 1] = "under siege (" .. (roads or "roads lost") .. ")"
			parts[#parts + 1] = WarLines.reserveText(st, r.faction) or "reserve unknown"
			parts[#parts + 1] = WarLines.fallText(r, st) or "holding"
		else
			parts[#parts + 1] = WarLines.reserveText(st, r.faction) or "reserve unknown"
			if roads ~= nil then
				parts[#parts + 1] = roads
			end
			local fall = WarLines.capitalFallText(r, st)
			if fall ~= nil then
				parts[#parts + 1] = fall
			end
		end
	else
		parts[#parts + 1] = name .. " -- " .. (WarLines.HELD[r.faction] or "unheld")
		parts[#parts + 1] = WarLines.crates(r) .. " crates"
		local road = WarLines.roadText(r)
		if road ~= nil then
			parts[#parts + 1] = road
		end
		parts[#parts + 1] = WarLines.statusText(r, st)
	end
	return table.concat(parts, ", ") .. "."
end

function WarLines.legacyTownLine(r, name)
	local who = (WarReport ~= nil and WarReport.factionName ~= nil) and WarReport.factionName(r.faction) or WarLines.side(r.faction)
	local line = name .. " -- held by " .. who
	local contest = num(r.contest) or 0
	if contest >= 75 then line = line .. ", under heavy attack"
	elseif contest >= 25 then line = line .. ", contested"
	elseif contest >= 1 then line = line .. ", skirmishing"
	else line = line .. ", quiet" end
	if r.supply_status == "cut" then line = line .. ", supply cut"
	elseif r.supply_status == "degraded" then line = line .. ", supply strained" end
	return line .. "."
end

--- Every town on one planet, sorted by id, as town lines.
function WarLines.planetLines(st, planet)
	local out = {}
	if st == nil or type(st.regions) ~= "table" or planet == nil then
		return out
	end
	local ids = {}
	for id, _ in pairs(st.regions) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if WarLines.planetOf(id) == planet then
			local line = WarLines.townLine(st, id)
			if line ~= nil then
				out[#out + 1] = line
			end
		end
	end
	return out
end

-- ------------------------------------------------------ 4.3 the report --

--- "=== Galactic Civil War, day 12 ===" (with the sudden-death countdown
-- when it is within two days, and the intermission when the season is over).
function WarLines.header(st)
	local s = st and st.season
	if type(s) ~= "table" then
		return "=== Galactic Civil War ==="
	end
	if s.winner ~= nil and s.winner ~= "" then
		local left = WarLines.hoursText(s.intermission_remaining, st)
		local line = "=== Season " .. tostring(s.index or "?") .. " is over: the " .. WarLines.side(s.winner) .. " won"
		if left ~= nil and left ~= "now" then
			line = line .. ". Next season in " .. left
		end
		return line .. " ==="
	end
	local day = math.floor(num(s.day) or 0)
	local line = "=== Galactic Civil War, day " .. day
	local sd = num(s.sudden_death_in_ticks)
	if sd ~= nil and sd <= WarLines.SUDDEN_DEATH_WARN_TICKS then
		line = line .. " -- sudden death in " .. WarLines.hoursText(sd, st)
	end
	return line .. " ==="
end

--- "Empire: 19 days of supply. Alliance: 11 days." -- who is winning.
function WarLines.reserveLine(st)
	local imp, reb = WarLines.factionOf(st, "imperial"), WarLines.factionOf(st, "rebel")
	if imp == nil or reb == nil then
		return nil
	end
	local function part(f, first)
		local days = WarLines.daysText(f.reserve_days)
		if days ~= nil then
			return days .. (first and " of supply" or "")
		end
		local crates = num(f.reserve)
		if crates ~= nil then
			return "supply steady (" .. round(crates) .. " crates)"
		end
		return "supply unknown"
	end
	return "Empire: " .. part(imp, true) .. ". Alliance: " .. part(reb, false) .. "."
end

--- "Alliance holds 1 of Theed's 2 roads and 0 of Coronet's 3; Empire holds 0 of Anchorhead's 3."
function WarLines.roadsLine(st)
	local clauses = {}
	for _, faction in ipairs({ "rebel", "imperial" }) do
		local f = WarLines.factionOf(st, faction)
		if f ~= nil and type(f.roads_into) == "table" then
			local ids = {}
			for id, _ in pairs(f.roads_into) do ids[#ids + 1] = id end
			table.sort(ids)
			local bits = {}
			for i, id in ipairs(ids) do
				local ri = f.roads_into[id]
				local held, total = num(ri.held) or 0, num(ri.total) or 0
				local bit = held .. " of " .. WarLines.name(id) .. "'s " .. total
				if i == 1 then
					bit = bit .. (total == 1 and " road" or " roads")
				end
				bits[#bits + 1] = bit
			end
			if #bits > 0 then
				clauses[#clauses + 1] = WarLines.side(faction) .. " holds " .. table.concat(bits, " and ")
			end
		end
	end
	if #clauses == 0 then
		return nil
	end
	return table.concat(clauses, "; ") .. "."
end

--- "Fronts: Bestine (Empire attacking, falls in ~4 h), Keren (Alliance attacking, holding), Moenia (Alliance offensive, led by Cmdr Terrik)."
function WarLines.frontsLine(st)
	local fronts = st and st.fronts
	if type(fronts) ~= "table" or #fronts == 0 then
		return "Fronts: none."
	end
	local parts = {}
	for _, fr in ipairs(fronts) do
		local r = st.regions and st.regions[fr.region]
		local what = WarLines.side(fr.attacker) .. (fr.offensive and " offensive" or " attacking")
		-- a capital that is not besieged does not fall with its reserve (2.8)
		local status = ((r ~= nil and r.is_capital) and WarLines.capitalFallText(r, st) or WarLines.fallText(r, st)) or "holding"
		local p = WarLines.name(fr.region) .. " (" .. what .. ", " .. status
		if fr.offensive and fr.officer ~= nil and fr.officer ~= "" then
			p = p .. ", led by " .. tostring(fr.officer)
		end
		parts[#parts + 1] = p .. ")"
	end
	return "Fronts: " .. table.concat(parts, ", ") .. "."
end

--- The whole login report (section 4.3) as a list of lines: header, who is
-- winning, roads into the capitals, fronts, then this planet's towns. With
-- `planet` nil the towns are omitted (the galaxy-wide part only); with
-- `allPlanets` true every planet is listed (the officer's report).
function WarLines.report(st, planet, allPlanets)
	local lines = {}
	if st == nil then
		return lines
	end
	lines[#lines + 1] = WarLines.header(st)
	local reserve = WarLines.reserveLine(st)
	if reserve ~= nil then lines[#lines + 1] = reserve end
	local roads = WarLines.roadsLine(st)
	if roads ~= nil then lines[#lines + 1] = roads end
	lines[#lines + 1] = WarLines.frontsLine(st)
	local planets = {}
	if allPlanets then
		planets = { "corellia", "naboo", "tatooine" }
	elseif planet ~= nil then
		planets = { planet }
	end
	for _, p in ipairs(planets) do
		local towns = WarLines.planetLines(st, p)
		if #towns > 0 then
			lines[#lines + 1] = "On " .. WarLines.planetName(p) .. ":"
			for _, t in ipairs(towns) do
				lines[#lines + 1] = "  " .. t
			end
		end
	end
	return lines
end

-- ---------------------------------------------------------- 4.2 arrival --

--- How many crates one courier run delivers (the game side owns this).
function WarLines.courierCrates()
	if WarCourier ~= nil and num(WarCourier.POINTS) ~= nil then
		return round(WarCourier.POINTS)
	end
	return 5
end

--- "buys ~35 min" / "buys ~2 h" for `crates` against a burn of `cph` (<0).
function WarLines.buysText(crates, cph)
	cph = num(cph)
	if cph == nil or cph >= -0.5 or crates == nil or crates <= 0 then
		return nil
	end
	local hours = crates / -cph
	if hours < 1 then
		return "buys ~" .. math.max(5, round(hours * 60 / 5) * 5) .. " min"
	end
	return "buys ~" .. round(hours) .. " h"
end

--- Section 4.2: the arrival line and the call to action, as a list of one
-- to three sentences (the surface sends each as a line).
--   The Alliance holds Bestine. 37 crates in store and falling -- the road from Anchorhead is cut.
--   Another ~4 h and the town is lost. A crate run from Anchorhead buys ~35 min.
function WarLines.arrival(st, regionId)
	local r = st and st.regions and st.regions[regionId]
	if r == nil or not WarLines.isSupply(r) then
		return {}
	end
	local name = WarLines.name(regionId)
	local planet = WarLines.planetOf(regionId)
	local out = {}
	if r.is_capital then
		local first = name .. " is the " .. WarLines.side(r.faction) .. "'s capital on " .. WarLines.planetName(planet) .. "."
		local reserve = WarLines.reserveText(st, r.faction)
		if reserve ~= nil then
			first = first .. " " .. reserve:gsub("^reserve", "Reserve:") .. "."
		end
		out[#out + 1] = first
		local siege, roads = r.siege, WarLines.siegeRoadsText(r)
		if type(siege) == "table" and siege.active then
			local fall = WarLines.fallText(r, st)
			out[#out + 1] = "UNDER SIEGE -- " .. (roads or "roads lost") .. (fall and ("; it " .. fall .. ".") or ".")
			out[#out + 1] = "Reopen a road -- retake a town on it -- or the capital falls with the reserve."
		elseif roads ~= nil then
			local dry = WarLines.capitalFallText(r, st)
			out[#out + 1] = roads:gsub("^%l", string.upper) .. (dry and ("; " .. dry) or "") .. "."
		end
		return out
	end

	local capitalId = WarLines.capitalOf(st, r.faction, planet)
	local capital = capitalId and WarLines.name(capitalId) or nil
	local from = capital and (" from " .. capital) or ""
	local crates = WarLines.crates(r)
	local cph = num(r.crates_per_hour) or 0
	local road = WarLines.roadState(r)
	local first = "The " .. WarLines.side(r.faction) .. " holds " .. name .. ". " .. crates .. " crates in store"
	if road == "cut" then
		first = first .. (cph <= -0.5 and " and falling" or "") .. " -- the road" .. from .. " is cut."
	elseif road == "strained" then
		first = first .. (cph <= -0.5 and " and falling" or "") .. " -- the road" .. from .. " is under strain."
	elseif cph <= -0.5 then
		first = first .. " and falling under the fighting."
	elseif cph >= 0.5 then
		first = first .. " and rising."
	else
		first = first .. " and holding."
	end
	out[#out + 1] = first

	local falls = num(r.falls_in_ticks)
	local run = WarLines.courierCrates()
	local buys = WarLines.buysText(run, cph)
	if falls ~= nil and falls <= 0 then
		out[#out + 1] = "One more lost fight and the town falls. Hold the line."
	elseif falls ~= nil then
		local second = "Another " .. WarLines.hoursText(falls, st) .. " and the town is lost."
		if road == "cut" then
			second = second .. " Reopen the road or run crates" .. from .. (buys and (" -- a crate run " .. buys .. ".") or ".")
		else
			second = second .. (buys and (" A crate run" .. from .. " " .. buys .. ".") or "")
		end
		out[#out + 1] = second
	elseif (num(r.grace_remaining) or 0) > 0 then
		out[#out + 1] = "It changed hands lately: no attack can be called against it for " .. WarLines.hoursText(r.grace_remaining, st) .. "."
	elseif WarLines.isFront(r) then
		local attacker = type(r.front) == "table" and r.front.attacker or other(r.faction)
		local af = WarLines.factionOf(st, attacker)
		if af ~= nil and (num(af.reserve) or 0) <= 0 then
			out[#out + 1] = "The " .. (WarLines.ADJ[attacker] or "enemy") .. " line here is out of supply and cannot press."
		else
			out[#out + 1] = "Under attack and holding. Every wiped " .. (WarLines.ADJ[attacker] or "enemy") .. " line costs them crates."
		end
	end
	return out
end

-- ------------------------------------------------ 4.4 what you can do --

--- Section 4.4's ranked actions for one town, with numbers, as lines.
function WarLines.actions(st, regionId)
	local r = st and st.regions and st.regions[regionId]
	if r == nil or not WarLines.isSupply(r) then
		return {}
	end
	local tun = (type(st.tunables) == "table") and st.tunables or {}
	local perBody = num(tun.crates_per_casualty) or 1
	local perLost = num(tun.crates_per_lost_fight) or 3
	local out = {}
	local cph = num(r.crates_per_hour) or 0
	local run = WarLines.courierCrates()
	local buys = WarLines.buysText(run, cph)
	local falls = num(r.falls_in_ticks)
	if r.is_capital then
		out[#out + 1] = "A crate run: +" .. run .. " crates to the reserve."
	else
		out[#out + 1] = "A crate run: +" .. run .. " crates here" .. (buys and (", " .. buys .. " of supply") or "") .. "."
	end
	if WarLines.isFront(r) then
		local attacker = type(r.front) == "table" and r.front.attacker or other(r.faction)
		local cost = round(WarLines.LINE_BODIES * perBody + perLost)
		out[#out + 1] = "A wiped " .. (WarLines.ADJ[attacker] or "enemy") .. " line: -" .. cost .. " crates to them (" .. round(perBody) .. " per body, " .. round(perLost) .. " for the line)."
	end
	if WarLines.roadState(r) == "cut" then
		local capitalId = WarLines.capitalOf(st, r.faction, WarLines.planetOf(regionId))
		out[#out + 1] = "The road" .. (capitalId and (" from " .. WarLines.name(capitalId)) or "") .. " is cut: retake a town on it and the crates flow again."
	end
	if falls ~= nil and falls <= 0 then
		out[#out + 1] = "Dry: one lost fight here loses the town. Hold the line."
	end
	return out
end

-- -------------------------------------------------- 4.5 transitions --

--- Everything worth a galaxy dispatch that is a CHANGE of state rather than
-- an event the exporter already lists (flips and road changes come from
-- war_flips.lua): a siege begun or lifted, an offensive declared, a season
-- won, a new season begun. `last` is the previous snapshot (a table of
-- string -> string, or nil on the first run). Returns lines, snapshot.
-- On the first run (last == nil) nothing is announced: the snapshot is
-- recorded, like WarAnnounce:claim's first-tick rule.
function WarLines.transitions(st, last)
	local lines, snap = {}, {}
	if st == nil or type(st.regions) ~= "table" then
		return lines, snap
	end
	-- The season first: the announcer caps the lines it sends and writes
	-- the snapshot before sending (verifier, 2026-09-06), so the line that
	-- matters most must never be the one past the cap.
	local s = st.season
	if type(s) == "table" then
		local winner = (s.winner ~= nil and s.winner ~= "") and tostring(s.winner) or ""
		local index = tostring(s.index or "")
		snap["winner"] = winner
		snap["season"] = index
		if last ~= nil then
			if (last["winner"] or "") == "" and winner ~= "" then
				lines[#lines + 1] = "A capital has fallen. Season " .. index .. " is the " .. WarLines.side(winner) .. "'s."
					.. ((num(s.intermission_remaining) or 0) > 0 and (" The next season begins in " .. WarLines.hoursText(s.intermission_remaining, st) .. ".") or "")
			elseif (last["season"] or index) ~= index and winner == "" then
				lines[#lines + 1] = "Season " .. index .. " begins. The reserves are full and every road is open."
			end
		end
	end
	local ids = {}
	for id, _ in pairs(st.regions) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local r = st.regions[id]
		if r.is_capital and type(r.siege) == "table" then
			local key = "siege:" .. id
			local now = r.siege.active and "1" or "0"
			snap[key] = now
			if last ~= nil and last[key] ~= nil and last[key] ~= now then
				if now == "1" then
					lines[#lines + 1] = WarLines.name(id) .. " is under siege: the " .. WarLines.side(other(r.faction)) .. " holds every road into it."
				else
					lines[#lines + 1] = "The siege of " .. WarLines.name(id) .. " is lifted: a road into it is open again."
				end
			end
		end
	end
	if type(st.fronts) == "table" then
		for _, fr in ipairs(st.fronts) do
			if fr.region ~= nil then
				local key = "offensive:" .. fr.region
				local now = fr.offensive and "1" or "0"
				snap[key] = now
				if last ~= nil and (last[key] or "0") ~= now and now == "1" then
					local line = WarLines.side(fr.attacker) .. " offensive declared at " .. WarLines.name(fr.region)
					if fr.officer ~= nil and fr.officer ~= "" then
						line = line .. ", led by " .. tostring(fr.officer)
					end
					lines[#lines + 1] = line .. "."
				end
			end
		end
	end
	return lines, snap
end

--- Snapshot <-> string, for shared string data.
function WarLines.packSnapshot(snap)
	local keys = {}
	for k, _ in pairs(snap or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(snap[k]) end
	return table.concat(parts, ";")
end

function WarLines.unpackSnapshot(raw)
	if raw == nil or raw == "" then
		return nil
	end
	local out = {}
	for k, v in string.gmatch(raw, "([^;=]+)=([^;]*)") do
		out[k] = v
	end
	return out
end
