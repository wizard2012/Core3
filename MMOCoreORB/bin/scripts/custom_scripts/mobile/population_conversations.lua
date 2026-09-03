--[[
  custom_scripts/mobile/population_conversations.lua

  Phase 1 (D15 / docs/DESIGN-POPULATION.md S4.3, S4.7): conversation
  templates for the field medic and travelling performer. Split out of
  custom_scripts/screenplays/population/standing_services.lua because
  ConvoTemplate/ConvoScreen (mobile/conversation.lua) are only defined in
  the Lua state mobile/serverobjects.lua's own chain loads -- NOT in
  DirectorManager's screenplays.lua state standing_services.lua runs in.
  See custom_scripts/mobile/serverobjects.lua's header for the verified
  load-order finding.

  The actual fee/cooldown/buff logic (PopulationServices:deliverMedic /
  deliverPerformer) lives in standing_services.lua, not here -- these
  handlers only read which NPC was talked to (for its region, hence its
  fee) and call into PopulationServices, which is a plain global table
  reachable from any Lua state in this same process image the same way
  BartendersScreenPlay is already reachable from
  screenplays/cities/cantinas/bartender_conv_handler.lua's own
  cross-file references.

  CORRECTED: this file previously used @population:* StringId keys on the
  premise that this project ships no .stf string table, so those keys
  would render to the player as the literal, un-looked-up key text. That
  premise was wrong. Core3 branches on a leading "@" both at template load
  and at send time (ConversationScreen.h's readObject() for dialog bodies
  via leftDialog/customDialogText, and addOption() for options) and takes
  the string as plain literal text whenever it does NOT start with "@" --
  no .stf entry required. Vanilla already relies on this itself (e.g.
  mobile/conversations/events/syren/kaila_min_conv.lua's literal option
  "You led me into an ambush!"). So every screen below now carries plain
  English directly: dialog bodies via customDialogText, options as literal
  strings in the options tables. This is proven readable client-side, not
  merely server-side -- there is no StringId indirection left to fail.
]]

PopulationMedicConvoTemplate = ConvoTemplate:new {
	initialScreen = "population_medic_start",
	templateType = "Lua",
	luaClassHandler = "PopulationMedicConvHandler",
	screens = {}
}

population_medic_start = ConvoScreen:new {
	id = "population_medic_start",
	customDialogText = "You look like you could use some patching up. I can treat your wounds, for a fee.",
	stopConversation = "false",
	options = {
		{"Patch me up.", "opt_treat"},
		{"Just passing through.", "opt_leave"},
	}
}
PopulationMedicConvoTemplate:addScreen(population_medic_start)

population_medic_treat = ConvoScreen:new {
	id = "opt_treat",
	customDialogText = "Hold still... there, that should hold you over.",
	stopConversation = "true",
	options = {}
}
PopulationMedicConvoTemplate:addScreen(population_medic_treat)

population_medic_leave = ConvoScreen:new {
	id = "opt_leave",
	customDialogText = "Take care of yourself.",
	stopConversation = "true",
	options = {}
}
PopulationMedicConvoTemplate:addScreen(population_medic_leave)

addConversationTemplate("PopulationMedicConvoTemplate", PopulationMedicConvoTemplate)

-- PopulationMedicConvHandler (the luaClassHandler named above) is defined
-- in custom_scripts/screenplays/population/standing_services.lua, NOT
-- here -- conv_handler (screenplays/conv_handler.lua) is only defined in
-- DirectorManager's screenplays.lua Lua state, confirmed live (defining
-- it here raised "attempt to index a nil value (global 'conv_handler')"
-- on every boot). This mirrors vanilla Core3's own split exactly:
-- mobile/conversations/misc/bartender_conv.lua (this file's counterpart)
-- only ever defines ConvoTemplate/ConvoScreen + addConversationTemplate;
-- screenplays/cities/cantinas/bartender_conv_handler.lua (a completely
-- different directory tree) is where BartenderConversationHandler =
-- conv_handler:new{} actually lives. C++ dispatches luaClassHandler by
-- name at conversation-open time, not by Lua reference at definition
-- time, so the two pieces do not need to share a Lua state.

PopulationPerformerConvoTemplate = ConvoTemplate:new {
	initialScreen = "population_performer_start",
	templateType = "Lua",
	luaClassHandler = "PopulationPerformerConvHandler",
	screens = {}
}

population_performer_start = ConvoScreen:new {
	id = "population_performer_start",
	customDialogText = "Stay a while and enjoy the show. Once you've had your fill, come back and I'll help clear your head, for a fee.",
	stopConversation = "false",
	options = {
		{"Watch the performance.", "opt_clear"},
		{"Just passing through.", "opt_leave"},
	}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_start)

population_performer_clear = ConvoScreen:new {
	id = "opt_clear",
	customDialogText = "Enjoy the show.",
	stopConversation = "true",
	options = {}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_clear)

population_performer_leave = ConvoScreen:new {
	id = "opt_leave",
	customDialogText = "Take care of yourself.",
	stopConversation = "true",
	options = {}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_leave)

addConversationTemplate("PopulationPerformerConvoTemplate", PopulationPerformerConvoTemplate)

-- PopulationPerformerConvHandler likewise lives in standing_services.lua
-- -- see the note above PopulationMedicConvoTemplate's addConversationTemplate call.
