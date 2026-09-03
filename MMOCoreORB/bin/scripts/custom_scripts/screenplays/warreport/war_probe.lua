--[[
  custom_scripts/screenplays/warreport/war_probe.lua

  Console-callable proof that the spawn bridge is loaded AND resolving
  templates from the war state, rather than falling through to stock GCW.

  WHY IT LIVES HERE AND NOT IN screenplays/tests/tests.lua: that path is
  covered by the Core3 submodule s own .gitignore (bin/scripts/screenplays/tests),
  so a probe added there is untracked and would not survive a fresh clone --
  it would silently not exist for the next person. Tests is a plain global
  table, and custom_scripts loads after tests.lua defines it, so attaching
  the method from here is equivalent at runtime and actually version-controlled.

  WHY IT EXISTS AT ALL: war_hook.lua only printf()s on its ERROR paths, so a
  silent log is ambiguous -- it means either loaded fine or never ran. This
  gives a positive signal, and reports the resolved faction/density/templates
  per city so a wrong answer is visible rather than merely absent.

  Run:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff \x27test warBridgeCheck\n\x27"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep WARBRIDGECHECK ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -12"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports No Sockets found even on a healthy server.
]]

function Tests:warBridgeCheck()
	printf("WARBRIDGECHECK: begin\n")

	if WarBridge == nil then
		printf("WARBRIDGECHECK: FAIL -- WarBridge table is nil; war_hook.lua did not load into this VM\n")
		return
	end
	printf("WARBRIDGECHECK: WarBridge table present\n")

	if WarBridgeTest == nil then
		printf("WARBRIDGECHECK: FAIL -- WarBridgeTest is nil\n")
		return
	end

	-- Did the war state actually load into this VM?
	if WAR_STATE == nil or WAR_STATE.regions == nil then
		printf("WARBRIDGECHECK: FAIL -- WAR_STATE missing or has no .regions; hook falls back to stock GCW\n")
		return
	end
	printf("WARBRIDGECHECK: WAR_STATE loaded, generated_at_tick=" .. tostring(WAR_STATE.generated_at_tick) .. "\n")

	-- The interesting cities are the ones where our faction DISAGREES with
	-- the stock spawn table -- those are the only places a player can SEE
	-- the bridge working. Anchorhead (stock rebel, ours rebel) and Bestine
	-- (stock imperial, ours imperial) are invisible by construction.
	local subjects = {
		"TatooineMosEisleyScreenPlay",
		"TatooineMosEspaScreenPlay",
		"TatooineAnchorheadScreenPlay",
		"TatooineBestineScreenPlay",
		"CorelliaTyrenaScreenPlay",
		"CorelliaCoronetScreenPlay",
		"NabooTheedScreenPlay",
	}

	for i = 1, #subjects do
		local name = subjects[i]
		local okR, region = pcall(function() return WarBridgeTest:describeRegion(name) end)
		local okG, choice = pcall(function() return WarBridgeTest:describeGcwChoice(name) end)
		printf("WARBRIDGECHECK: " .. name
			.. " | " .. (okR and tostring(region) or ("region-ERR " .. tostring(region)))
			.. " | " .. (okG and tostring(choice) or ("gcw-ERR " .. tostring(choice))) .. "\n")
	end

	printf("WARBRIDGECHECK: end\n")
end

--- Force the briefing officers to spawn now.
--
-- reloadscreenplays does NOT re-run a global screenplay start() that already
-- ran at boot (see CLAUDE.md reload section), so editing war_officer.lua and
-- reloading is not enough to make officers appear -- without this you have to
-- restart the whole server, which disconnects every player.
function Tests:warOfficerSpawn()
	printf("WAROFFICERSPAWN: begin\n")

	if WarOfficer == nil then
		printf("WAROFFICERSPAWN: FAIL -- WarOfficer table is nil\n")
		return
	end

	if WarReport == nil then
		printf("WAROFFICERSPAWN: FAIL -- WarReport table is nil\n")
		return
	end

	local st = WarReport.state()
	printf("WAROFFICERSPAWN: war state " .. (st ~= nil and ("loaded, tick=" .. tostring(st.generated_at_tick)) or "NOT READABLE") .. "\n")

	WarOfficer.retriesLeft = 0  -- one shot; do not queue retries from a manual call
	local ok, err = pcall(function() WarOfficer:spawnAll(nil, "") end)
	if not ok then
		printf("WAROFFICERSPAWN: ERROR " .. tostring(err) .. "\n")
	end

	printf("WAROFFICERSPAWN: end\n")
end

