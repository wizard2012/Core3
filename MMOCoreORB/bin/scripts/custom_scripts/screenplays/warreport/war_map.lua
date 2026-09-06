--[[
  custom_scripts/screenplays/warreport/war_map.lua

  Surface 5: the live map overlay. Every war city on the player's CURRENT
  planet gets a session waypoint, colour-coded by controlling faction, with
  a one-line label carrying name / faction / how contested / supply. Refreshed
  on login and every WarMap.REFRESH_INTERVAL_MS thereafter, so a player can
  glance at the map at any time and see the whole picture -- not just the
  fronts -- without opening a menu (owner's request, verbatim in the ticket:
  "Id prefer it to be on the map if possible").

  WHY EVERY CITY, NOT JUST FRONTS: war_login.lua's markFront() (now folded
  into this file -- see the note at the bottom) only ever marked contested
  regions. That answers "where is the fighting" but not "who owns what and
  how supplied are they", which is exactly what the owner asked for. Fronts
  still stand out here too: see HEAVY_CONTEST_THRESHOLD below.

  WHY CHANGE-DETECTION MATTERS: the sim only ticks hourly (CLAUDE.md decision
  table), but the owner asked for a 10-minute refresh. Most 10-minute ticks
  will find identical data. Re-issuing 13 waypoints with notifyClient=true
  on a cadence the player can't act on would flicker their map for nothing.
  So every refresh computes a cheap string signature of what it WOULD draw
  for the player's current planet and only touches the client
  (removeWaypointBySpecialType + addWaypoint) when that signature differs
  from the last one drawn for this player. A planet change always produces
  a different signature (different region set), so that case is handled for
  free by the same mechanism -- no separate "did they zone" hook needed.

  THE SIGNATURE CACHE IS THREAD-LOCAL, NOT PLAYER-LOCAL. Core3 gives every
  server thread its own Lua VM (WarReport.state()'s own header explains
  this), and createEvent's self-reschedule is not guaranteed to land back on
  the same thread every time. WarMap._lastSignature therefore only holds
  "what did THIS thread last believe it drew for this player" -- it is a
  strictly best-effort de-dupe. Worst case, a scheduling thread hop makes
  the cache miss once and this fires one redundant identical update. That is
  a wasted notifyClient roundtrip, not a correctness bug: clear-then-redraw
  is idempotent, and specialTypeID confines it to this overlay's own pins.

  WHY specialTypeID = 9001: repo-wide search of every addWaypoint call site
  (69 of them) plus WaypointObject.idl's SPECIALTYPE_* enum (values 1-11,
  covering FIND/FINDFRIEND/.../QUESTTASK) turned up nothing at or near 9001.
  The overwhelming majority of calls pass literal 0 (no special type) or a
  quest's CRC (large, quest-specific hashes, e.g. EnoughQuest.REBEL_CRC) --
  none of those collide with a small fixed literal either. Getting this
  wrong would call removeWaypointBySpecialType on some OTHER system's
  waypoints (or a player's own quest markers) and silently delete them --
  unacceptable and unrecoverable, per the ticket -- so this value is
  reserved here, permanently, for this overlay only. Do not reuse it.

  LABEL FORMAT (plain text, no .stf -- see war_report.lua's own header on
  why that is fine here):
    "<City> (<Faction>) <ContestTier> | Supply: <status> ~<stock>"
  e.g. "Doaba Guerfel (Rebel) Skirmish | Supply: degraded ~50"
       "Bela Vistal (Imperial) Quiet | Supply: OK"            (no materiel)

  WHY BOTH supply_status AND raw supply_stock, not just one: the owner asked
  explicitly "how much supply that region has", which supply_status alone
  (a three-word qualitative bucket) does not answer -- but supply_stock
  ALONE is meaningless without the status, because it is an unbounded
  accumulating stockpile (bridge/war_state_writer.lua's own header: "a
  materiel stockpile that accumulates via production and drains under
  active fronts"), not a 0-100 percentage. A raw number with no status word
  tells a player "47" and nothing about whether that is fine or an
  emergency. Showing both costs a handful of characters and answers the
  question actually asked. supply_stock is OPTIONAL in the schema (absent
  entirely when materiel is disabled) -- when absent, the "~<stock>" clause
  is simply dropped, never rendered as ~0 or ~nil.

  COLOUR MAPPING (WaypointObject.idl COLOR_* enum, confirmed against
  DirectorManager.cpp's setGlobalInt calls -- see this file's header
  research): no faction/waypoint colour convention exists anywhere else in
  this codebase (repo-wide grep came up empty), so this is a fresh,
  deliberate choice, not a discovered one:
    - imperial            -> WAYPOINT_BLUE   (1)
    - rebel               -> WAYPOINT_ORANGE (3)
    - heavily contested    -> WAYPOINT_PURPLE (5), OVERRIDES the faction
      colour above once contest >= HEAVY_CONTEST_THRESHOLD -- a region on
      fire is more urgent than who currently holds it, so it gets its own
      colour rather than just a label a player has to stop and read.
    - unrecognised/neutral -> WAYPOINT_WHITE  (0)
  Deliberately NOT WAYPOINT_YELLOW: that colour is already the de facto
  "quest available" colour across ~30 stock quest call sites in this repo
  (WAYPOINTQUESTTASK pins). Reusing it here would make a war-map pin look
  like a quest marker at a glance -- exactly the legibility problem this
  feature exists to avoid.

  FOLDING war_login.lua's markFront() INTO THIS FILE: markFront placed its
  own waypoints (specialTypeID = 0, colour 2, front-only, label
  "<City> (<Faction>)") for the same cities this file now covers with a
  strict superset (every city, not just fronts) and a richer label. Two
  systems drawing overlapping pins for the same locations, on the same
  trigger, with different colours/specialTypeIDs/labels would double up on
  a player's map and actively contradict each other (e.g. a quiet-green pin
  from one system next to a contested-purple pin from this one for the
  SAME city). So markFront and its two now-dead fields (waypointColor,
  frontThreshold) were REMOVED from war_login.lua, and its single call site
  now calls WarMap:refresh(pPlayer) instead -- see that file's own diff.
  Nothing else in war_login.lua changed: the delayed text report, the
  install()/monkey-patch machinery, and the pcall safety net around
  playerLoggedIn are all untouched.

  HARD CONSTRAINTS HONOURED HERE (per ticket):
    - Every player-facing call is inside a pcall; a failure here can never
      block or interrupt a player's login, session, or logout.
    - Missing/malformed WarReport, WAR_STATE, or supply_stock degrades
      silently to "draw nothing" or "draw without the supply clause" --
      never an error, never a per-player log spam (log lines here are
      startup-time only: PlayerTriggers not being a table).
    - persistence = 0 on every pin (session-only, never saved to the
      player's datapad).
    - The per-player refresh chain is cancelled on logout (see install()
      below) so it cannot leak once a player disconnects.
]]

