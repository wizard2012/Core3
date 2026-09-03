--[[
  custom_scripts/screenplays/warreport/war_login.lua

  Surface 1 of 4: the war report a player gets on login, plus the front-line
  waypoints that put the war on their map.

  WHY A MONKEY-PATCH AND NOT AN EDIT TO playerTriggers.lua: same reasoning as
  bridge/war_hook.lua and population/bartender_rumor.lua -- playerTriggers.lua
  is tracked inside the pinned Core3 submodule, and editing it would dirty a
  checkout this project keeps clean by contract (see CLAUDE.md "Out of
  bounds" and render-config.sh's header). PlayerTriggers is a plain global
  table defined at screenplays/playerTriggers.lua:1, and custom_scripts loads
  after it, so we can wrap the method from here instead.

  RE-CAPTURE ON RELOAD: playerTriggers.lua does `PlayerTriggers = { }` at the
  top, so every reload-lua.sh produces a BRAND NEW table. The original is
  therefore stashed as a FIELD ON THAT TABLE (_warReportOriginalLoggedIn),
  not in a free-standing global -- the field is naturally nil again after a
  reload and we re-wrap the fresh vanilla function, instead of holding a
  stale closure over a dead one. This is the same trick
  population/bartender_rumor.lua documents for BartenderConversationHandler.

  WHY THE REPORT IS DELAYED: sending at the instant playerLoggedIn fires
  lands the message while the client is still zoning, where it is either
  dropped or scrolls past behind the loading screen. The report is scheduled
  onto a short timer instead so it arrives once the player is actually
  looking at the world.

  WHY WAYPOINTS ARE SESSION-ONLY (persistence = 0): a persistent waypoint per
  front region per login would grow the player's datapad without bound and
  leave stale markers pointing at fronts that have since gone quiet. Passing
  persistence = 0 to addWaypoint (LuaPlayerObject.cpp:188 documents the
  11-argument form) means the markers live for the session and are re-derived
  from current war state on the next login -- so they are always accurate and
  never accumulate.
]]

WarReportLogin = ScreenPlay:new {
	screenplayName = "WarReportLogin",

	-- Delay before the report is sent, ms. Long enough for the client to
	-- finish zoning; short enough that it still reads as "here is where the
	-- war stands" rather than arriving out of nowhere mid-play.
	reportDelayMs = 12000,

	-- Contest at or above which a region is worth a map marker. Matches
	-- WarReport.frontRegions' own default (1.0, the same floor
	-- war_battle.lua stages a fight at) so the text report, the waypoints,
	-- and the battle system can never disagree about what counts as "the
	-- front". Noise is controlled by WarReport.MAX_FRONT_REGIONS, not by
	-- raising this back up.
	frontThreshold = 1.0,

	-- Waypoint colour. 2 is the standard blue used by
	-- screenplays that mark objectives; see addWaypoint's `color` arg.
	waypointColor = 2,
}

registerScreenPlay("WarReportLogin", true)

function WarReportLogin:start()
	-- Nothing to schedule globally; this screenplay exists only as a
	-- dispatch target for the delayed per-player event below.
end

--- Wrap PlayerTriggers:playerLoggedIn. Idempotent across reloads by the
-- field-on-the-table mechanism described in this file's header.
function WarReportLogin:install()
	if PlayerTriggers == nil or type(PlayerTriggers) ~= "table" then
		printf("WarReportLogin: PlayerTriggers is not a table -- login war report disabled, stock login behaviour unchanged.\n")
		return
	end

	if PlayerTriggers._warReportOriginalLoggedIn ~= nil then
		return -- already wrapped in this VM incarnation
	end

	PlayerTriggers._warReportOriginalLoggedIn = PlayerTriggers.playerLoggedIn

	PlayerTriggers.playerLoggedIn = function(triggersSelf, pPlayer)
		-- Vanilla behaviour FIRST and unconditionally: ServerEventAutomation
		-- and BestineElection must run even if everything below explodes.
		local okOrig = pcall(function()
			if PlayerTriggers._warReportOriginalLoggedIn ~= nil then
				PlayerTriggers._warReportOriginalLoggedIn(triggersSelf, pPlayer)
			end
		end)
		if not okOrig then
			printf("WarReportLogin: original playerLoggedIn raised; war report continues.\n")
		end

		if pPlayer == nil then
			return
		end

		pcall(function()
			createEvent(WarReportLogin.reportDelayMs, "WarReportLogin", "sendReport", pPlayer, "")
		end)
	end
end

--- Deliver the report. Called off the delayed event, so a failure here can
-- never block login itself.
function WarReportLogin:sendReport(pPlayer)
	if pPlayer == nil then
		return
	end

	local ok, err = pcall(function()
		if WarReport == nil or WarReport.state() == nil then
			return -- sim has not produced a state yet; say nothing at all
		end

		local creature = CreatureObject(pPlayer)

		local headline = WarReport.headline()
		if headline == nil then
			return
		end

		creature:sendSystemMessage("=== Galactic Civil War ===")
		creature:sendSystemMessage(headline)

		local front = WarReport.frontLine()
		if front ~= nil then
			creature:sendSystemMessage(front)
		end

		-- Only the planet the player is actually standing on. A galaxy-wide
		-- dump every login is the "loading screen" failure this design was
		-- explicitly warned about.
		local zoneName = SceneObject(pPlayer):getZoneName()
		local lines = WarReport.planetLines(zoneName)
		if #lines > 0 then
			creature:sendSystemMessage("On " .. WarReport.planetName(zoneName) .. ":")
			for i = 1, #lines do
				creature:sendSystemMessage("  " .. lines[i])
			end
		end

		WarReportLogin:markFront(pPlayer, zoneName)
	end)

	if not ok then
		printf("WarReportLogin: sendReport failed: " .. tostring(err) .. "\n")
	end
end

--- Drop session-only waypoints on every contested region of this planet.
function WarReportLogin:markFront(pPlayer, zoneName)
	if pPlayer == nil or zoneName == nil then
		return
	end
	if WarReport == nil or WarReport.COORDS == nil then
		return
	end

	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return
	end

	local front = WarReport.frontRegions(WarReportLogin.frontThreshold)
	for i = 1, #front do
		local id = front[i].id
		local coords = WarReport.COORDS[id]

		if coords ~= nil and WarReport.PLANET_OF[id] == zoneName then
			local label = WarReport.regionName(id) .. " (" .. WarReport.factionAdjective(front[i].faction) .. ")"

			pcall(function()
				PlayerObject(pGhost):addWaypoint(
					zoneName,          -- planet
					label,             -- name (literal; no .stf needed)
					"",                -- desc
					coords[1],         -- x
					0,                 -- z
					coords[2],         -- y
					WarReportLogin.waypointColor,
					true,              -- active
					true,              -- notifyClient
					0,                 -- specialTypeID
					0                  -- persistence: session-only, see header
				)
			end)
		end
	end
end

WarReportLogin:install()
