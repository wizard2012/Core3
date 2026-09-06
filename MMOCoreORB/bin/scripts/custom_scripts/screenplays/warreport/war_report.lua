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

  SLICE 3 (DESIGN-WAR-V2 section 4, 2026-09-06): the LINE SHAPES moved to
  war_lines.lua (WarLines), which is pure and tested headlessly
  (bridge/tests/t_readouts.lua). This file keeps the state accessor, the
  names, the geometry, and the entry points older callers use -- headline()
  is now the days-of-reserve line, regionLine() the section-4.3 town line --
  so no caller had to change to start speaking crates.
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

-- Contest floor and battle staging both live at 1.0 now (see
-- warreport/war_battle.lua:71) so the surfaces and the battle system can
-- never disagree about whether a front exists. With that floor a lot more
-- regions qualify than under the old absolute 25.0 gate, so the noise
-- control moves from the threshold to a rank cap instead: only the top
-- MAX_FRONT_REGIONS contested regions are ever surfaced to a player.
WarReport.MAX_FRONT_REGIONS = 3

WarReport.PLANET_OF = {
	cor_bela_vistal = "corellia", cor_coronet = "corellia",
	cor_doaba = "corellia", cor_kor_vella = "corellia",
	cor_tyrena = "corellia",
	nab_kaadara = "naboo", nab_keren = "naboo",
	nab_moenia = "naboo", nab_theed = "naboo",
	nab_lianorm = "naboo", -- the Rebel outpost in the Lianorm Swamp: ground given 2026-09-06 (B33)
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
	-- "the Alliance", not "the Rebellion": section 4's vocabulary (2026-09-06).
	if faction == "rebel" then
		return "the Alliance"
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
	-- Core3 gives every server thread its own Lua VM, and WAR_STATE is only
	-- populated in a thread that has actually included war_hook.lua (which
	-- calls WarBridge.load() at include time). A reader running on any other
	-- thread sees nil.
	--
	-- That is not hypothetical: it is why the Anchorhead briefing officer
	-- spawned nowhere while the spawn bridge itself worked perfectly. The
	-- officer read the state from a thread that had none, got nil, and
	-- silently declined to spawn.
	--
	-- So reload on demand rather than assuming someone else did it. Cheap
	-- (two includeFile calls of small generated files), idempotent, and it
	-- makes every surface independent of thread and load order.
	if (WAR_STATE == nil or type(WAR_STATE) ~= "table") and WarBridge ~= nil and WarBridge.load ~= nil then
		pcall(function() WarBridge.load() end)
	end

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

--- Regions under active contest, most-contested first, capped to the top
-- WarReport.MAX_FRONT_REGIONS. `threshold` defaults to 1.0 -- the same
-- floor at which war_battle.lua stages a fight, so a region can never be a
-- live battle while this list calls it quiet. Noise is controlled by the
-- rank cap below, not by raising the threshold.
function WarReport.frontRegions(threshold)
	local st = WarReport.state()
	if st == nil then
		return {}
	end
	threshold = threshold or 1.0

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

	-- Rank, don't gate: cap the list rather than raising the threshold back
	-- up, so the exact same region can never be "in battle" and "not a
	-- front" at once.
	while #front > WarReport.MAX_FRONT_REGIONS do
		table.remove(front)
	end

	return front
end

--- One-line strategic summary, or nil if the war state is unavailable.
-- Slice 3: "Empire: 19 days of supply. Alliance: 11 days." -- who is
-- winning, from the reserves; the old holdings count only for an export
-- without a factions block.
function WarReport.headline()
	local st = WarReport.state()
	if st ~= nil and type(st.factions) == "table" and WarLines ~= nil and WarLines.reserveLine ~= nil then
		local line = WarLines.reserveLine(st)
		if line ~= nil then
			return line
		end
	end
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
	-- Slice 3: section 4.3's town line (war_lines.lua handles schema 3 too).
	if WarLines ~= nil and WarLines.townLine ~= nil then
		return WarLines.townLine(st, regionId)
	end

	local line = WarReport.regionName(regionId) .. " -- held by " .. WarReport.factionName(r.faction)

	local contest = tonumber(r.contest) or 0
	if contest >= 75.0 then
		line = line .. ", under heavy attack"
	elseif contest >= 25.0 then
		line = line .. ", contested"
	elseif contest >= 1.0 then
		line = line .. ", skirmishing"
	else
		line = line .. ", quiet"
	end

	-- Three real supply_status values exist in the live war state today
	-- (connected, degraded, cut -- confirmed against the deployed
	-- custom_scripts/war/war_state.lua). "connected" was, and remains,
	-- silent -- a healthy region needs no extra words. "degraded" used to
	-- fall through to nothing at all, reading identically to a healthy
	-- region; it now gets its own word so a player can tell the two apart.
	if r.supply_status == "cut" then
		line = line .. ", supply cut"
	elseif r.supply_status == "degraded" then
		line = line .. ", supply strained"
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
		local planetOfId = (WarLines ~= nil and WarLines.planetOf ~= nil) and WarLines.planetOf(id) or WarReport.PLANET_OF[id]
		if planetOfId == planetId then
			local line = WarReport.regionLine(id)
			if line ~= nil then
				out[#out + 1] = line
			end
		end
	end
	return out
end

--- Gap 2's galaxy-wide-but-front-scoped supply overview: every region
-- currently on WarReport.frontRegions() (the same front-line list the
-- login report and the waypoint layer already use), grouped so cut/
-- strained regions are easy to spot rather than buried in a wall of
-- "connected" lines.
--
-- SCOPED TO FRONTS, NOT EVERY REGION: this file's own header rule is that
-- "a galaxy-wide dump every login is the loading screen failure mode this
-- design was warned about" -- an ALL-regions dump on demand would still be
-- exactly that shape of wall of text, just moved from login to a menu
-- click. It is also not very actionable: a quiet, uncontested region's
-- supply status doesn't help a player decide where to go. Fronts are where
-- the war is actually being fought and where a delivery run matters, so
-- that is what this reports -- the same scoping decision war_login.lua's
-- own waypoint logic already made for the same reason.
--
-- DELIVERED ONLY ON DEMAND (the officer's Report radial, war_officer_report
-- .lua) -- never called from the login report. Returns a list of plain
-- strings ready for sendSystemMessage(), one call per line; never nil, even
-- when there is nothing to report.
function WarReport.supplyOverview()
	local st = WarReport.state()
	local front = WarReport.frontRegions()
	if st == nil or #front == 0 then
		return { "No active fronts to report supply on right now." }
	end

	local cut, strained, ok = {}, {}, {}
	for i = 1, #front do
		local id = front[i].id
		local r = st.regions[id]
		local name = WarReport.regionName(id) .. " (" .. WarReport.factionAdjective(front[i].faction) .. ")"

		if r ~= nil and r.supply_status == "cut" then
			cut[#cut + 1] = name
		elseif r ~= nil and r.supply_status == "degraded" then
			strained[#strained + 1] = name
		else
			ok[#ok + 1] = name
		end
	end

	local lines = { "Supply overview, active fronts:" }
	if #cut > 0 then
		lines[#lines + 1] = "  Cut off: " .. table.concat(cut, ", ")
	end
	if #strained > 0 then
		lines[#lines + 1] = "  Strained: " .. table.concat(strained, ", ")
	end
	if #ok > 0 then
		lines[#lines + 1] = "  Connected: " .. table.concat(ok, ", ")
	end
	return lines
end

--- Is this region on the front? Used by the waypoint layer to decide what is
-- worth marking on a player's map. `threshold` defaults to 1.0, matching
-- frontRegions() and war_battle.lua's staging floor -- there is no caller
-- (checked repo-wide) that wants a stricter notion of "contested" here.
function WarReport.isFront(regionId, threshold)
	local st = WarReport.state()
	if st == nil then
		return false
	end
	local r = st.regions[regionId]
	if r == nil or type(r.contest) ~= "number" then
		return false
	end
	return r.contest >= (threshold or 1.0)
end

--- World coordinates for each region's town centre, {x, y}.
--
-- Taken from the game's OWN authoritative region tables
-- (managers/planet/<planet>_regions.lua, the CITY entries), NOT from the
-- city screenplays' mobile spawn rows: most of those rows are cell-relative
-- coordinates for NPCs standing inside buildings (x=60, y=0.6 and friends),
-- which would have put every waypoint at the origin. Verified against
-- tatooine_regions.lua:177-183, corellia_regions.lua and naboo_regions.lua.
-- NB: a region row is {name, x1, y1, {CIRCLE, radius}} OR
-- {name, x1, y1, {RECTANGLE, x2, y2}}. For a CIRCLE, (x1,y1) IS the centre.
-- For a RECTANGLE it is a BOUNDING BOX CORNER, and the centre is the midpoint.
-- nab_keren and nab_theed are the only two RECTANGLE regions here, and both
-- were originally taken as (x1,y1) -- putting their waypoints 1225 m and 952 m
-- off, in the officer spawn, the login report and the recruiter briefing.
-- Verified against managers/planet/<planet>_regions.lua by scripted audit.
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
	nab_keren       = {  1424,  2702 },
	nab_moenia      = {  4800, -4784 },
	nab_theed       = { -5320,  4368 },
	-- The Lianorm Swamp has no city; the sim's Rebel capital on Naboo stands
	-- at the named region's centre (naboo_regions.lua:75, lianorm_swamp_1),
	-- solid ground at z 18.8 (measured 2026-09-06; the swamp water lies
	-- lower). navmesh/lianorm_outpost_navmesh.lua gives it a mesh.
	nab_lianorm     = {  -416,     0 },
}

--- KILL_BOUNDS -- the containment shape for each COORDS town centre, used
-- by regionAt() below to turn a world position into a war region id for
-- combat-contribution attribution (backlog: wire game combat into
-- war_contrib). Sourced from the SAME authoritative game region tables
-- COORDS's own header says it was taken from
-- (managers/planet/<planet>_regions.lua CITY rows) -- this is the radius
-- half of the row COORDS already took the centre from, not a new mapping.
-- Every CITY row on tatooine/corellia/naboo is {CIRCLE, radius} except
-- nab_keren and nab_theed, which are {RECTANGLE, x2, y2} (bounding-box
-- corner opposite {x1,y1}) -- COORDS already notes this and stores the
-- midpoint; KILL_BOUNDS stores the same rectangle's corners instead of a
-- radius for those two, verified against naboo_regions.lua:94,96.
WarReport.KILL_BOUNDS = {
	tat_anchorhead  = { kind = "circle", radius = 125 },
	tat_bestine     = { kind = "circle", radius = 336 },
	tat_mos_eisley  = { kind = "circle", radius = 456 },
	tat_mos_espa    = { kind = "circle", radius = 533 },

	cor_bela_vistal = { kind = "circle", radius = 480 },
	cor_coronet     = { kind = "circle", radius = 581 },
	cor_tyrena      = { kind = "circle", radius = 622 },
	cor_kor_vella   = { kind = "circle", radius = 758 },
	cor_doaba       = { kind = "circle", radius = 632 },

	nab_kaadara     = { kind = "circle", radius = 320 },
	nab_moenia      = { kind = "circle", radius = 336 },
	nab_lianorm     = { kind = "circle", radius = 300 },
	-- naboo_regions.lua:94 -- {336, 2140, {RECTANGLE, 2512, 3264}}
	nab_keren       = { kind = "rect", x1 = 336,   y1 = 2140, x2 = 2512, y2 = 3264 },
	-- naboo_regions.lua:96 -- {-6160, 3920, {RECTANGLE, -4480, 4816}}
	nab_theed       = { kind = "rect", x1 = -6160, y1 = 3920, x2 = -4480, y2 = 4816 },
}

--- Resolve a world position to a war region id, or nil if it falls outside
-- every mapped town's kill-attribution bounds (open field, a different
-- planet, or a region with no Core3 city screenplay -- bridge/region_map.lua
-- already leaves those `false`, so KILL_BOUNDS simply has no entry for
-- them). Deliberately returns nil rather than picking a "nearest" region:
-- the caller (war_contrib_hook.lua) records nothing on nil, per this
-- project's rule that a guess is worse than no data.
--
-- Pure geometry -- does not require WAR_STATE to be loaded, so a combat kill
-- can still be correctly rejected/accepted even on a thread where the war
-- state failed to parse (WarContrib.record's own faction/region validation
-- is the only other gate a caller needs).
function WarReport.regionAt(zoneName, x, y)
	if type(zoneName) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end

	for id, shape in pairs(WarReport.KILL_BOUNDS) do
		if WarReport.PLANET_OF[id] == zoneName then
			if shape.kind == "circle" then
				local c = WarReport.COORDS[id]
				if c ~= nil then
					local dx, dy = x - c[1], y - c[2]
					if (dx * dx + dy * dy) <= (shape.radius * shape.radius) then
						return id
					end
				end
			elseif shape.kind == "rect" then
				local xlo, xhi = math.min(shape.x1, shape.x2), math.max(shape.x1, shape.x2)
				local ylo, yhi = math.min(shape.y1, shape.y2), math.max(shape.y1, shape.y2)
				if x >= xlo and x <= xhi and y >= ylo and y <= yhi then
					return id
				end
			end
		end
	end

	return nil
end