WarMap = ScreenPlay:new {
	screenplayName = "WarMap",

	-- Reserved specialTypeID for every waypoint this overlay places. See
	-- this file's header for the collision search that justifies the value.
	SPECIAL_TYPE_ID = 9001,

	-- Owner's explicit ask: "it would need to be updated after say 10 min".
	REFRESH_INTERVAL_MS = 10 * 60 * 1000,

	-- Contest at/above which a region's pin turns WAYPOINT_PURPLE regardless
	-- of holder. Matches WarReport.regionLine's own "under heavy attack"
	-- tier (warreport/war_report.lua) so this overlay's idea of "heavy" can
	-- never disagree with the text report's.
	HEAVY_CONTEST_THRESHOLD = 75.0,
	CONTESTED_THRESHOLD = 25.0,
	SKIRMISH_THRESHOLD = 1.0,
}

registerScreenPlay("WarMap", true)

-- Last signature drawn per player, keyed by object ID. Thread-local cache;
-- see this file's header for why that is an acceptable best-effort de-dupe
-- rather than a correctness requirement.
WarMap._lastSignature = WarMap._lastSignature or {}

function WarMap:start()
	-- Nothing to schedule globally; every refresh is per-player, kicked off
	-- by war_login.lua's login flow and self-rescheduling from there.
end