--- Force the flip announcer to run now, ignoring the dedup claim.
--
-- reloadscreenplays is lazy per-thread, so after an export there is no
-- guarantee any thread has re-run war_announce.lua yet. This runs it here.
function Tests:warAnnounceRun()
	printf("WARANNOUNCE: begin\n")
	if WarAnnounce == nil then
		printf("WARANNOUNCE: FAIL -- WarAnnounce table is nil\n")
		return
	end
	pcall(function() includeFile("../custom_scripts/war/war_flips.lua") end)
	if WAR_FLIPS == nil then
		printf("WARANNOUNCE: FAIL -- WAR_FLIPS nil after includeFile\n")
		return
	end
	printf("WARANNOUNCE: flips file tick=" .. tostring(WAR_FLIPS.tick)
		.. " count=" .. tostring(WAR_FLIPS.flips and #WAR_FLIPS.flips or 0) .. "\n")
	-- clear the claim so a manual run always announces
	writeSharedMemory(WarAnnounce.CLAIM_KEY, 1)
	pcall(function() WarAnnounce:run() end)
	printf("WARANNOUNCE: end\n")
end

--- Report which WarBridge functions are visible in THIS threads

--- Report which WarBridge functions are visible in THIS thread's Lua VM, and
-- exercise the reskin directly.
--
-- Needed because the flip path silently skipped the reskin: its guard is
-- `WarBridge.reskinRegion ~= nil`, and a guard that fails looks identical to a
-- guard that was never reached.
function Tests:warBridgeFuncs()
	local function ty(v) return type(v) end
	printf("WARBRIDGEFUNCS: WarBridge=" .. ty(WarBridge)
		.. " reskin=" .. ty(WarBridge and WarBridge.reskin)
		.. " reskinRegion=" .. ty(WarBridge and WarBridge.reskinRegion)
		.. " WAR_REGION_MAP=" .. ty(WAR_REGION_MAP)
		.. " spawnMobOverridden=" .. ty(CityScreenPlay and CityScreenPlay._warOriginalSpawnMob)
		.. "\n")

	if WarBridge ~= nil and WarBridge.reskinRegion ~= nil then
		printf("WARBRIDGEFUNCS: calling reskinRegion(tat_anchorhead)\n")
		local ok, err = pcall(function() WarBridge.reskinRegion("tat_anchorhead") end)
		if not ok then
			printf("WARBRIDGEFUNCS: ERROR " .. tostring(err) .. "\n")
		end
	else
		printf("WARBRIDGEFUNCS: reskinRegion NOT visible in this VM\n")
	end
end

--- Stage a battle immediately, instead of waiting for the cycle timer.
--
-- WarBattle:start() schedules the first battle 45s after boot and then every
-- BATTLE_INTERVAL_MS. reloadscreenplays does not re-run a global screenplay's
-- start(), so without this a change to war_battle.lua can only be exercised by
-- restarting the whole server and disconnecting every player.
function Tests:warBattleNow()
	printf("WARBATTLE: begin\n")

	if WarBattle == nil then
		printf("WARBATTLE: FAIL -- WarBattle table is nil\n")
		return
	end

	if WarReport == nil or WarReport.state() == nil then
		printf("WARBATTLE: FAIL -- war state not readable on this thread\n")
		return
	end

	local region, holder, contest = WarBattle:pickRegion()
	printf("WARBATTLE: target=" .. tostring(region)
		.. " holder=" .. tostring(holder)
		.. " contest=" .. tostring(contest) .. "\n")

	local ok, err = pcall(function()
		WarBattle:clear()
		WarBattle:spawnBattle()
	end)
	if not ok then
		printf("WARBATTLE: ERROR " .. tostring(err) .. "\n")
	end

	printf("WARBATTLE: end\n")
end

--- Tear down whatever battle is live.
function Tests:warBattleClear()
	if WarBattle == nil then
		printf("WARBATTLE: WarBattle is nil\n")
		return
	end
	printf("WARBATTLE: cleared " .. tostring(WarBattle:clear()) .. " combatant(s)\n")
end


--- Verification probe for the front-region threshold/cap fix (contest floor
-- dropped from an absolute 25.0 to the same 1.0 war_battle.lua stages at,
-- with the list capped to WarReport.MAX_FRONT_REGIONS instead).
function Tests:warFrontRegions()
	printf("WARFRONTREGIONS: begin\n")

	if WarReport == nil or WarReport.state() == nil then
		printf("WARFRONTREGIONS: FAIL -- war state not readable on this thread\n")
		return
	end

	local front = WarReport.frontRegions()
	printf("WARFRONTREGIONS: count=" .. #front
		.. " cap=" .. tostring(WarReport.MAX_FRONT_REGIONS) .. "\n")
	for i = 1, #front do
		printf("WARFRONTREGIONS: #" .. i .. " " .. tostring(front[i].id)
			.. " contest=" .. tostring(front[i].contest)
			.. " faction=" .. tostring(front[i].faction) .. "\n")
	end

	printf("WARFRONTREGIONS: end\n")
end


--- Renders the ACTUAL player-facing strings at current tick, for the
-- threshold/ladder fix verification (login headline/front-line/region
-- lines, and the bartender rumour) -- not just frontRegions()'s raw list.
function Tests:warFrontRender()
	printf("WARFRONTRENDER: begin\n")

	if WarReport == nil or WarReport.state() == nil then
		printf("WARFRONTRENDER: FAIL -- war state not readable on this thread\n")
		return
	end

	printf("WARFRONTRENDER: headline = " .. tostring(WarReport.headline()) .. "\n")
	printf("WARFRONTRENDER: frontLine = " .. tostring(WarReport.frontLine()) .. "\n")

	local ids = { "nab_moenia", "tat_anchorhead", "tat_mos_eisley", "cor_doaba" }
	for i = 1, #ids do
		printf("WARFRONTRENDER: regionLine(" .. ids[i] .. ") = "
			.. tostring(WarReport.regionLine(ids[i])) .. "\n")
	end

	if WarRumor ~= nil then
		printf("WARFRONTRENDER: bartender line = " .. tostring(WarRumor:line()) .. "\n")
	else
		printf("WARFRONTRENDER: WarRumor table is nil\n")
	end

	printf("WARFRONTRENDER: end\n")
end
