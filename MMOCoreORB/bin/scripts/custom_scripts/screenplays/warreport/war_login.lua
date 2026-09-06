--[[
  custom_scripts/screenplays/warreport/war_login.lua

  Surface 1 of 4: the war report a player gets on login, plus the live map
  overlay that puts the war on their map (drawn by warreport/war_map.lua --
  see that file's header for the label format, colour mapping, and change
  detection; the map-marking logic that used to live in THIS file as
  markFront() has been folded there, see the note below).

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

  MAP OVERLAY FOLDED INTO war_map.lua (2026-09-03): this file used to place
  its own front-only waypoints via a markFront() method (specialTypeID = 0,
  a single flat colour, one label style, front regions only). war_map.lua
  now covers every war city on the player's planet -- not just fronts --
  with a richer label (faction, contest tier, supply) and its own reserved
  specialTypeID, colour-coded by faction, refreshed every 10 minutes. Running
  both would double up pins for the same cities with different colours and
  specialTypeIDs, so markFront() and its two fields (waypointColor,
  frontThreshold) were removed outright rather than left dead and
  re-enableable by accident. The single call site below now hands off to
  WarMap:refresh(pPlayer) instead, which also takes over the 10-minute
  self-rescheduling and logout cleanup -- see war_map.lua's own header.
]]

WarReportLogin = ScreenPlay:new {
	screenplayName = "WarReportLogin",

	-- Delay before the report is sent, ms. Long enough for the client to
	-- finish zoning; short enough that it still reads as "here is where the
	-- war stands" rather than arriving out of nowhere mid-play.
	reportDelayMs = 12000,
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

		-- Only the planet the player is actually standing on. A galaxy-wide
		-- dump every login is the "loading screen" failure this design was
		-- explicitly warned about.
		local zoneName = SceneObject(pPlayer):getZoneName()

		-- Slice 3 (DESIGN-WAR-V2 4.3): the report on section 4's lines --
		-- day, who is winning by reserve, roads into the capitals, the
		-- fronts, then this planet's towns. The old shape stays for an
		-- export without a factions block.
		local st = WarReport.state()
		if WarLines ~= nil and WarLines.report ~= nil and st ~= nil and type(st.factions) == "table" then
			local lines = WarLines.report(st, zoneName, false)
			for i = 1, #lines do
				creature:sendSystemMessage(lines[i])
			end
			-- Slice 9: what happened since this player's last login.
			if WarDigest ~= nil and WarDigest.onLogin ~= nil then
				pcall(function() WarDigest.onLogin(pPlayer, st) end)
			end
			-- Slice 7: the season that ended (paid once), then where this
			-- player stands this season and who leads their side.
			if WarStandings ~= nil and WarStandings.onLogin ~= nil then
				pcall(function() WarStandings.onLogin(pPlayer, st) end)
			end
			return
		end

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

		local lines = WarReport.planetLines(zoneName)
		if #lines > 0 then
			creature:sendSystemMessage("On " .. WarReport.planetName(zoneName) .. ":")
			for i = 1, #lines do
				creature:sendSystemMessage("  " .. lines[i])
			end
		end
	end)

	if not ok then
		printf("WarReportLogin: sendReport failed: " .. tostring(err) .. "\n")
	end

	-- Kick off the map overlay separately from the text-report pcall above,
	-- so a failure in one can never suppress the other. See war_map.lua's
	-- own header for what this does and why it is safe to call unconditionally.
	pcall(function()
		if WarMap ~= nil then
			WarMap:refresh(pPlayer)
		end
	end)
end

WarReportLogin:install()
