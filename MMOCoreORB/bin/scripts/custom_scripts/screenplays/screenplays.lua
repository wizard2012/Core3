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
includeFile("../custom_scripts/screenplays/population/population_probe.lua")

-- Ambient street life: lines (pure data) first, then tunables, then the
-- screenplay itself, then its console probes. Reads WarBridge/WarReport at
-- CALL time (not include time), so it does not need to load after
-- warreport/war_report.lua below -- see street_life.lua's own header.
includeFile("../custom_scripts/screenplays/population/street_lines.lua")
includeFile("../custom_scripts/screenplays/population/street_config.lua")
includeFile("../custom_scripts/screenplays/population/street_life.lua")
includeFile("../custom_scripts/screenplays/population/street_probe.lua")

-- War report surfaces. Loaded AFTER population so war_bartender.lua chains
-- onto population/bartender_rumor.lua's runScreenHandlers wrapper.
includeFile("../custom_scripts/screenplays/warreport/war_contrib.lua")
-- Must load right after war_contrib.lua: it wraps WarContrib.record, and
-- that wrap must be (re)installed every time war_contrib.lua's own
-- unconditional `function WarContrib.record(...)` re-runs on a reload --
-- see war_contrib_counter.lua's header for why load order here matters.
includeFile("../custom_scripts/screenplays/warreport/war_contrib_counter.lua")
includeFile("../custom_scripts/screenplays/warreport/war_report.lua")
includeFile("../custom_scripts/screenplays/warreport/war_login.lua")
includeFile("../custom_scripts/screenplays/warreport/war_contrib_hook.lua")
includeFile("../custom_scripts/screenplays/warreport/war_officer.lua")
-- Reads WarOfficer.POSTS and the warofficer:npc:<region> shared-memory keys
-- war_officer.lua writes, so it must load after that file.
includeFile("../custom_scripts/screenplays/warreport/war_officer_report.lua")
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