--- Short contest-tier word, one glance, matches WarReport.regionLine's own
-- threshold ladder (1.0 / 25.0 / 75.0) so the two surfaces never disagree
-- about whether a region counts as quiet/skirmishing/contested/heavy.
function WarMap:contestTier(contest)
	contest = tonumber(contest) or 0
	if contest >= WarMap.HEAVY_CONTEST_THRESHOLD then
		return "HEAVY"
	elseif contest >= WarMap.CONTESTED_THRESHOLD then
		return "Contested"
	elseif contest >= WarMap.SKIRMISH_THRESHOLD then
		return "Skirmish"
	end
	return "Quiet"
end

--- Waypoint colour for one region row (a table with .faction and .contest,
-- as found in WAR_STATE.regions[id]). See this file's header for the
-- mapping and its rationale.
function WarMap:colorFor(region)
	if region == nil then
		return WAYPOINT_WHITE
	end

	local contest = tonumber(region.contest) or 0
	if contest >= WarMap.HEAVY_CONTEST_THRESHOLD then
		return WAYPOINT_PURPLE
	end

	if region.faction == "imperial" then
		return WAYPOINT_BLUE
	elseif region.faction == "rebel" then
		return WAYPOINT_ORANGE
	end
	return WAYPOINT_WHITE
end

--- Short supply clause, or "" when there is nothing safe to say (missing
-- supply_status entirely -- an older schema_version). "connected" reads as
-- "OK" (a healthy region needs no alarming word); "degraded"/"cut" are
-- shown verbatim since those ARE the alarming words. The raw stockpile
-- number is appended only when supply_stock carries an entry for the
-- HOLDING faction (see this file's header on why the key is optional and
-- per-faction).
function WarMap:supplyClause(region)
	if region == nil or type(region.supply_status) ~= "string" then
		return ""
	end

	local statusWord
	if region.supply_status == "connected" then
		statusWord = "OK"
	elseif region.supply_status == "degraded" then
		statusWord = "degraded"
	elseif region.supply_status == "cut" then
		statusWord = "CUT"
	else
		return "" -- unrecognised value; say nothing rather than guess
	end

	local clause = " | Supply: " .. statusWord

	if type(region.supply_stock) == "table" and type(region.faction) == "string" then
		local stock = region.supply_stock[region.faction]
		if type(stock) == "number" then
			clause = clause .. " ~" .. tostring(math.floor(stock + 0.5))
		end
	end

	return clause
end

--- Full plain-text label for one region, e.g.
--   "Doaba Guerfel (Rebel) Skirmish | Supply: degraded ~50"
function WarMap:labelFor(regionId, region)
	-- Slice 3: section 4.1's line, identical to the planetary map pin's
	-- (war_map_pins.lua), so radar and map never disagree.
	if WarLines ~= nil and WarLines.pin ~= nil and WarLines.isSupply ~= nil and WarLines.isSupply(region) then
		return WarLines.pin(WarReport.state(), regionId)
	end
	local name = WarReport.regionName(regionId)
	local adjective = WarReport.factionAdjective(region.faction)
	local tier = WarMap:contestTier(region.contest)
	return name .. " (" .. adjective .. ") " .. tier .. WarMap:supplyClause(region)
end

