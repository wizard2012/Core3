--[[
  custom_scripts/screenplays/warreport/war_bartender.lua

  Surface 3 of 4: cantina bartenders gossip about the war.

  This is the ambient, discoverable half of the design. It is deliberately
  VAGUE where the officer is precise -- you overhear that fighting is bad
  somewhere, not a settlement count. A player who wants numbers goes to a
  capital and talks to the officer.

  WHY IT CHAINS RATHER THAN RE-PATCHES
  ------------------------------------
  population/bartender_rumor.lua already monkey-patches
  BartenderConversationHandler:runScreenHandlers, stashing the vanilla
  function in the table field _populationOriginalRSH. A second, independent
  patch that also tried to capture "the original" would either clobber the
  population rumour or be clobbered by it, depending on load order.

  So this file captures whatever runScreenHandlers is CURRENT at its own
  load time -- which, because custom_scripts/screenplays/screenplays.lua
  includes population/ before warreport/, is the population wrapper -- and
  stores it under its OWN field name, _warOriginalRSH. Calling it runs the
  population rumour, which in turn runs vanilla. Both features work, neither
  knows about the other, and the chain rebuilds correctly on every reload
  because bartender_conv_handler.lua reassigns
  BartenderConversationHandler to a brand-new table each time, nilling both
  fields at once.

  If load order is ever changed so warreport loads first, the chain simply
  runs in the other order -- still correct, because neither wrapper depends
  on the other's effects.

  Literal spatialChat text is the proven pattern here (bartenders.lua's own
  chatListen ships literal strings); literal ConvoScreen dialog is NOT, which
  is why this adds a spoken line rather than a new menu option. Same
  reasoning as population/bartender_rumor.lua's header, and the same reason
  war_officer.lua speaks instead of conversing.
]]

WarRumor = WarRumor or {}

-- Vague by design. Indexed by how bad the worst front is, so the flavour
-- tracks the actual war without quoting numbers at the player.
WarRumor.LINES_QUIET = {
	"Quiet season. The Empire and the Alliance are just glaring at each other.",
	"No real fighting lately. Won't last, it never does.",
	"Folks are still moving cargo without an escort. That tells you something.",
}

WarRumor.LINES_CONTESTED = {
	"Word is there's shooting out %s way. I'd not travel light.",
	"Had a runner through here out of %s. Said it's getting ugly.",
	"They're fighting over %s again. Third time this season.",
}

WarRumor.LINES_HEAVY = {
	"%s is a warzone. Don't go, and if you must, don't go alone.",
	"Whole convoys aren't coming back from %s. Make of that what you will.",
	"If you've got kin near %s, you'd best go get them.",
}

--- Deterministic-ish pick without RNG plumbing: hash the region name and the
-- current tick so the same bartender says the same thing for a while, but the
-- line changes as the war moves. Avoids a player hearing three different
-- lines by clicking the same option three times.
local function pickLine(lines, salt)
	if #lines == 0 then
		return nil
	end
	local h = 0
	for i = 1, #salt do
		h = (h * 31 + salt:byte(i)) % 100003
	end
	return lines[(h % #lines) + 1]
end

--- The rumour, or nil if there is nothing to say (war state unavailable).
function WarRumor:line()
	if WarReport == nil or WarReport.state() == nil then
		return nil
	end

	local st = WarReport.state()
	local tickSalt = tostring(st.generated_at_tick or 0)

	local front = WarReport.frontRegions()
	if #front == 0 then
		return pickLine(self.LINES_QUIET, "quiet" .. tickSalt)
	end

	local worst = front[1]
	local name = WarReport.regionName(worst.id)

	local pool = (worst.contest >= 60.0) and self.LINES_HEAVY or self.LINES_CONTESTED
	local template = pickLine(pool, worst.id .. tickSalt)
	if template == nil then
		return nil
	end
	return string.format(template, name)
end

function WarRumor:tellWarRumor(pNpc)
	if pNpc == nil then
		return
	end
	local ok, line = pcall(function() return self:line() end)
	if ok and line ~= nil then
		spatialChat(pNpc, line)
	end
end

function WarRumor:install()
	if BartenderConversationHandler == nil or type(BartenderConversationHandler) ~= "table" then
		printf("WarRumor: BartenderConversationHandler is not a table -- war rumours disabled, bartenders behave as before.\n")
		return
	end

	if BartenderConversationHandler._warOriginalRSH ~= nil then
		return -- already chained in this VM incarnation
	end

	-- Capture whatever is current (population's wrapper, normally) under our
	-- OWN field, so the two features chain instead of clobbering.
	BartenderConversationHandler._warOriginalRSH = BartenderConversationHandler.runScreenHandlers

	function BartenderConversationHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
		local result = nil

		local okPrev, err = pcall(function()
			local prev = BartenderConversationHandler._warOriginalRSH
			if prev ~= nil then
				result = prev(self, pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
			end
		end)
		if not okPrev then
			printf("WarRumor: chained runScreenHandlers raised: " .. tostring(err) .. "\n")
		end

		pcall(function()
			if pConvScreen == nil then
				return
			end
			local screen = LuaConversationScreen(pConvScreen)
			if screen == nil then
				return
			end
			if screen:getScreenID() == "opt_rumor" then
				WarRumor:tellWarRumor(pNpc)
			end
		end)

		return result
	end
end

WarRumor:install()
