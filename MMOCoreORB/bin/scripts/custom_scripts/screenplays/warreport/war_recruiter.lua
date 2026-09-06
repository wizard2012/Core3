--[[
  custom_scripts/screenplays/warreport/war_recruiter.lua

  Faction recruiters hand out front-line assignments: ask an Imperial or Rebel
  recruiter about the war and get a spoken briefing plus a waypoint to the
  live battle.

  WHY A RECRUITER AND NOT A MISSION TERMINAL
  ------------------------------------------
  A mission terminal entry was the original ask, and it is the one thing this
  project cannot deliver readably. Mission generation is C++ (MissionManager),
  and terminal entries draw their title, description and objective text from
  the client's .stf string tables. This project cannot ship .stf files -- they
  are TRE/client assets (see BACKLOG B4, and population_conversations.lua's own
  note) -- so a new mission type would render every line to the player as a raw
  key like "@mission/warfront:title". That is precisely the unreadable-client
  failure that cost real time on B4.

  Recruiters are already in the game as conversable NPCs with a Lua screenplay
  (screenplays/gcw/recruiters/), and spatialChat + sendSystemMessage + waypoint
  labels all take PLAIN strings. So the player gets readable text today, with
  no C++, no rebuild, and no client assets.

  HOW IT HOOKS
  ------------
  Same monkey-patch mechanism as population/bartender_rumor.lua and
  war_bartender.lua: RecruiterConvoHandler is a plain global
  (recruiterConvoHandler.lua:3, `RecruiterConvoHandler = conv_handler:new {}`),
  and custom_scripts loads after it. The original is stashed on a FIELD of the
  table (_warOriginalRecruiterRSH) so it re-captures cleanly after every
  reload, when that file reassigns the table anew.

  It fires on the screens where a player is already asking about the war --
  the GCW score screen and the faction-member greetings -- so it adds to an
  existing conversation branch rather than needing a new menu option, which
  would itself need an .stf label.
]]

WarRecruiter = WarRecruiter or {}

-- Screens on which a briefing is appropriate: the player is asking about the
-- war, or has just reported in as a faction member.
WarRecruiter.BRIEF_SCREENS = {
	["show_gcw_score"] = true,
	["greet_member_start_covert"] = true,
	["greet_member_start_overt"] = true,
	["greet_member_start_covert2"] = true,
	["greet_member_start_overt2"] = true,
}

-- Waypoint colour and per-player cooldown so repeat conversations do not
-- stack duplicate markers in the datapad.
WarRecruiter.WAYPOINT_COLOR = 2
WarRecruiter.COOLDOWN_MS = 3 * 60 * 1000

--- Where the live battle is, or nil. Reads WarBattle's own record rather than
-- recomputing, so the recruiter can never send a player somewhere the battle
-- system did not actually stage a fight.
function WarRecruiter:battleRegion()
	if WarBattle == nil then
		return nil
	end
	local id = readStringData(WarBattle.REGION_KEY)
	if id == nil or id == "" then
		return nil
	end
	return id
end

--- The briefing line, or nil if there is nothing to say.
function WarRecruiter:briefLine()
	if WarReport == nil or WarReport.state() == nil then
		return nil, nil
	end

	-- The Supply War's countdown for a region, as a clause, or "".
	local function stakes(regionId)
		local st = WarReport.state()
		local r = st ~= nil and st.regions[regionId] or nil
		if r == nil or r.crates == nil or WarLines == nil then
			return ""
		end
		if r.is_capital and type(r.siege) == "table" and r.siege.active then
			return " The capital is under siege."
		end
		local fall = WarLines.fallText(r, st)
		if fall ~= nil then
			return " It " .. fall .. "."
		end
		return ""
	end

	local battleRegion = WarRecruiter:battleRegion()
	if battleRegion ~= nil then
		local name = WarReport.regionName(battleRegion)
		local planet = WarReport.planetName(WarReport.PLANET_OF[battleRegion])
		return "There's fighting at " .. name .. " on " .. planet
			.. " right now." .. stakes(battleRegion) .. " Get out there.", battleRegion
	end

	-- No live battle: point at the hottest front instead of inventing one.
	local front = WarReport.frontRegions()
	if #front > 0 then
		local name = WarReport.regionName(front[1].id)
		return "No engagement underway. " .. name .. " is where it'll break next." .. stakes(front[1].id), nil
	end

	return "Quiet on every front. Enjoy it while it lasts.", nil
