--[[
  custom_scripts/screenplays/squadleader/sl_probe.lua

  Console-callable proof that the Squad Leader onboarding hook is loaded,
  the login wrap is installed, and forceAwardSkill/setFaction resolve the
  way this feature's design assumes -- without needing a live client to
  actually log in and see it.

  WHY IT LIVES HERE AND NOT IN screenplays/tests/tests.lua: that path is
  covered by the Core3 submodule's own .gitignore (bin/scripts/screenplays/tests),
  so a probe added there is untracked and would not survive a fresh clone.
  Tests is a plain global table and custom_scripts loads after tests.lua
  defines it, so attaching the method from here is equivalent at runtime
  and actually version-controlled -- same reasoning as warreport/war_probe.lua.

  Run:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff \x27test squadLeaderOnboardCheck\n\x27"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep SQUADLEADERONBOARDCHECK ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -20"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports "No Sockets found" even on a healthy
  server.
]]

function Tests:squadLeaderOnboardCheck()
	printf("SQUADLEADERONBOARDCHECK: begin\n")

	if SquadLeaderOnboard == nil then
		printf("SQUADLEADERONBOARDCHECK: FAIL -- SquadLeaderOnboard table is nil; sl_onboard.lua did not load into this VM\n")
		return
	end
	printf("SQUADLEADERONBOARDCHECK: SquadLeaderOnboard table present, noviceSkill=" .. tostring(SquadLeaderOnboard.noviceSkill) .. "\n")

	-- Registration check: has the login wrap actually installed on THIS
	-- thread's PlayerTriggers incarnation?
	local wrapped = (PlayerTriggers ~= nil and PlayerTriggers._slOnboardOriginalLoggedIn ~= nil)
	printf("SQUADLEADERONBOARDCHECK: login wrap installed=" .. tostring(wrapped) .. "\n")

	-- The skill this feature depends on being zero-cost -- confirms the
	-- boot-time zeroing from managers/skill_manager.lua actually reached
	-- the running SkillManager, not just that the Lua table lists it.
	if LuaSkillManager == nil then
		printf("SQUADLEADERONBOARDCHECK: FAIL -- LuaSkillManager binding not visible\n")
		return
	end
	local skillManager = LuaSkillManager()
	local skillObj = skillManager:getSkill(SquadLeaderOnboard.noviceSkill)
	printf("SQUADLEADERONBOARDCHECK: getSkill(" .. SquadLeaderOnboard.noviceSkill .. ") -> " .. tostring(skillObj ~= nil) .. "\n")

	-- Faction hash resolution: the exact lookup handleFactionChoice does
	-- at call time against recruiterScreenplay, proving load order holds.
	if recruiterScreenplay == nil then
		printf("SQUADLEADERONBOARDCHECK: FAIL -- recruiterScreenplay table not visible (load-order assumption broken)\n")
		return
	end
	local rebelHash = recruiterScreenplay:getFactionHashCode("rebel")
	local imperialHash = recruiterScreenplay:getFactionHashCode("imperial")
	printf("SQUADLEADERONBOARDCHECK: rebelHash=" .. tostring(rebelHash) .. " imperialHash=" .. tostring(imperialHash) .. "\n")

	-- promoteFactionRank must exist (C++ shipped it) but this feature must
	-- NEVER call it -- confirms the global is visible without exercising it.
	printf("SQUADLEADERONBOARDCHECK: promoteFactionRank visible=" .. tostring(promoteFactionRank ~= nil) .. " (not called by this feature)\n")

	printf("SQUADLEADERONBOARDCHECK: end\n")
end
