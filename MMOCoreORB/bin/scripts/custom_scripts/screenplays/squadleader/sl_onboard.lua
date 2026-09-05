--[[
  custom_scripts/screenplays/squadleader/sl_onboard.lua

  Squad Leader onboarding, owner's ruling (see docs/BACKLOG.md / the
  session that shipped this): every player gets the Squad Leader profession
  for free and picks a GCW faction the first time they are faction-neutral
  -- this server is basically focused on the GCW.

  RULING UPDATED 2026-09-04: the grant is now the FULL tree, not just
  novice. "Everyone is a squad leader" -- all 18 boxes through
  outdoors_squadleader_master, granted on login to new and existing
  characters alike. See the `tree` field for the sync requirement against
  squadLeaderZeroPointSkills.

  WHAT SHIPPED BEFORE THIS FILE (all live already, none of it touched here):
    - SkillManager::forceAwardSkill(skillName, creature, notifyClient) --
      grants a skill skipping the prerequisite walk. Bound at
      LuaSkillManager.cpp:12/:106 as
      LuaSkillManager():forceAwardSkill(pPlayer, skillName) -- confirmed by
      reading the C++ arg order (creature at stack -2, skill name at -1)
      against skillManager:awardSkill(pPlayer, skillName) call sites already
      in this codebase (utils/space_helpers.lua:120,
      trainers/trainerConvHandler.lua:238).
    - The 18 squadLeaderZeroPointSkills entries (managers/skill_manager.lua)
      cost 0 skill points, applied at boot -- so ranking Squad Leader up
      never touches the profession cap.
    - FactionManager::promoteFactionRank(player) -- exists, clamped below
      rank 22, exposed as a DirectorManager Lua global. NOT called from
      here or anywhere else: what earns a promotion is a design question
      the owner has not answered yet.

  WHY THIS IS A LOGIN HOOK, NOT A PlayerCreationManager EDIT: a
  creation-time hook only fires for characters made after it ships, and
  there are already live characters on this server (including the owner's
  own). A login hook covers new and existing characters identically, and
  hasSkill(NOVICE_SKILL) / getFaction() == 0 ARE the idempotency checks --
  no new persisted flag needed, matching the owner's ruling that dismissing
  the faction picker just means being asked again next login.

  WHY A MONKEY-PATCH, AND WHY A SEPARATE STASH FIELD FROM war_login.lua:
  same reasoning as warreport/war_login.lua's own header --
  playerTriggers.lua does `PlayerTriggers = { }` at the top, so every
  reload-lua.sh produces a brand-new table and any stashed closure over the
  old one would go stale. This file chains onto whatever
  PlayerTriggers.playerLoggedIn already is (including war_login.lua's own
  wrap, whichever load order wins) rather than replacing it, and stashes
  the pre-chain function under ITS OWN field, `_slOnboardOriginalLoggedIn`
  -- reusing war_login.lua's field name would make the two wraps fight over
  the same slot on reload and drop one of them.

  WHY DELAYED, NOT IMMEDIATE: same reasoning as war_login.lua -- sending a
  system message or opening a SUI window at the exact instant
  playerLoggedIn fires lands it while the client is still zoning, where SUI
  windows in particular are simply not delivered. Scheduled onto a short
  timer instead, same pattern, different createEvent.

  WHY setFaction()/setFactionStatus() DIRECTLY, NOT THE RECRUITER CONVO:
  recruiterConvoHandler.lua's "accept_join" screen ID is gated behind
  minimumFactionStanding = 200 (recruiterScreenplay.lua), and the owner has
  ruled enlistment here is free -- no standing requirement. This calls
  CreatureObject(pPlayer):setFaction(hash) then :setFactionStatus(1),
  copying recruiterConvoHandler.lua's own "accept_join" branch byte for
  byte, which is the SAME thing handleGoOnLeave/handleGoCovert do to change
  status without going through the standing gate. Faction rank is left
  untouched: the vanilla enlist path never sets factionRank either, so a
  new member sits at the default rank 0 ("recruit"), which is exactly the
  ruled starting rank.

  Faction hash codes are read from recruiterScreenplay:getFactionHashCode()
  at CALL time (not include time), rather than re-declaring the numbers
  here, so this file can never drift from the one place that owns them.
  screenplays/screenplays.lua includes gcw/recruiters/recruiterScreenplay.lua
  (line 74) before custom_scripts/screenplays/screenplays.lua (line 734),
  so recruiterScreenplay is guaranteed to exist by the time a player logs
  in.
]]

