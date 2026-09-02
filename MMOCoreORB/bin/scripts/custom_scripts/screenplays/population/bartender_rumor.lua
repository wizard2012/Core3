--[[
  custom_scripts/screenplays/population/bartender_rumor.lua

  Phase 1/2 discovery (docs/DESIGN-POPULATION.md S4.7.5): "ask a
  bartender" -- the cheapest of the three discovery mechanisms listed,
  and the only one this design needs to build anything for.

  WHY THIS IS A MONKEY-PATCH AND NOT A SUBMODULE EDIT
  -----------------------------------------------------
  screenplays/cities/cantinas/bartender_conv_handler.lua already has an
  "opt_rumor" branch ("Heard anything interesting lately?") that every
  rumour-flagged bartender (15% of the 17, per bartenders.lua) offers.
  docs/DESIGN-POPULATION.md S13's file map calls a new branch there "the
  only edit outside custom_scripts/" and explicitly offers the fallback of
  keeping the change out of the submodule entirely. This file takes that
  fallback: it does NOT touch bartender_conv_handler.lua. Instead, exactly
  like bridge/war_hook.lua already does for CityScreenPlay (see that
  file's own header for the mechanism), it monkey-patches
  BartenderConversationHandler:runScreenHandlers from custom_scripts/,
  which loads after screenplays.lua has already defined
  BartenderConversationHandler as a global table (verified:
  screenplays/screenplays.lua includes cities/cantinas/bartender_conv_handler.lua
  at line 587 and custom_scripts/screenplays/screenplays.lua at line 734,
  well after). git -C core3 status stays clean; the override lives here.

  This ADDS to the existing opt_rumor behaviour (the player-fed-rumour
  system stays exactly as it was) rather than adding a new UI screen --
  which sidesteps needing a new .stf string-table entry (a TRE/client
  asset this design cannot add, see standing_services.lua's own note)
  for a new button label. The rumour line itself uses spatialChat with a
  literal string, exactly like bartenders.lua's own chatListen already
  does ("Ya never know what ya'll hear 'round these parts...") -- literal
  spatialChat text is a proven, already-shipped pattern in this exact file
  chain, unlike literal ConvoScreen dialog text, which is not.

  Re-capturing the original function is done via a FIELD ON THE TABLE
  (_populationOriginalRSH), not a free-standing global: bartender_conv_handler.lua
  reassigns `BartenderConversationHandler = conv_handler:new{}` to a BRAND
  NEW table on every reload, so the field is naturally nil again after
  each reload-lua.sh and this file re-captures the fresh vanilla function
  every time rather than risking a stale closure.

  FAIL-SAFE CONTRACT
  -------------------
  Every read here goes through pcall / PopulationPlacement's own nil
  contract. If BartenderConversationHandler is not a table when this file
  loads (bartender_conv_handler.lua missing, or a load-order change), this
  file logs once and does nothing -- the bartender's rumour behaves as
  pure stock Core3, with no extra line and no error.
]]

PopulationRumor = PopulationRumor or {}

local REGION_DISPLAY = {
	cor_bela_vistal = "Bela Vistal",
	cor_coronet     = "Coronet",
	cor_doaba       = "Doaba Guerfel",
	cor_kor_vella   = "Kor Vella",
	cor_tyrena      = "Tyrena",
	nab_kaadara     = "Kaadara",
	nab_keren       = "Keren",
	nab_moenia      = "Moenia",
	nab_theed       = "Theed",
	tat_anchorhead  = "Anchorhead",
	tat_bestine     = "Bestine",
	tat_mos_eisley  = "Mos Eisley",
	tat_mos_espa    = "Mos Espa",
}

local function displayName(regionId)
	if regionId == nil then
		return nil
	end
	return REGION_DISPLAY[regionId] or regionId
end

local function holdPhrase(ticksLeft)
	if ticksLeft == nil then
		return ""
	elseif ticksLeft <= 24 then
		return ", and she'll be there another day or so"
	elseif ticksLeft <= 48 then
		return ", she should be there a couple more days"
	else
		return ", she's just settled in"
	end
end

local function providerLine(kind, providerId, verb)
	if type(POPULATION_SERVICES) ~= "table" or not POPULATION_SERVICES[kind] then
		return nil
	end

	local warState = PopulationPlacement.loadWarState()
	if warState == nil then
		return nil
	end

	local regionId = PopulationPlacement.currentRegion(kind, providerId, warState, {})
	if regionId == nil then
		return nil
	end

	local name = displayName(regionId)
	local ticksLeft = PopulationPlacement.ticksUntilNextCycle(warState)

	return "Last I heard, " .. verb .. " working " .. name .. holdPhrase(ticksLeft) .. "."
end

--- Speaks up to two lines (one per provider kind still switched on) about
-- where the medics/performers currently are. Called from the
-- BartenderConversationHandler patch below; safe to call standalone from
-- the console for a demo (runLuaFunction PopulationRumor:tellProviderRumor:<npcOid>).
function PopulationRumor:tellProviderRumor(pNpc)
	if pNpc == nil then
		return
	end

	local medicLine = providerLine("medic", "medic_1", "the medic's") or providerLine("medic", "medic_2", "the medic's")
	local performerLine = providerLine("performer", "performer_1", "the performer's") or providerLine("performer", "performer_2", "the performer's")

	if medicLine ~= nil then
		spatialChat(pNpc, medicLine)
	end

	if performerLine ~= nil then
		spatialChat(pNpc, performerLine)
	end
end

-- ============================================================ the patch ==

if type(BartenderConversationHandler) == "table" then
	if BartenderConversationHandler._populationOriginalRSH == nil then
		BartenderConversationHandler._populationOriginalRSH = BartenderConversationHandler.runScreenHandlers
	end

	local original = BartenderConversationHandler._populationOriginalRSH

	function BartenderConversationHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
		local result = original(self, pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)

		local ok = pcall(function()
			local screen = LuaConversationScreen(pConvScreen)
			if screen:getScreenID() == "opt_rumor" then
				PopulationRumor:tellProviderRumor(pNpc)
			end
		end)

		if not ok then
			-- FAIL SAFE: the extra rumour line failed for any reason;
			-- the original bartender behaviour above already ran and
			-- already returned a valid conversation screen, so the
			-- conversation itself is unaffected.
		end

		return result
	end
else
	printf("PopulationRumor: BartenderConversationHandler is not loaded -- provider rumour disabled, bartenders behave as stock Core3.\n")
end
