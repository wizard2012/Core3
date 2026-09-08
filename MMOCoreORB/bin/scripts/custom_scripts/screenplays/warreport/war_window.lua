--[[
war_window.lua -- The War window (B48; owner ruling 2026-09-07, evening:
"SUI war window from the officer").

The officer's fourth radial, "War", opens a real client window (a SUI list
box, the same server-driven UI the stock skill trainers and junk dealers
use) instead of the chat-line report: the report lines, the towns with a
fight in their streets, this player's standing and open order, then action
rows -- take orders, transport to the front, print the report to chat --
that run the same code the Orders / Deploy / Report radials run. Close does
nothing. No slash command: the client only sends the commands in its own
command table, so a /war can never reach the server without a client patch.

Pure, tested by the console probe (test warWindowCheck): WarWindow.rows(st,
zoneName, pPlayer, pOfficer) -> rows, prompt.
]]

WarWindow = WarWindow or {}

WarWindow.RADIAL_ID = 23
WarWindow.SIZE = "620,460"
WarWindow.ACTION_ORDERS = "orders"
WarWindow.ACTION_DEPLOY = "deploy"
WarWindow.ACTION_REPORT = "report"
WarWindow.MAX_ROWS = 60

--- The window's rows: { text, value } each; value "" for a line, an action
-- name for an action row. The prompt is the report's first line.
function WarWindow.rows(st, zoneName, pPlayer, pOfficer)
	local rows = {}
	local function add(text, value)
		if text ~= nil and text ~= "" and #rows < WarWindow.MAX_ROWS then
			rows[#rows + 1] = { text = tostring(text), value = value or "" }
		end
	end
	local prompt = "The war."
	if st == nil or type(st.factions) ~= "table" or WarLines == nil or WarLines.report == nil then
		add("The war reports nothing yet.", "")
		return rows, prompt
	end
	local lines = WarLines.report(st, zoneName, true)
	if #lines > 0 then
		prompt = lines[1]
	end
	for i = 2, #lines do
		add(lines[i], "")
	end
	-- B43: fights standing in a town's streets right now.
	if WarBattle ~= nil and WarBattle.fronts ~= nil and WarVoice ~= nil and WarVoice.streetsNote ~= nil
		and WarReport ~= nil and WarReport.regionName ~= nil then
		local nowMs = getTimestampMilli()
		local cap = (WarPresence ~= nil and WarPresence.STREETS_NOTE_MS) or (30 * 60 * 1000)
		for _, f in ipairs(WarBattle.fronts()) do
			local by = readStringData("warbattle:streets:" .. tostring(f.id))
			local at = readData("warbattle:streets_ms:" .. tostring(f.id)) or 0
			if by ~= nil and by ~= "" and at > 0 and (nowMs - at) <= cap then
				add(WarVoice.streetsNote(by, WarReport.regionName(f.id)), "")
			end
		end
	end
	if pPlayer ~= nil then
		if WarStandings ~= nil and WarStandings.officerLines ~= nil then
			local ok, standing = pcall(function() return WarStandings.officerLines(pPlayer, st) end)
			if ok and type(standing) == "table" then
				for _, line in ipairs(standing) do
					add(line, "")
				end
			end
		end
		if WarOrders ~= nil and WarOrders.reportLine ~= nil then
			local ok, orderLine = pcall(function() return WarOrders.reportLine(pPlayer, st) end)
			if ok and orderLine ~= nil then
				add(orderLine, "")
			end
		end
	end
	add("-- Select a row and press Do it --", "")
	if WarOrders ~= nil and WarOrders.onRadial ~= nil then
		add("Take orders from this officer", WarWindow.ACTION_ORDERS)
	end
	if WarDeploy ~= nil and WarDeploy.onRadial ~= nil then
		add("Transport to the front", WarWindow.ACTION_DEPLOY)
	end
	add("Print this report to chat", WarWindow.ACTION_REPORT)
	return rows, prompt
end

--- Open the window for a player at an officer.
function WarWindow.open(pPlayer, pOfficer)
	if pPlayer == nil then
		return false
	end
	local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	local zoneName = SceneObject(pPlayer):getZoneName()
	local rows, prompt = WarWindow.rows(st, zoneName, pPlayer, pOfficer)
	if SuiListBox == nil then
		-- No SUI library on this thread: the chat report instead.
		for _, r in ipairs(rows) do
			if r.value == "" then
				CreatureObject(pPlayer):sendSystemMessage(r.text)
			end
		end
		return false
	end
	local sui = SuiListBox.new("WarWindow", "onSelect")
	sui.setTargetNetworkId(SceneObject(pPlayer):getObjectID())
	sui.setProperty("", "Size", WarWindow.SIZE)
	sui.setTitle("The War")
	sui.setPrompt(prompt)
	sui.setOkButtonText("Do it")
	sui.setCancelButtonText("Close")
	sui.setStoredData("officer", tostring((pOfficer ~= nil) and SceneObject(pOfficer):getObjectID() or 0))
	for _, r in ipairs(rows) do
		sui.add(r.text, r.value)
	end
	sui.sendTo(pPlayer)
	printf("WarWindow: opened for " .. tostring(SceneObject(pPlayer):getObjectID()) .. " with " .. tostring(#rows) .. " row(s)\n")
	return true
end

--- The window's callback: Do it on an action row runs the radial's code.
function WarWindow:onSelect(pPlayer, pSui, eventIndex, args)
	if pPlayer == nil or eventIndex == 1 then
		return
	end
	local ok, err = pcall(function()
		local pPageData = LuaSuiBoxPage(pSui):getSuiPageData()
		if pPageData == nil then
			return
		end
		local page = LuaSuiPageData(pPageData)
		local value = page:getStoredData(tostring(args))
		local officerOid = tonumber(page:getStoredData("officer")) or 0
		local pOfficer = (officerOid > 0) and getSceneObject(officerOid) or nil
		if value == WarWindow.ACTION_ORDERS and WarOrders ~= nil and WarOrders.onRadial ~= nil then
			WarOrders.onRadial(pPlayer, pOfficer)
		elseif value == WarWindow.ACTION_DEPLOY and WarDeploy ~= nil and WarDeploy.onRadial ~= nil then
			WarDeploy.onRadial(pPlayer, pOfficer)
		elseif value == WarWindow.ACTION_REPORT and WarOfficerReportMenuComponent ~= nil and pOfficer ~= nil then
			WarOfficerReportMenuComponent:sendReport(pPlayer, pOfficer)
		end
	end)
	if not ok then
		printf("WarWindow.onSelect failed, swallowed: " .. tostring(err) .. "\n")
	end
end

-- Console probe: test warWindowCheck
if type(Tests) == "table" then
	function Tests:warWindowCheck()
		printf("WARWINDOW: begin\n")
		local ok, err = pcall(function()
			local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
			local rows, prompt = WarWindow.rows(st, "naboo", nil, nil)
			printf("WARWINDOW: prompt | " .. tostring(prompt) .. "\n")
			printf("WARWINDOW: " .. tostring(#rows) .. " row(s)\n")
			for i = 1, math.min(#rows, 6) do
				printf("WARWINDOW:   " .. rows[i].text .. "\n")
			end
			local actions = 0
			for _, r in ipairs(rows) do
				if r.value ~= "" then actions = actions + 1 end
			end
			printf("WARWINDOW: " .. ((actions >= 2) and "PASS" or "FAIL") .. " action rows present (" .. tostring(actions) .. ")\n")
			printf("WARWINDOW: " .. ((SuiListBox ~= nil and SuiListBox.new ~= nil) and "PASS" or "FAIL") .. " SuiListBox is on this thread\n")
			printf("WARWINDOW: " .. ((#rows <= WarWindow.MAX_ROWS) and "PASS" or "FAIL") .. " within the row cap\n")
			local empty = WarWindow.rows(nil, "naboo", nil, nil)
			printf("WARWINDOW: " .. ((#empty == 1) and "PASS" or "FAIL") .. " no state gives one line\n")
		end)
		if not ok then
			printf("WARWINDOW: failed: " .. tostring(err) .. "\n")
		end
		printf("WARWINDOW: end\n")
	end
end