SquadLeaderOnboard = ScreenPlay:new {
	screenplayName = "SquadLeaderOnboard",

	-- Every box in the Squad Leader tree, in dependency order: novice, the
	-- four branch lines, then master. The owner's ruling changed from
	-- "everyone gets Squad Leader novice for free" to "everyone IS a Master
	-- Squad Leader", so this is the full grant list rather than one box.
	-- (noviceSkill, which sl_probe.lua reads, is derived from tree[1] below
	-- rather than spelled twice.)
	--
	-- MUST stay in sync with squadLeaderZeroPointSkills
	-- (managers/skill_manager.lua). All 18 names are listed there, which is
	-- what makes the whole tree cost 0 skill points, so granting it never
	-- touches the profession cap. A name added HERE but not THERE would
	-- silently start charging real skill points against that cap -- which is
	-- exactly the per-setting drift trap CLAUDE.md records for
	-- config-local.lua's MantisPass.
	--
	-- forceAwardSkill skips the prerequisite walk, so strict ordering is not
	-- required for correctness; tree order is kept so that if a name ever
	-- stops resolving, the failure is visible at the right place.
	tree = {
		"outdoors_squadleader_novice",
		"outdoors_squadleader_movement_01",
		"outdoors_squadleader_movement_02",
		"outdoors_squadleader_movement_03",
		"outdoors_squadleader_movement_04",
		"outdoors_squadleader_offense_01",
		"outdoors_squadleader_offense_02",
		"outdoors_squadleader_offense_03",
		"outdoors_squadleader_offense_04",
		"outdoors_squadleader_defense_01",
		"outdoors_squadleader_defense_02",
		"outdoors_squadleader_defense_03",
		"outdoors_squadleader_defense_04",
		"outdoors_squadleader_support_01",
		"outdoors_squadleader_support_02",
		"outdoors_squadleader_support_03",
		"outdoors_squadleader_support_04",
		"outdoors_squadleader_master",
	},

	-- Delay before onboarding runs, ms. Same value and same reasoning as
	-- WarReportLogin.reportDelayMs (warreport/war_login.lua): long enough
	-- for the client to finish zoning, short enough to still read as part
	-- of logging in rather than arriving out of nowhere mid-play.
	onboardDelayMs = 10000,
}

-- The novice box, for sl_probe.lua: one spelling, not two that can drift.
SquadLeaderOnboard.noviceSkill = SquadLeaderOnboard.tree[1]

registerScreenPlay("SquadLeaderOnboard", true)

function SquadLeaderOnboard:start()
	-- Nothing to schedule globally; this screenplay exists only as a
	-- dispatch target for the delayed per-player event below and the SUI
	-- callback registered against its name.
end

--- Wrap PlayerTriggers:playerLoggedIn. Idempotent across reloads by the
-- field-on-the-table mechanism war_login.lua documents; see this file's
-- header for why the stash field is distinct from war_login.lua's own.
function SquadLeaderOnboard:install()
	if PlayerTriggers == nil or type(PlayerTriggers) ~= "table" then
		printf("SquadLeaderOnboard: PlayerTriggers is not a table -- onboarding disabled, stock login behaviour unchanged.\n")
		return
	end

	if PlayerTriggers._slOnboardOriginalLoggedIn ~= nil then
		return -- already wrapped in this VM incarnation
	end

	PlayerTriggers._slOnboardOriginalLoggedIn = PlayerTriggers.playerLoggedIn

	PlayerTriggers.playerLoggedIn = function(triggersSelf, pPlayer)
		-- Whatever is already wrapped in (vanilla, or war_login.lua's own
		-- wrap) FIRST and unconditionally -- this hook must never be able
		-- to block login-time behaviour that shipped before it.
		local okOrig = pcall(function()
			if PlayerTriggers._slOnboardOriginalLoggedIn ~= nil then
				PlayerTriggers._slOnboardOriginalLoggedIn(triggersSelf, pPlayer)
			end
		end)
		if not okOrig then
			printf("SquadLeaderOnboard: chained playerLoggedIn raised; onboarding continues.\n")
		end

		if pPlayer == nil then
			return
		end

		pcall(function()
			createEvent(SquadLeaderOnboard.onboardDelayMs, "SquadLeaderOnboard", "onboardPlayer", pPlayer, "")
		end)
	end
end

--- Delayed per-login entry point: grant the skill, then offer the faction
-- picker if still neutral. Split into two pcall'd steps so a failure in
-- one never blocks the other.
function SquadLeaderOnboard:onboardPlayer(pPlayer)
	if pPlayer == nil then
		return
	end

	local okSkill, errSkill = pcall(function()
		SquadLeaderOnboard:grantSquadLeaderSkill(pPlayer)
	end)
	if not okSkill then
		printf("SquadLeaderOnboard: grantSquadLeaderSkill failed: " .. tostring(errSkill) .. "\n")
	end

	local okPicker, errPicker = pcall(function()
		SquadLeaderOnboard:maybeShowFactionPicker(pPlayer)
	end)
	if not okPicker then
		printf("SquadLeaderOnboard: maybeShowFactionPicker failed: " .. tostring(errPicker) .. "\n")
	end
