--[[
  custom_scripts/screenplays/warreport/war_standings.lua

  Slice 7 (2026-09-06, autonomous run): what the war gives a player back.

  The ledger has always known who did what; nobody could see it in the game,
  and a season ended with nothing for anyone. The export now carries
  `standings` (per-character points this season, best first, both sides,
  names from the game's characters table), `last_season` (the season that
  ended last, with its final standings, winner and deciding region) and
  `ranks` (the titles war_rank holds for each side). This module turns them
  into:

    - the login report's personal lines, after the section 4.3 report:
      "You: 41 crates' worth this season, 1st of 3 in the Alliance, rank
      Commander." and "Top of the Alliance: Kessa 41, Rue 12, ..."
      (WarLines.ownStandingLine / topLine, war_lines.lua);
    - the officer's report: the count of players on each side
      (WarLines.countedLine), the same personal line, a longer top list;
    - the season's pay, ONCE per character per season, on the first login
      after the reset: credits and faction standing scaled by the points
      (CREDITS_PER_POINT, STANDING_PER_POINT), the winner's bonus on top,
      both capped. WarStandings.payoutFor is pure; settle() pays;
    - the galaxy-wide "most decorated" line under the season-won dispatch
      (WarLines.decoratedLine, from war_lines.lua's transitions).

  WHY LAST SEASON, NOT THE INTERMISSION: the export keeps `standings` for
  the season in progress (winner set or not) and `last_season` for the one
  before it. A season is paid from `last_season`, so a player away through
  the twelve-hour intermission is still paid on their next login, and the
  numbers paid are final by construction (the window closed at the reset).

  IDEMPOTENCE: the last season index paid is kept in screenplay state
  (PAID_KEY) per character, written BEFORE the pay -- paying nobody twice
  is worth more than paying everybody once -- and the log line says what
  happened either way.

  POINTS ARE THE LEDGER'S: one point is one crate's worth (a crate donated,
  a crate carried, a body at a front). A rank (WarLines.rankTitle) is a
  readout, not a permission: nothing checks it.

  The pure parts are covered by bridge/tests/t_readouts.lua from a fixture;
  the engine parts by `test warStandingsCheck` (a render from the live
  export and a dry-run payout that is never applied) and a client login.
]]

WarStandings = WarStandings or {}

WarStandings.CREDITS_PER_POINT = 500    -- 30 crates' worth of a season: 15,000 credits...
WarStandings.STANDING_PER_POINT = 20    -- ...and 600 faction standing
WarStandings.WIN_BONUS_CREDITS = 5000   -- on top, for a character counted on the winning side
WarStandings.WIN_BONUS_STANDING = 500
WarStandings.MAX_CREDITS = 250000
WarStandings.MAX_STANDING = 5000
WarStandings.PAID_KEY = "war_season_paid" -- screenplay state: the last season index paid to this character
WarStandings.TOP_LOGIN = 3
WarStandings.TOP_OFFICER = 5

--- Pure. What the season that ended last pays this character, or nil when
-- there is no last season, no entry, or nothing to pay:
-- { credits, standing, won, points, faction }.
function WarStandings.payoutFor(st, oid)
	local ls = st and st.last_season
	if type(ls) ~= "table" or WarLines == nil or WarLines.entryOf == nil then
		return nil
	end
	local e = WarLines.entryOf(ls, oid)
	if e == nil then
		return nil
	end
	local p = tonumber(e.points) or 0
	if p <= 0 then
		return nil
	end
	local won = (ls.winner ~= nil and ls.winner == e.faction)
	local credits = math.floor(p * WarStandings.CREDITS_PER_POINT + 0.5) + (won and WarStandings.WIN_BONUS_CREDITS or 0)
	local standing = math.floor(p * WarStandings.STANDING_PER_POINT + 0.5) + (won and WarStandings.WIN_BONUS_STANDING or 0)
	return {
		credits = math.min(credits, WarStandings.MAX_CREDITS),
		standing = math.min(standing, WarStandings.MAX_STANDING),
		won = won,
		points = p,
		faction = e.faction,
	}
end

--- The player's side in the export's vocabulary ("imperial"/"rebel"), or nil.
function WarStandings.factionOf(pPlayer)
	local hash = CreatureObject(pPlayer):getFaction()
	if recruiterScreenplay ~= nil and recruiterScreenplay.getFactionFromHashCode ~= nil then
		local f = recruiterScreenplay:getFactionFromHashCode(hash)
		if f == "imperial" or f == "rebel" then
			return f
		end
		return nil
	end
	if FACTIONIMPERIAL ~= nil and hash == FACTIONIMPERIAL then
		return "imperial"
	end
	if FACTIONREBEL ~= nil and hash == FACTIONREBEL then
		return "rebel"
	end
	return nil
end

--- Pay the season that ended last, once per character. Returns true when
-- the result lines were sent (paid or not), false when nothing was new.
function WarStandings.settle(pPlayer, st)
	local ls = st and st.last_season
	local index = (type(ls) == "table") and math.tointeger(tonumber(ls.index)) or nil
	if index == nil or index <= 0 then
		return false
	end
	local creature = CreatureObject(pPlayer)
	local paid = tonumber(creature:getScreenPlayState(WarStandings.PAID_KEY)) or 0
	if paid >= index then
		return false
	end
	creature:setScreenPlayState(index, WarStandings.PAID_KEY)
	local oid = SceneObject(pPlayer):getObjectID()
	local pay = WarStandings.payoutFor(st, oid)
	for _, line in ipairs(WarLines.seasonResultLines(st, oid, pay)) do
		creature:sendSystemMessage(line)
	end
	if pay ~= nil then
		local ok, err = pcall(function()
			creature:addCashCredits(pay.credits, true)
			local pGhost = creature:getPlayerObject()
			if pGhost ~= nil and pay.standing > 0 then
				PlayerObject(pGhost):increaseFactionStanding(pay.faction, pay.standing)
			end
		end)
		printf("WarStandings: season " .. tostring(index) .. " paid " .. tostring(oid) .. " "
			.. tostring(pay.credits) .. " credits, " .. tostring(pay.standing) .. " " .. tostring(pay.faction)
			.. " standing" .. (pay.won and " (winner)" or "")
			.. (ok and "\n" or (" -- FAILED: " .. tostring(err) .. "\n")))
	end
	return true
end

--- The login report's personal lines, after the section 4.3 report.
function WarStandings.onLogin(pPlayer, st)
	if pPlayer == nil or st == nil or WarLines == nil or WarLines.ownStandingLine == nil then
		return
	end
	local creature = CreatureObject(pPlayer)
	pcall(function() WarStandings.settle(pPlayer, st) end)
	local faction = WarStandings.factionOf(pPlayer)
	if faction == nil or type(st.standings) ~= "table" then
		return
	end
	local oid = SceneObject(pPlayer):getObjectID()
	creature:sendSystemMessage(WarLines.ownStandingLine(st, faction, oid))
	local top = WarLines.topLine(st, faction, WarStandings.TOP_LOGIN)
	if top ~= nil then
		creature:sendSystemMessage(top)
	end
end

--- The officer's standings lines (after "What you can do here").
function WarStandings.officerLines(pPlayer, st)
	local lines = {}
	if pPlayer == nil or st == nil or WarLines == nil or WarLines.countedLine == nil or type(st.standings) ~= "table" then
		return lines
	end
	local counted = WarLines.countedLine(st)
	if counted ~= nil then
		lines[#lines + 1] = counted
	end
	local faction = WarStandings.factionOf(pPlayer)
	if faction ~= nil then
		lines[#lines + 1] = WarLines.ownStandingLine(st, faction, SceneObject(pPlayer):getObjectID())
		local top = WarLines.topLine(st, faction, WarStandings.TOP_OFFICER)
		if top ~= nil then
			lines[#lines + 1] = top
		end
	end
	return lines
end

-- Console probe: test warStandingsCheck -- renders the standings lines from
-- the live export and a dry-run payout from a synthetic last season that is
-- never applied to anyone.
if type(Tests) == "table" then
	function Tests:warStandingsCheck()
		printf("WARSTANDINGS: begin\n")
		local ok, err = pcall(function()
			local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
			if st == nil or WarLines == nil then
				printf("WARSTANDINGS: no war state or no WarLines on this thread\n")
				return
			end
			local block = st.standings
			local entries = (type(block) == "table" and type(block.top) == "table") and #block.top or 0
			printf("WARSTANDINGS: standings=" .. tostring(type(block) == "table") .. " entries=" .. tostring(entries)
				.. " last_season=" .. tostring(type(st.last_season) == "table" and st.last_season.index or "none")
				.. " ranks=" .. tostring(type(st.ranks) == "table") .. "\n")
			printf("WARSTANDINGS: counted | " .. tostring(WarLines.countedLine(st)) .. "\n")
			for _, f in ipairs({ "imperial", "rebel" }) do
				printf("WARSTANDINGS: top " .. f .. " | " .. tostring(WarLines.topLine(st, f, 5)) .. "\n")
			end
			printf("WARSTANDINGS: decorated | " .. tostring(WarLines.decoratedLine(st, 3)) .. "\n")
			local first = (entries > 0) and block.top[1] or nil
			if first ~= nil then
				printf("WARSTANDINGS: own(" .. tostring(first.id) .. ") | " .. WarLines.ownStandingLine(st, first.faction, first.id) .. "\n")
			end
			printf("WARSTANDINGS: own(none) | " .. WarLines.ownStandingLine(st, "rebel", 1) .. "\n")
			local fake = {
				last_season = { index = 1, winner = "imperial", deciding_region = "nab_lianorm",
					top = { { id = 42, name = "Probe", faction = "rebel", points = 30 } } },
				ranks = st.ranks,
			}
			local pay = WarStandings.payoutFor(fake, 42)
			printf("WARSTANDINGS: dry-run pay | credits=" .. tostring(pay and pay.credits) .. " standing="
				.. tostring(pay and pay.standing) .. " won=" .. tostring(pay and pay.won) .. "\n")
			for _, line in ipairs(WarLines.seasonResultLines(fake, 42, pay)) do
				printf("WARSTANDINGS: dry-run line | " .. line .. "\n")
			end
		end)
		if not ok then
			printf("WARSTANDINGS: failed: " .. tostring(err) .. "\n")
		end
		printf("WARSTANDINGS: end\n")
	end
end
