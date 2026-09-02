includeFile("../custom_scripts/screenplays/war_hook.lua")

-- Phase 1 synthetic population (D15 / docs/DESIGN-POPULATION.md S4.7):
-- config first, then the pure placement function, then the screenplay
-- that spawns/relocates the providers, then the bartender-rumour patch
-- (which needs BartenderConversationHandler already defined, which it is
-- by this point in screenplays.lua's own include chain).
includeFile("../custom_scripts/screenplays/population/population_config.lua")
includeFile("../custom_scripts/screenplays/population/placement.lua")
includeFile("../custom_scripts/screenplays/population/standing_services.lua")
includeFile("../custom_scripts/screenplays/population/bartender_rumor.lua")