end

--- Grant the ENTIRE Squad Leader tree via forceAwardSkill, skipping any box
-- the player already holds. hasSkill() per box IS the idempotency check --
-- no persisted flag -- so this is safe to run on every login forever, and a
-- player who somehow lost one box gets exactly that box back rather than a
-- redundant re-grant of the other seventeen.
--
-- Deliberately NOT an early return on "has novice": the previous version
-- returned as soon as novice was present, which for every existing character
-- on this server is true. Keeping that check would have made the whole-tree
-- grant a no-op for precisely the players who already logged in once.
function SquadLeaderOnboard:grantSquadLeaderSkill(pPlayer)
	local creature = CreatureObject(pPlayer)
	local skillManager = LuaSkillManager()

	local granted, failed = 0, 0

	for _, skillName in ipairs(SquadLeaderOnboard.tree) do
		if not creature:hasSkill(skillName) then
			if skillManager:forceAwardSkill(pPlayer, skillName) then
				granted = granted + 1
			else
				failed = failed + 1
				printf("SquadLeaderOnboard: forceAwardSkill(" .. skillName .. ") returned false\n")
			end
		end
	end

	if granted > 0 then
		creature:sendSystemMessage("You have been commissioned as a Master Squad Leader. The full profession is yours, and it costs no skill points.")
		printf("SquadLeaderOnboard: granted " .. tostring(granted) .. " Squad Leader box(es)\n")
	end

	if failed > 0 then
		printf("SquadLeaderOnboard: " .. tostring(failed) .. " Squad Leader box(es) FAILED to grant\n")
	end
end

--- Offer the GCW faction picker if the player is currently faction-neutral.
-- getFaction() == 0 IS the "have they chosen" flag -- ruled behaviour: a
-- player who dismisses the picker is simply asked again next login.
function SquadLeaderOnboard:maybeShowFactionPicker(pPlayer)
	local creature = CreatureObject(pPlayer)

	if creature:getFaction() ~= 0 then
		return -- already aligned; never re-prompt
	end

	local suiManager = LuaSuiManager()
	local options = {
		{ "Rebel Alliance", 0 },
		{ "Galactic Empire", 0 },
	}

	-- usingObject is required non-nil by SuiManager::sendListBox but is
	-- otherwise only used for the forceCloseDist proximity check; passing
	-- the player as their own usingObject (distance always 0) means this
	-- picker needs no NPC to anchor to, same as it needs none to fire.
	suiManager:sendListBox(
		pPlayer, pPlayer,
		"Choose a Faction",
		"The Galactic Civil War is the heart of this server. Enlist now as a Squad Leader recruit -- free, no standing required -- or decide later.",
		2, "Decide Later", "", "Enlist",
		"SquadLeaderOnboard", "handleFactionChoice", 0,
		options
	)
end

--- SUI callback for the faction picker. eventIndex 1 is the cancel button
-- ("Decide Later") -- matches recruiterScreenplay:handleSuiPurchase's own
-- cancelPressed = (eventIndex == 1). arg0 is the 0-based selected row.
function SquadLeaderOnboard:handleFactionChoice(pCreature, pSui, eventIndex, arg0)
	if pCreature == nil then
		return
	end

	local cancelPressed = (eventIndex == 1)
	if cancelPressed then
		return -- getFaction() stays 0; asked again next login, as ruled
	end

	local factionName = nil
	if arg0 == 0 then
		factionName = "rebel"
	elseif arg0 == 1 then
		factionName = "imperial"
	else
		return
	end

	local hash = recruiterScreenplay:getFactionHashCode(factionName)
	if hash == nil then
		printf("SquadLeaderOnboard: could not resolve faction hash for " .. tostring(factionName) .. "\n")
		return
	end

	-- Byte-for-byte the same two calls as recruiterConvoHandler.lua's
	-- "accept_join" screen ID, bypassing the standing gate entirely.
	-- factionRank is deliberately left untouched -- see this file's header.
	CreatureObject(pCreature):setFaction(hash)
	CreatureObject(pCreature):setFactionStatus(1)

	CreatureObject(pCreature):sendSystemMessage("You have enlisted with the " .. (factionName == "rebel" and "Rebel Alliance" or "Galactic Empire") .. ". Welcome, recruit.")
end

SquadLeaderOnboard:install()
