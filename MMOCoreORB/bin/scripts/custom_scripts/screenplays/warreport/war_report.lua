--[[
  custom_scripts/screenplays/warreport/war_report.lua

  The shared formatter behind every player-facing view of the war. The four
  surfaces (login report, capital officer NPC, bartender rumours, flip
  announcements) all render from HERE so they can never disagree with each
  other about who holds what.

  WHY A SHARED MODULE AND NOT FOUR RENDERERS: the failure mode we are
  designing against is a player being told "the Empire holds Bestine" by a
  broadcast and "the Rebellion holds Bestine" by an NPC thirty seconds later,
  because two call sites read the war state at different times or resolve
  faction differently. One formatter, one faction vocabulary, one set of
  display names.

  WHAT IT MAY AND MAY NOT DO (hard constraints, all verified in-repo):
    - Literal strings ONLY. We cannot add .stf string-table entries -- those
      are client TRE assets this project does not ship (see
      population/standing_services.lua's own note on exactly this). So no new
      UI screens and no new button labels anywhere in this feature.
      sendSystemMessage() with a plain (non-"@") String is fine: 188 such
      calls already exist in stock scripts and
      CreatureObjectImplementation.cpp:543 takes a plain String.
    - No C++, no new mobile/ or loot/ templates (those need restart.sh, not
      reload-lua.sh -- see CLAUDE.md's reload table).
    - Reads the SAME hand-off file the spawn bridge reads
      (custom_scripts/war/war_state.lua, produced by
      bridge/generate_war_state.lua). It does not re-derive anything.

  FAIL-SAFE CONTRACT: every entry point returns nil or an empty table when
  the war state is missing or malformed. A player must never see a Lua error
  or a half-rendered sentence because the sim has not run yet. Callers treat
  nil as "say nothing at all".
]]

WarReport = WarReport or {}

-- Display names. Derived from the region id where possible so a new region
-- added to the sim renders sanely without touching this file; the table
-- below only holds the cases where the derivation would read wrong.
WarReport.NAME_OVERRIDES = {
	cor_bela_vistal = "Bela Vistal",
	cor_doaba       = "Doaba Guerfel",
	cor_kor_vella   = "Kor Vella",
	tat_mos_eisley  = "Mos Eisley",
	tat_mos_espa    = "Mos Espa",
	nab_kaadara     = "Kaadara",
}

WarReport.PLANET_OF = {
	cor_bela_vistal = "corellia", cor_coronet = "corellia",
	cor_doaba = "corellia", cor_kor_vella = "corellia",
	cor_tyrena = "corellia",
	nab_kaadara = "naboo", nab_keren = "naboo",
	nab_moenia = "naboo", nab_theed = "naboo",
	tat_anchorhead = "tatooine", tat_bestine = "tatooine",
	tat_mos_eisley = "tatooine", tat_mos_espa = "tatooine",
}

WarReport.PLANET_NAME = {
	corellia = "Corellia", naboo = "Naboo", tatooine = "Tatooine",
}

--- "the Empire" / "the Rebellion". One vocabulary, used everywhere.
-- Deliberately NOT "Imperial"/"Rebel" as bare adjectives -- these strings are
-- dropped into sentences by four different callers and the article matters.
function WarReport.factionName(faction)
	if faction == "rebel" then
		return "the Rebellion"
	elseif faction == "imperial" then
		return "the Empire"
	end
	return "no one"
end

--- Short adjective form, for "Imperial patrols" style phrasing.
function WarReport.factionAdjective(faction)
	if faction == "rebel" then
		return "Rebel"
	elseif faction == "imperial" then
		return "Imperial"
	end
	return "neutral"
end

--- Pretty name for a region id: override table first, else derive by
-- stripping the planet prefix and title-casing the remainder.
function WarReport.regionName(regionId)
	if type(regionId) ~= "string" then
		return "somewhere"
	end

	local override = WarReport.NAME_OVERRIDES[regionId]
	if override ~= nil then
		return override
	end

	local bare = regionId:gsub("^[a-z]+_", "")
	bare = bare:gsub("_", " ")
	-- title-case each word
	bare = bare:gsub("(%a)([%w]*)", function(first, rest)
		return first:upper() .. rest
	end)
	return bare
end

function WarReport.planetName(planetId)
	return WarReport.PLANET_NAME[planetId] or planetId or "unknown space"
end

--- The war state, or nil. Loaded by the spawn bridge already; we reuse the
-- global it populates rather than includeFile()ing a second copy, so the two
-- systems can never be looking at different ticks of the war.
function WarReport.state()
	if WAR_STATE == nil or type(WAR_STATE) ~= "table" then
		return nil
	end
	if WAR_STATE.regions == nil or type(WAR_STATE.regions) ~= "table" then
		return nil
	end
	return WAR_STATE
end

--- Stable, sorted list of region ids. Sorted so every surface lists the war
-- in the same order every time -- an unstable order reads as the war
-- churning when nothing has actually changed.
function WarReport.regionIds()
	local st = WarReport.state()
	if st == nil then
		return {}
	end

	local ids = {}
	for id, _ in pairs(st.regions) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

--- Holdings count per faction: { imperial = n, rebel = n, total = n }
function WarReport.tally()
	local st = WarReport.state()
	if st == nil then
		return nil
	end

	local out = { imperial = 0, rebel = 0, total = 0 }
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		local r = st.regions[ids[i]]
		if r ~= nil and type(r.faction) == "string" then
			if out[r.faction] ~= nil then
				out[r.faction] = out[r.faction] + 1
			end
			out.total = out.total + 1
		end
	end
	return out
end

--- Regions under active contest, most-contested first. `threshold` defaults
-- to 25.0 -- below that the fighting is not worth a player's attention and
-- listing it would bury the real front in noise.
function WarReport.frontRegions(threshold)
	local st = WarReport.state()
	if st == nil then
		return {}
	end
	threshold = threshold or 25.0

	local front = {}
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		local id = ids[i]
		local r = st.regions[id]
		if r ~= nil and type(r.contest) == "number" and r.contest >= threshold then
			front[#front + 1] = { id = id, contest = r.contest, faction = r.faction }
		end
	end

	-- Sort by contest descending; tie-break on id so the order is total and
	-- therefore stable across calls (table.sort is not a stable sort).
	table.sort(front, function(a, b)
		if a.contest == b.contest then
			return a.id < b.id
		end
		return a.contest > b.contest
	end)
	return front
end

--- One-line strategic summary, or nil if the war state is unavailable.
function WarReport.headline()
	local t = WarReport.tally()
	if t == nil or t.total == 0 then
		return nil
	end

	local lead
	if t.imperial > t.rebel then
		lead = "The Empire holds " .. t.imperial .. " of " .. t.total .. " contested settlements."
	elseif t.rebel > t.imperial then
		lead = "The Rebellion holds " .. t.rebel .. " of " .. t.total .. " contested settlements."
	else
		lead = "The war is deadlocked: " .. t.imperial .. " settlements each."
	end
	return lead
end

--- The front, as a player-readable sentence. nil when nothing is contested.
function WarReport.frontLine(maxNamed)
	local front = WarReport.frontRegions()
	if #front == 0 then
		return nil
	end
	maxNamed = maxNamed or 3

	local names = {}
	local n = #front
	if n > maxNamed then n = maxNamed end
	for i = 1, n do
		names[#names + 1] = WarReport.regionName(front[i].id)
	end

	local list = table.concat(names, ", ")
	if #front > maxNamed then
		list = list .. " and " .. (#front - maxNamed) .. " more"
	end

	if #front == 1 then
		return "Fighting is heaviest at " .. list .. "."
	end
	return "Fighting is heaviest at " .. list .. "."
end

--- Per-region detail line, e.g.
--   "Mos Eisley -- held by the Rebellion, under heavy attack, supply cut."
function WarReport.regionLine(regionId)
	local st = WarReport.state()
	if st == nil then
		return nil
	end
	local r = st.regions[regionId]
	if r == nil then
		return nil
	end

	local line = WarReport.regionName(regionId) .. " -- held by " .. WarReport.factionName(r.faction)

	local contest = tonumber(r.contest) or 0
	if contest >= 75.0 then
		line = line .. ", under heavy attack"
	elseif contest >= 25.0 then
		line = line .. ", contested"
	else
		line = line .. ", quiet"
	end

	if r.supply_status == "cut" then
		line = line .. ", supply cut"
	end

	return line .. "."
end

--- Every region on one planet, sorted. Used by the login report (which only
-- reports the planet you actually landed on -- a galaxy-wide dump on every
-- login is the "loading screen" failure mode).
function WarReport.planetLines(planetId)
	local st = WarReport.state()
	if st == nil or planetId == nil then
		return {}
	end

	local out = {}
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		local id = ids[i]
		if WarReport.PLANET_OF[id] == planetId then
			local line = WarReport.regionLine(id)
			if line ~= nil then
				out[#out + 1] = line
			end
		end
	end
	return out
end

--- Is this region on the front? Used by the waypoint layer to decide what is
-- worth marking on a player's map.
function WarReport.isFront(regionId, threshold)
	local st = WarReport.state()
	if st == nil then
		return false
	end
	local r = st.regions[regionId]
	if r == nil or type(r.contest) ~= "number" then
		return false
	end
	return r.contest >= (threshold or 25.0)
end

--- World coordinates for each region's town centre, {x, y}.
--
-- Taken from the game's OWN authoritative region tables
-- (managers/planet/<planet>_regions.lua, the CITY entries), NOT from the
-- city screenplays' mobile spawn rows: most of those rows are cell-relative
-- coordinates for NPCs standing inside buildings (x=60, y=0.6 and friends),
-- which would have put every waypoint at the origin. Verified against
-- tatooine_regions.lua:177-183, corellia_regions.lua and naboo_regions.lua.
WarReport.COORDS = {
	tat_anchorhead  = {   102, -5360 },
	tat_bestine     = { -1218, -3688 },
	tat_mos_eisley  = {  3460, -4768 },
	tat_mos_espa    = { -2940,  2190 },

	cor_bela_vistal = {  6788, -5654 },
	cor_coronet     = {  -178, -4504 },
	cor_tyrena      = { -5282, -2526 },
	cor_kor_vella   = { -3512,  3184 },
	cor_doaba       = {  3272,  5456 },

	nab_kaadara     = {  5168,  6704 },
	nab_keren       = {   336,  2140 },
	nab_moenia      = {  4800, -4784 },
	nab_theed       = { -6160,  3920 },
}
