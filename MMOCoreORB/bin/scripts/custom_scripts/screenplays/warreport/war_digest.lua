--[[
  custom_scripts/screenplays/warreport/war_digest.lua

  Slice 9 (2026-09-06, autonomous run): while you were away.

  The login report says what the war IS; nothing said what HAPPENED. The
  export now carries `events` -- the last notable sim events (towns fallen,
  sieges begun and lifted, offensives declared, seasons won, officers
  defeated), newest first, from the sim's own war_event table -- and this
  module reads back, on login, the ones since the player's last login:

    While you were away:
      The Alliance declared an offensive at Moenia. (~4 h ago)
      Theed came under siege: the Alliance holds every road into it. (~3 h ago)
      Moenia fell to the Alliance. (under an hour ago)

  oldest first so it reads as a story, capped at MAX_LINES (the newest
  kept). A first login on this code reads the last FIRST_LOGIN_TICKS ticks
  under "Lately:". The lines are WarLines.eventLine / sinceLines (pure,
  pinned by bridge/tests/t_readouts.lua).

  THE LAST-SEEN TICK lives in screenplay state (LAST_SEEN_KEY). The binding
  ORs (CLAUDE.md part 3), so markSeen clears the old word before it sets
  the new one -- assign, not accumulate. Set only when the export's tick is
  newer than what is stored.
]]

WarDigest = WarDigest or {}

WarDigest.LAST_SEEN_KEY = "war_last_seen_tick"
WarDigest.MAX_LINES = 12
WarDigest.FIRST_LOGIN_TICKS = 24 -- six hours at the 15-minute tick

function WarDigest.lastSeen(creature)
	return math.tointeger(tonumber(creature:getScreenPlayState(WarDigest.LAST_SEEN_KEY))) or 0
end

--- Assign the tick: clear the stored word, then set the new one.
function WarDigest.markSeen(creature, tick)
	local cur = WarDigest.lastSeen(creature)
	if cur == tick then
		return
	end
	if cur > 0 then
		creature:removeScreenPlayState(cur, WarDigest.LAST_SEEN_KEY)
	end
	creature:setScreenPlayState(tick, WarDigest.LAST_SEEN_KEY)
end

--- The login lines, then the last-seen tick moves up.
function WarDigest.onLogin(pPlayer, st)
	if pPlayer == nil or st == nil or WarLines == nil or WarLines.sinceLines == nil then
		return
	end
	local creature = CreatureObject(pPlayer)
	local tick = math.tointeger(tonumber(st.generated_at_tick)) or 0
	if tick <= 0 then
		return
	end
	local last = WarDigest.lastSeen(creature)
	local since = (last > 0) and last or math.max(0, tick - WarDigest.FIRST_LOGIN_TICKS)
	local lines = WarLines.sinceLines(st, since, WarDigest.MAX_LINES)
	if #lines > 0 then
		creature:sendSystemMessage((last > 0) and "While you were away:" or "Lately:")
		for _, line in ipairs(lines) do
			creature:sendSystemMessage("  " .. line)
		end
	end
	if tick > last then
		WarDigest.markSeen(creature, tick)
	end
end

-- Console probe: test warDigestCheck -- the lines for the last twelve hours
-- and every event line in the live export.
if type(Tests) == "table" then
	function Tests:warDigestCheck()
		printf("WARDIGEST: begin\n")
		local ok, err = pcall(function()
			local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
			if st == nil or WarLines == nil or WarLines.sinceLines == nil then
				printf("WARDIGEST: no war state or no WarLines on this thread\n")
				return
			end
			local tick = tonumber(st.generated_at_tick) or 0
			local n = type(st.events) == "table" and #st.events or 0
			printf("WARDIGEST: tick=" .. tostring(tick) .. " events=" .. tostring(n) .. "\n")
			for _, line in ipairs(WarLines.sinceLines(st, tick - 48, 12)) do
				printf("WARDIGEST: since-48 | " .. line .. "\n")
			end
			for i = 1, math.min(n, 8) do
				printf("WARDIGEST: event " .. tostring(st.events[i].tick) .. " " .. tostring(st.events[i].kind) .. " | "
					.. tostring(WarLines.eventLine(st.events[i], st)) .. "\n")
			end
		end)
		if not ok then
			printf("WARDIGEST: failed: " .. tostring(err) .. "\n")
		end
		printf("WARDIGEST: end\n")
	end
end
