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

  BEST-EFFORT, UNPROVEN CLIENT-SIDE (docs/AGENTS.md S8, BACKLOG B4): the
  @population:* string ids below follow this codebase's own convention
  (see @bartender:* in mobile/conversations/misc/bartender_conv.lua) but
  this design cannot add the matching .stf string-table entries -- that is
  a TRE/client-asset pipeline step, out of the Lua+SQL scope this task is
  bound to. Until a .stf exists, the client shows the raw key rather than
  readable text; the underlying MECHANIC is fully server-side and is what
  screenplays/tests/tests.lua's Tests:populationPhase1 exercises directly,
  bypassing the conversation UI entirely, exactly per
  docs/DESIGN-POPULATION.md S10's acceptance spec.
]]

PopulationMedicConvoTemplate = ConvoTemplate:new {
	initialScreen = "population_medic_start",
	templateType = "Lua",
	luaClassHandler = "PopulationMedicConvHandler",
	screens = {}
}

population_medic_start = ConvoScreen:new {
	id = "population_medic_start",
	leftDialog = "@population:medic_greet",
	stopConversation = "false",
	options = {
		{"@population:medic_opt_treat", "opt_treat"},
		{"@population:opt_leave", "opt_leave"},
	}
}
PopulationMedicConvoTemplate:addScreen(population_medic_start)

population_medic_treat = ConvoScreen:new {
	id = "opt_treat",
	leftDialog = "@population:medic_msg_treat",
	stopConversation = "true",
	options = {}
}
PopulationMedicConvoTemplate:addScreen(population_medic_treat)

population_medic_leave = ConvoScreen:new {
	id = "opt_leave",
	leftDialog = "@population:msg_leave",
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
	leftDialog = "@population:performer_greet",
	stopConversation = "false",
	options = {
		{"@population:performer_opt_clear", "opt_clear"},
		{"@population:opt_leave", "opt_leave"},
	}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_start)

population_performer_clear = ConvoScreen:new {
	id = "opt_clear",
	leftDialog = "@population:performer_msg_clear",
	stopConversation = "true",
	options = {}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_clear)

population_performer_leave = ConvoScreen:new {
	id = "opt_leave",
	leftDialog = "@population:msg_leave",
	stopConversation = "true",
	options = {}
}
PopulationPerformerConvoTemplate:addScreen(population_performer_leave)

addConversationTemplate("PopulationPerformerConvoTemplate", PopulationPerformerConvoTemplate)

-- PopulationPerformerConvHandler likewise lives in standing_services.lua
-- -- see the note above PopulationMedicConvoTemplate's addConversationTemplate call.
