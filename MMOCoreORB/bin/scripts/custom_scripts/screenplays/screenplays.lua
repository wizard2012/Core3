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

-- War report surfaces. Loaded AFTER population so war_bartender.lua chains
-- onto population/bartender_rumor.lua's runScreenHandlers wrapper.
includeFile("../custom_scripts/screenplays/warreport/war_contrib.lua")
includeFile("../custom_scripts/screenplays/warreport/war_report.lua")
includeFile("../custom_scripts/screenplays/warreport/war_login.lua")
includeFile("../custom_scripts/screenplays/warreport/war_contrib_hook.lua")
includeFile("../custom_scripts/screenplays/warreport/war_officer.lua")
includeFile("../custom_scripts/screenplays/warreport/war_bartender.lua")
includeFile("../custom_scripts/screenplays/warreport/war_announce.lua")
includeFile("../custom_scripts/screenplays/warreport/war_battle.lua")
includeFile("../custom_scripts/screenplays/warreport/war_recruiter.lua")
includeFile("../custom_scripts/screenplays/warreport/war_probe.lua")

-- New-player starter pack (mechanism only; NOT wired into character
-- creation yet -- owner wants to tune contents first, see
-- starter_pack.lua's file header).
includeFile("../custom_scripts/screenplays/starterpack/starter_pack.lua")
includeFile("../custom_scripts/screenplays/starterpack/starter_pack_probe.lua")

-- Bazaar stocking, stage S1 (binding + probe only -- see docs/DECISIONS.md).
includeFile("../custom_scripts/screenplays/bazaar/bazaar_probe.lua")
