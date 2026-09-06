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
-- war_voice.lua first: every player-facing war string lives there, and
-- three later modules (tally, presence, announce) read it.
includeFile("../custom_scripts/screenplays/warreport/war_voice.lua")
-- war_lines.lua: the Supply War's line shapes (DESIGN-WAR-V2 section 4), pure,
-- used by war_report/war_map/war_map_pins/war_presence/war_login/war_officer*
-- and war_announce below. Nothing runs at include time.
includeFile("../custom_scripts/screenplays/warreport/war_lines.lua")
-- war_standings.lua: slice 7 -- what the war gives a player back (standings
-- on login and at the officer, the season's pay once, the rank readout).
includeFile("../custom_scripts/screenplays/warreport/war_standings.lua")
includeFile("../custom_scripts/screenplays/warreport/war_contrib.lua")
-- Must load right after war_contrib.lua: it wraps WarContrib.record, and
-- that wrap must be (re)installed every time war_contrib.lua's own
-- unconditional `function WarContrib.record(...)` re-runs on a reload --
-- see war_contrib_counter.lua's header for why load order here matters.
includeFile("../custom_scripts/screenplays/warreport/war_contrib_counter.lua")
-- Same wrap-and-reinstall contract as the counter, same reason to sit
-- right here: see war_tick_tally.lua.
includeFile("../custom_scripts/screenplays/warreport/war_tick_tally.lua")
includeFile("../custom_scripts/screenplays/warreport/war_report.lua")
includeFile("../custom_scripts/screenplays/warreport/war_map.lua")
includeFile("../custom_scripts/screenplays/warreport/war_login.lua")
includeFile("../custom_scripts/screenplays/warreport/war_contrib_hook.lua")
includeFile("../custom_scripts/screenplays/warreport/war_heal.lua")
includeFile("../custom_scripts/screenplays/warreport/war_presence.lua")
-- Courier runs: needs WarReport, WarVoice, WarContrib (all above) at
-- include time; WarDonate (below) only at delivery time.
includeFile("../custom_scripts/screenplays/warreport/war_courier.lua")
includeFile("../custom_scripts/screenplays/warreport/war_squad.lua")
includeFile("../custom_scripts/screenplays/warreport/war_squad_probe.lua")
includeFile("../custom_scripts/screenplays/warreport/war_officer.lua")
-- Reads WarOfficer.POSTS and the warofficer:npc:<region> shared-memory keys
-- war_officer.lua writes, so it must load after that file.
includeFile("../custom_scripts/screenplays/warreport/war_officer_report.lua")
includeFile("../custom_scripts/screenplays/warreport/war_bartender.lua")
includeFile("../custom_scripts/screenplays/warreport/war_announce.lua")
includeFile("../custom_scripts/screenplays/warreport/war_battle.lua")
includeFile("../custom_scripts/screenplays/warreport/war_recruiter.lua")
-- Read-only console probe (Tests:battleOffsetSweep) for the SITE_OVERRIDES
-- candidates in war_battle.lua -- depends on WarBattle/WarReport already
-- being loaded, hence placed after both.
includeFile("../custom_scripts/screenplays/warreport/war_battle_offset_sweep.lua")
-- Independently wraps RecruiterConvoHandler.runScreenHandlers again (own
-- stash field, chains the prior wrap first -- see its own header); load
-- order relative to war_recruiter.lua does not matter for correctness, but
-- follows it here since both touch the same recruiter conversation surface.
includeFile("../custom_scripts/screenplays/warreport/war_donate.lua")
includeFile("../custom_scripts/screenplays/warreport/war_probe.lua")
-- war_mcp_probe.lua: the server-side action channel for tools/swgclient-mcp (B35): test mcpLua.
includeFile("../custom_scripts/screenplays/warreport/war_mcp_probe.lua")
-- war_orders.lua: slice 8 -- orders from the officer. After war_contrib.lua
-- and war_contrib_counter.lua: it wraps WarContrib.record above the counter.
includeFile("../custom_scripts/screenplays/warreport/war_orders.lua")
includeFile("../custom_scripts/screenplays/warreport/war_template_probe.lua")
-- Slice D: a player takes command of a line from its sergeant (radial).
includeFile("../custom_scripts/screenplays/warreport/war_command.lua")
-- Slice E: barrages and flares (visual only).
includeFile("../custom_scripts/screenplays/warreport/war_effects.lua")

-- New-player starter pack (mechanism only; NOT wired into character
-- creation yet -- owner wants to tune contents first, see
-- starter_pack.lua's file header).
includeFile("../custom_scripts/screenplays/starterpack/starter_pack.lua")
includeFile("../custom_scripts/screenplays/starterpack/starter_pack_probe.lua")

-- Bazaar stocking, stage S1 (binding + probe only -- see docs/DECISIONS.md).
includeFile("../custom_scripts/screenplays/bazaar/bazaar_probe.lua")

-- Bazaar stocking, stage S2: the actual stock policy. Config first (also
-- includeFile()s gcw/recruiters/factionPerkData.lua for the deny-list -- see
-- bazaar_config.lua's own header for why that's safe to re-include here),
-- then the screenplay, then its S2 probe. Ghost sellers themselves are stage
-- S3, a human step -- see bazaar_stock.lua's header; this loads and runs
-- fine with zero of the three characters created, it just lists nothing.
includeFile("../custom_scripts/screenplays/bazaar/bazaar_config.lua")
includeFile("../custom_scripts/screenplays/bazaar/bazaar_stock.lua")
includeFile("../custom_scripts/screenplays/bazaar/bazaar_stock_probe.lua")

-- Squad Leader onboarding: free novice Squad Leader skill + GCW faction
-- picker at login (see squadleader/sl_onboard.lua header). Reads
-- recruiterScreenplay's faction hash codes at CALL time, not include time,
-- so it has no ordering dependency on the warreport/* block above -- kept
-- as its own trailing block to stay out of that lane's merge surface.
includeFile("../custom_scripts/screenplays/squadleader/sl_onboard.lua")
includeFile("../custom_scripts/screenplays/squadleader/sl_probe.lua")

-- B21 spawn-placement safety audit (Tests:spawnSafetyAudit). Read-only,
-- console-triggered only -- reads WarReport/city screenplay tables at CALL
-- time, not include time, so it only needs to load after this file's own
-- warreport/ block above, not depend on any other lane. Kept as its own
-- trailing block, out of every other lane's merge surface (see
-- spawnsafety/spawn_safety_probe.lua's own header for what it does).
includeFile("../custom_scripts/screenplays/spawnsafety/spawn_safety_probe.lua")

-- Anchorhead west-outpost navmesh (audit-driven fix, dist=-1 found by
-- Tests.isPointWalkable / spawn_safety_probe.lua for the npc_6/r3_1
-- patrolPoints cluster in screenplays/cities/tatooine_anchorhead.lua --
-- see navmesh/anchorhead_outpost_navmesh.lua's own header for the full
-- writeup). Independent of every other lane; no ordering dependency.
includeFile("../custom_scripts/screenplays/navmesh/anchorhead_outpost_navmesh.lua")
-- Lianorm Swamp: the sim's Rebel capital on Naboo got ground 2026-09-06; its
-- navmesh (same unguarded-start pattern) and the WarLianormOutpost global the
-- region map names. See that file's header.
includeFile("../custom_scripts/screenplays/navmesh/lianorm_outpost_navmesh.lua")

-- Surface 6: the war on the planetary map screen (needs the three
-- LuaSceneObject map bindings in this branch's core3; fails closed without).
includeFile("../custom_scripts/screenplays/warreport/war_map_pins.lua")

-- SimPlayers (docs/DESIGN-SIMPLAYERS.md): Erenshor-style NPC "players".
-- After every war module and population/ (they read WarReport, WarBattle,
-- WarVoice and POPULATION_CANTINAS); config before voice before behaviour.
includeFile("../custom_scripts/screenplays/simplayers/sim_config.lua")
includeFile("../custom_scripts/screenplays/simplayers/sim_voice.lua")
includeFile("../custom_scripts/screenplays/simplayers/sim_players.lua")
includeFile("../custom_scripts/screenplays/simplayers/sim_probe.lua")