--- Cheap signature of everything that WOULD be drawn for one planet, so
-- refresh() can skip the client-visible update when nothing changed.
-- Sorted region id order (WarReport.regionIds() is already sorted) keeps
-- the signature stable across calls for identical data.
function WarMap:signatureFor(planetName)
	local st = WarReport.state()
	if st == nil then
		return "no-state"
	end

	local parts = {}
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		local id = ids[i]
		if WarReport.PLANET_OF[id] == planetName then
			local r = st.regions[id]
			if r ~= nil then
				parts[#parts + 1] = WarMap:labelFor(id, r)
			end
		end
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

--- Draw (or skip, if unchanged) the overlay for one player on their current
-- planet, then reschedule itself REFRESH_INTERVAL_MS from now. This is the
-- single entry point: war_login.lua's delayed login handler calls it once,
-- and every subsequent call is this function calling itself.
function WarMap:refresh(pPlayer)
	if pPlayer == nil then
		return
	end

	local ok, err = pcall(function()
		WarMap:doRefresh(pPlayer)
	end)
	if not ok then
		printf("WarMap: refresh failed: " .. tostring(err) .. "\n")
	end

	-- Reschedule regardless of success above -- a transient failure (state
	-- not loaded yet on this thread, e.g.) should not permanently stop this
	-- player's overlay from ever updating again. Only stops for real when
	-- playerLoggedOut cancels it (see install() below), or the player
	-- object is no longer resolvable (checked inside doRefresh).
	pcall(function()
		createEvent(WarMap.REFRESH_INTERVAL_MS, "WarMap", "refresh", pPlayer, "")
	end)
end

--- The actual work, split out of refresh() so the reschedule above always
-- runs even if this throws.
function WarMap:doRefresh(pPlayer)
	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return -- player object gone (logged out between schedule and fire)
	end

	if WarReport == nil or WarReport.state() == nil or WarReport.COORDS == nil then
		return -- sim not loaded on this thread yet; try again next cycle
	end

	local objectId = SceneObject(pPlayer):getObjectID()
	local zoneName = SceneObject(pPlayer):getZoneName()
	if zoneName == nil then
		return
	end

	local signature = WarMap:signatureFor(zoneName)
	if WarMap._lastSignature[objectId] == signature then
		return -- nothing to draw differently since last time; skip the client update
	end

	local st = WarReport.state()
	local ids = WarReport.regionIds()

	-- Clear this overlay's own pins ONLY (specialTypeID-scoped, see header)
	-- before redrawing, so cities that changed planet visibility, dropped
	-- out of the current planet's set, or simply moved never leave a stale
	-- duplicate behind.
	PlayerObject(pGhost):removeWaypointBySpecialType(WarMap.SPECIAL_TYPE_ID)

	for i = 1, #ids do
		local id = ids[i]
		if WarReport.PLANET_OF[id] == zoneName then
			local region = st.regions[id]
			local coords = WarReport.COORDS[id]

			if region ~= nil and coords ~= nil then
				local label = WarMap:labelFor(id, region)
				local color = WarMap:colorFor(region)

				PlayerObject(pGhost):addWaypoint(
					zoneName,               -- planet
					label,                  -- name (literal text)
					"",                     -- desc
					coords[1],              -- x
					0,                      -- z
					coords[2],              -- y
					color,
					true,                   -- active
					true,                   -- notifyClient
					WarMap.SPECIAL_TYPE_ID,
					0                       -- persistence: session-only
				)
			end
		end
	end

	WarMap._lastSignature[objectId] = signature
end

--- Drop the signature cache entry and stop this player's refresh chain.
-- Wrapped the same idempotent-across-reload way war_login.lua wraps
-- playerLoggedIn (see that file's header for the field-on-the-table
-- rationale) -- PlayerTriggers is replaced wholesale on every reload, so
-- the guard field must live on the fresh table, not a free global.
function WarMap:install()
	if PlayerTriggers == nil or type(PlayerTriggers) ~= "table" then
		printf("WarMap: PlayerTriggers is not a table -- logout cleanup disabled, refresh chain will rely on stale-object checks only.\n")
		return
	end

	if PlayerTriggers._warMapOriginalLoggedOut ~= nil then
		return -- already wrapped in this VM incarnation
	end

	PlayerTriggers._warMapOriginalLoggedOut = PlayerTriggers.playerLoggedOut

	PlayerTriggers.playerLoggedOut = function(triggersSelf, pPlayer)
		local okOrig = pcall(function()
			if PlayerTriggers._warMapOriginalLoggedOut ~= nil then
				PlayerTriggers._warMapOriginalLoggedOut(triggersSelf, pPlayer)
			end
		end)
		if not okOrig then
			printf("WarMap: original playerLoggedOut raised; logout cleanup continues.\n")
		end

		if pPlayer == nil then
			return
		end

		pcall(function()
			cancelEvent("WarMap", "refresh", pPlayer)
		end)
		pcall(function()
			WarMap._lastSignature[SceneObject(pPlayer):getObjectID()] = nil
		end)
	end
end

WarMap:install()