end

--- Drop a waypoint on the battle. Session-only (persistence 0) for the same
-- reason war_login.lua's front markers are: a battle lasts ten minutes, and a
-- persistent marker would outlive it and point at empty desert.
function WarRecruiter:markBattle(pPlayer, regionId)
	if pPlayer == nil or regionId == nil or WarReport == nil then
		return
	end

	local coords = WarReport.COORDS[regionId]
	local zone = WarReport.PLANET_OF[regionId]
	if coords == nil or zone == nil then
		return
	end

	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return
	end

	-- Point at wherever WarBattle actually staged the recruiter-anchor site,
	-- not a locally recomputed offset. WarBattle.anchorPoint() is the SINGLE
	-- place this coords+offset arithmetic exists (see war_battle.lua's
	-- SITE_OVERRIDES comment) -- calling it here rather than recomputing
	-- coords + BATTLE_OFFSET_M ourselves is what makes it structurally
	-- impossible for this waypoint and the actual fight to drift apart,
	-- including when a region has a SITE_OVERRIDES.anchorOffset. Fall back
	-- to the bare town centre (offset 0) only if WarBattle itself is
	-- unavailable, same as the old behaviour.
	local wx, wy = coords[1], coords[2]
	if WarBattle ~= nil and WarBattle.anchorPoint ~= nil then
		wx, wy = WarBattle.anchorPoint(coords, regionId)
	end

	pcall(function()
		PlayerObject(pGhost):addWaypoint(
			zone,
			"Front line: " .. WarReport.regionName(regionId),
			"",
			wx, 0, wy,
			WarRecruiter.WAYPOINT_COLOR,
			true, true, 0, 0)
	end)
end

function WarRecruiter:brief(pPlayer, pNpc)
	if pPlayer == nil then
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()
	local key = playerOid .. ":war:lastRecruiterBrief"
	local last = readData(key)
	local now = getTimestampMilli()
	if last ~= nil and last > 0 and (now - last) < WarRecruiter.COOLDOWN_MS then
		return
	end
	writeData(key, now)

	local line, battleRegion = WarRecruiter:briefLine()
	if line == nil then
		return
	end

	if pNpc ~= nil then
		pcall(function() spatialChat(pNpc, line) end)
	end

	if battleRegion ~= nil then
		CreatureObject(pPlayer):sendSystemMessage("A waypoint to the fighting has been added to your datapad.")
		WarRecruiter:markBattle(pPlayer, battleRegion)
	end
end

function WarRecruiter:install()
	if RecruiterConvoHandler == nil or type(RecruiterConvoHandler) ~= "table" then
		printf("WarRecruiter: RecruiterConvoHandler is not a table -- recruiter briefings disabled, recruiters behave as stock.\n")
		return
	end

	if RecruiterConvoHandler._warOriginalRecruiterRSH ~= nil then
		return
	end

	RecruiterConvoHandler._warOriginalRecruiterRSH = RecruiterConvoHandler.runScreenHandlers

	function RecruiterConvoHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
		local result = nil

		-- Vanilla first and unconditionally: faction joining, promotions and
		-- resignations must work even if everything below fails.
		local okPrev, errPrev = pcall(function()
			local prev = RecruiterConvoHandler._warOriginalRecruiterRSH
			if prev ~= nil then
				result = prev(self, pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
			end
		end)
		if not okPrev then
			printf("WarRecruiter: original runScreenHandlers raised: " .. tostring(errPrev) .. "\n")
		end

		pcall(function()
			if pConvScreen == nil then
				return
			end
			local screen = LuaConversationScreen(pConvScreen)
			if screen == nil then
				return
			end
			if WarRecruiter.BRIEF_SCREENS[screen:getScreenID()] then
				WarRecruiter:brief(pPlayer, pNpc)
			end
		end)

		return result
	end
end

WarRecruiter:install()
