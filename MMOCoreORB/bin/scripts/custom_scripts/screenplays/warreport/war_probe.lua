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


--- Proof that the combat-contribution hook (war_contrib_hook.lua) is
-- loaded, its login wrap is installed, and region attribution resolves
-- real war-region coordinates correctly -- WITHOUT touching the production
-- spool (log/warcontrib/) or requiring a live player to actually kill
-- anything. Redirects WarContrib.SPOOL_DIR to a scratch path for the
-- duration of the check, calls WarContrib.record() directly with
-- synthetic-but-valid arguments (the same call onKilledCreature makes),
-- reads the line back, then restores SPOOL_DIR and deletes the scratch
-- file so nothing is left behind.
--
-- Run:
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "screen -S swgemu-server -X stuff \x27test warContribHookCheck\n\x27"
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "grep WARCONTRIBHOOKCHECK ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -20"
function Tests:warContribHookCheck()
	printf("WARCONTRIBHOOKCHECK: begin\n")

	if WarContribHook == nil then
		printf("WARCONTRIBHOOKCHECK: FAIL -- WarContribHook table is nil; war_contrib_hook.lua did not load into this VM\n")
		return
	end
	printf("WARCONTRIBHOOKCHECK: WarContribHook table present\n")

	if WarContrib == nil or WarContrib.record == nil then
		printf("WARCONTRIBHOOKCHECK: FAIL -- WarContrib.record not visible on this thread\n")
		return
	end

	if WarReport == nil or WarReport.regionAt == nil then
		printf("WARCONTRIBHOOKCHECK: FAIL -- WarReport.regionAt not visible on this thread\n")
		return
	end

	-- Registration check: has the login wrap actually installed?
	local wrapped = (PlayerTriggers ~= nil and PlayerTriggers._warContribOriginalLoggedIn ~= nil)
	printf("WARCONTRIBHOOKCHECK: login wrap installed=" .. tostring(wrapped) .. "\n")

	-- Region geometry check: Mos Eisley's own town-centre coordinate must
	-- resolve to tat_mos_eisley, and a point far out in open desert must
	-- resolve to nil (no guessing).
	local centre = WarReport.COORDS.tat_mos_eisley
	local inTown = WarReport.regionAt("tatooine", centre[1], centre[2])
	local farAway = WarReport.regionAt("tatooine", centre[1] + 50000, centre[2] + 50000)
	printf("WARCONTRIBHOOKCHECK: regionAt(town centre)=" .. tostring(inTown)
		.. " regionAt(open desert)=" .. tostring(farAway) .. "\n")

	-- Spool write check, redirected to a scratch path -- NEVER the
	-- production spool (log/warcontrib/), which the hourly cron flushes
	-- into the live ledger.
	local realSpoolDir = WarContrib.SPOOL_DIR
	local scratchDir = "log/warcontrib_probe_scratch"
	WarContrib.SPOOL_DIR = scratchDir

	local recorded, reason = WarContrib.record("imperial", "tat_mos_eisley", "npc_kill_faction", WarContribHook.NPC_KILL_POINTS, 123456789)
	printf("WARCONTRIBHOOKCHECK: WarContrib.record(npc_kill_faction) recorded=" .. tostring(recorded) .. " reason=" .. tostring(reason) .. "\n")

	local recorded2, reason2 = WarContrib.record("rebel", "tat_mos_eisley", "pvp_kill", WarContribHook.PVP_KILL_POINTS, 987654321)
	printf("WARCONTRIBHOOKCHECK: WarContrib.record(pvp_kill) recorded=" .. tostring(recorded2) .. " reason=" .. tostring(reason2) .. "\n")

	-- Read back whatever bucket file(s) landed in the scratch dir, so the
	-- exact written line is visible in screenlog.0 for eyeballing.
	local handle = io.popen("ls " .. scratchDir .. "/*.csv 2>/dev/null")
	if handle ~= nil then
		for path in handle:lines() do
			local fh = io.open(path, "r")
			if fh ~= nil then
				for line in fh:lines() do
					printf("WARCONTRIBHOOKCHECK: scratch line: " .. line .. "\n")
				end
				fh:close()
			end
		end
		handle:close()
	end

	-- Clean up the scratch spool so repeat runs of this probe don't
	-- accumulate files, and restore SPOOL_DIR unconditionally.
	os.execute("rm -rf " .. scratchDir)
	WarContrib.SPOOL_DIR = realSpoolDir

	printf("WARCONTRIBHOOKCHECK: end\n")
end


--- Proof that the materiel-donation writer (war_donate.lua) is loaded, its
-- recruiter conversation wrap is installed, its faction-perk exclusion set
-- built successfully, and that WarContrib.VALID_SOURCES now accepts
-- "materiel_donation" end to end -- WITHOUT touching the production spool
-- (log/warcontrib/) and without requiring a live player to hand anything
-- over. Same scratch-SPOOL_DIR technique as warContribHookCheck above.
--
-- Run:
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "screen -S swgemu-server -X stuff \x27test warDonateCheck\n\x27"
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "grep WARDONATECHECK ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -20"
function Tests:warDonateCheck()
	printf("WARDONATECHECK: begin\n")

	if WarDonate == nil then
		printf("WARDONATECHECK: FAIL -- WarDonate table is nil; war_donate.lua did not load into this VM\n")
		return
	end
	printf("WARDONATECHECK: WarDonate table present\n")

	if WarContrib == nil or WarContrib.record == nil then
		printf("WARDONATECHECK: FAIL -- WarContrib.record not visible on this thread\n")
		return
	end

	if WarContrib.VALID_SOURCES == nil or WarContrib.VALID_SOURCES.materiel_donation ~= true then
		printf("WARDONATECHECK: FAIL -- materiel_donation is not in WarContrib.VALID_SOURCES\n")
		return
	end
	printf("WARDONATECHECK: materiel_donation is a valid WarContrib source\n")

	-- Recruiter conversation wrap check.
	local wrapped = (RecruiterConvoHandler ~= nil and RecruiterConvoHandler._warDonateOriginalRSH ~= nil)
	printf("WARDONATECHECK: recruiter conversation wrap installed=" .. tostring(wrapped) .. "\n")

	-- Real-screen check: donate_review/donate_execute must actually exist
	-- in BOTH recruiter conv templates (mobile/conversations/recruiter/
	-- {rebel,imperial}_recruiter_conv.lua) -- this is what replaced the
	-- earlier self-linked-screen workaround, so a restart that did not pick
	-- up those two files would otherwise fail silently the first time a
	-- player actually tried to donate. Best-effort: these are plain Lua
	-- globals set by mobile/ at boot, so absence on THIS thread is
	-- reported, not treated as a hard failure, in case this particular
	-- thread never loaded those files into its own VM.
	local function hasScreen(template, screenId)
		if template == nil or template.screens == nil then
			return nil
		end
		for i = 1, #template.screens do
			if template.screens[i] ~= nil and template.screens[i].id == screenId then
				return true
			end
		end
		return false
	end

	if rebelRecruiterConvoTemplate == nil then
		printf("WARDONATECHECK: rebelRecruiterConvoTemplate not visible on this thread (inconclusive)\n")
	else
		printf("WARDONATECHECK: rebel donate_review present=" .. tostring(hasScreen(rebelRecruiterConvoTemplate, "donate_review"))
			.. " donate_execute present=" .. tostring(hasScreen(rebelRecruiterConvoTemplate, "donate_execute")) .. "\n")
	end

	if imperialRecruiterConvoTemplate == nil then
		printf("WARDONATECHECK: imperialRecruiterConvoTemplate not visible on this thread (inconclusive)\n")
	else
		printf("WARDONATECHECK: imperial donate_review present=" .. tostring(hasScreen(imperialRecruiterConvoTemplate, "donate_review"))
			.. " donate_execute present=" .. tostring(hasScreen(imperialRecruiterConvoTemplate, "donate_execute")) .. "\n")
	end

	-- Faction-perk exclusion set built from the live factionPerkData tables.
	local forbidden = WarDonate:forbiddenTemplates()
	local count = 0
	for _ in pairs(forbidden) do count = count + 1 end
	printf("WARDONATECHECK: forbidden faction-perk templates loaded=" .. tostring(count) .. "\n")

	local knownPerkTemplate = "object/tangible/wearables/armor/marine/armor_marine_backpack.iff"
	printf("WARDONATECHECK: known rebel perk template rejected=" .. tostring(forbidden[knownPerkTemplate] == true) .. "\n")

	-- Region geometry reuse check -- same WarReport.regionAt call
	-- war_contrib_hook.lua already proves; re-checked here because
	-- war_donate.lua's confirmDonation depends on it independently.
	if WarReport == nil or WarReport.regionAt == nil or WarReport.COORDS == nil then
		printf("WARDONATECHECK: FAIL -- WarReport.regionAt/COORDS not visible on this thread\n")
		return
	end
	local centre = WarReport.COORDS.tat_mos_eisley
	local inTown = WarReport.regionAt("tatooine", centre[1], centre[2])
	printf("WARDONATECHECK: regionAt(town centre)=" .. tostring(inTown) .. "\n")

	-- Spool write check, redirected to a scratch path -- NEVER the
	-- production spool.
	local realSpoolDir = WarContrib.SPOOL_DIR
	local scratchDir = "log/warcontrib_donate_probe_scratch"
	WarContrib.SPOOL_DIR = scratchDir

	local recorded, reason = WarContrib.record("rebel", "tat_mos_eisley", "materiel_donation", 7.5, 555555555)
	printf("WARDONATECHECK: WarContrib.record(materiel_donation) recorded=" .. tostring(recorded) .. " reason=" .. tostring(reason) .. "\n")

	local handle = io.popen("ls " .. scratchDir .. "/*.csv 2>/dev/null")
	if handle ~= nil then
		for path in handle:lines() do
			local fh = io.open(path, "r")
			if fh ~= nil then
				for line in fh:lines() do
					printf("WARDONATECHECK: scratch line: " .. line .. "\n")
				end
				fh:close()
			end
		end
		handle:close()
	end

	os.execute("rm -rf " .. scratchDir)
	WarContrib.SPOOL_DIR = realSpoolDir

	printf("WARDONATECHECK: end\n")
end


--- Console-callable proof of what warreport/war_map.lua WOULD draw, without
-- a game client and without touching any real player's waypoints. The
-- console `test <function>` command (ServerCore.cpp) takes the whole
-- remainder of the line as a zero-argument Lua function name -- there is no
-- way to pass a planet as a separate argument -- so this loops over every
-- planet WarReport knows about and prints each city's label/colour for all
-- of them; scroll to the planet you want.
--
-- Run:
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "screen -S swgemu-server -X stuff \x27test warMapProbe\n\x27"
--   docker exec -u swgemu swgwar-core3 bash -lc \
--     "grep WARMAPPROBE ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -40"
function Tests:warMapProbe()
	printf("WARMAPPROBE: begin\n")

	if WarMap == nil then
		printf("WARMAPPROBE: FAIL -- WarMap table is nil; war_map.lua did not load into this VM\n")
		return
	end
	if WarReport == nil or WarReport.state() == nil then
		printf("WARMAPPROBE: FAIL -- war state not readable on this thread\n")
		return
	end

	printf("WARMAPPROBE: specialTypeID=" .. tostring(WarMap.SPECIAL_TYPE_ID)
		.. " refreshIntervalMs=" .. tostring(WarMap.REFRESH_INTERVAL_MS) .. "\n")

	local colorNames = {
		[WAYPOINT_WHITE] = "WHITE", [WAYPOINT_BLUE] = "BLUE",
		[WAYPOINT_GREEN] = "GREEN", [WAYPOINT_ORANGE] = "ORANGE",
		[WAYPOINT_YELLOW] = "YELLOW", [WAYPOINT_PURPLE] = "PURPLE",
	}

	local st = WarReport.state()
	local ids = WarReport.regionIds()
	local planets = { "tatooine", "corellia", "naboo" }

	for p = 1, #planets do
		local planetName = planets[p]
		printf("WARMAPPROBE: -- planet " .. planetName
			.. " signature=" .. tostring(WarMap:signatureFor(planetName)) .. "\n")

		for i = 1, #ids do
			local id = ids[i]
			if WarReport.PLANET_OF[id] == planetName then
				local region = st.regions[id]
				local coords = WarReport.COORDS[id]
				if region ~= nil and coords ~= nil then
					local label = WarMap:labelFor(id, region)
					local color = WarMap:colorFor(region)
					printf("WARMAPPROBE: " .. id
						.. " coords=(" .. tostring(coords[1]) .. "," .. tostring(coords[2]) .. ")"
						.. " color=" .. tostring(colorNames[color] or color)
						.. " label=\"" .. label .. "\"\n")
				else
					printf("WARMAPPROBE: " .. id .. " -- missing region or coords, skipped (would not draw)\n")
				end
			end
		end
	end

	printf("WARMAPPROBE: end\n")
end

--- Are the war NPCs actually fighting? Per site (region:site) from
-- war_battle's roster: bodies that resolve, how many are in combat, how
-- many have taken damage, how many are dead. A site where nobody is in
-- combat and nobody is hurt after ten minutes is a standoff, not a battle.
function Tests:warSiteHealthCheck()
	printf("WARSITEHEALTH: begin\n")
	local raw = (WarBattle ~= nil and WarBattle.ROSTER_KEY ~= nil) and readStringData(WarBattle.ROSTER_KEY) or nil
	if raw == nil or raw == "" then
		printf("WARSITEHEALTH: no roster\n")
		return
	end
	local sites = {}
	for rec in string.gmatch(raw, "([^;]+)") do
		local oid, region, site, fac = string.match(rec, "^(%d+)|([%w_]+)|([%w_]+)|([%w_]+)")
		if oid ~= nil then
			local key = region .. ":" .. site
			local s = sites[key] or { total = 0, alive = 0, combat = 0, hurt = 0, dead = 0, byFaction = {} }
			sites[key] = s
			s.total = s.total + 1
			local p = getSceneObject(tonumber(oid))
			if p ~= nil then
				local cre = CreatureObject(p)
				local ok, isDead = pcall(function() return cre:isDead() end)
				if ok and isDead then
					s.dead = s.dead + 1
				else
					s.alive = s.alive + 1
					s.byFaction[fac] = (s.byFaction[fac] or 0) + 1
					local okc, inCombat = pcall(function() return cre:isInCombat() end)
					if okc and inCombat then s.combat = s.combat + 1 end
					local okh, cur, max = pcall(function() return cre:getHAM(HEALTH), cre:getMaxHAM(HEALTH) end)
					if okh and cur ~= nil and max ~= nil and cur < max then s.hurt = s.hurt + 1 end
				end
			end
		end
	end
	local keys = {}
	for k, _ in pairs(sites) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local s = sites[k]
		local fparts = {}
		for f, n in pairs(s.byFaction) do fparts[#fparts + 1] = f .. "=" .. n end
		table.sort(fparts)
		printf(string.format("WARSITEHEALTH: %-22s tracked=%d alive=%d dead=%d inCombat=%d hurt=%d (%s)\n",
			k, s.total, s.alive, s.dead, s.combat, s.hurt, table.concat(fparts, ",")))
	end
	printf("WARSITEHEALTH: end\n")
end

--- Where are the two sides of each site standing, relative to the site
-- origin stored in the roster? Attackers start APPROACH_DISTANCE_M (120)
-- out; if they are still ~120 m out ten minutes later they never advanced,
-- which is a standoff, not a battle. Prints per site and faction: alive,
-- min/avg/max distance to the origin, how many are in combat, how many
-- have a follow target.
function Tests:warSiteDistanceCheck()
	printf("WARSITEDIST: begin\n")
	local raw = (WarBattle ~= nil and WarBattle.ROSTER_KEY ~= nil) and readStringData(WarBattle.ROSTER_KEY) or nil
	if raw == nil or raw == "" then
		printf("WARSITEDIST: no roster\n")
		return
	end
	local sites = {}
	for rec in string.gmatch(raw, "([^;]+)") do
		local oid, region, site, fac, ox, oy = string.match(rec, "^(%d+)|([%w_]+)|([%w_]+)|([%w_]+)|([%-%d%.]*)|([%-%d%.]*)")
		if oid ~= nil then
			local key = region .. ":" .. site
			local s = sites[key] or { ox = tonumber(ox), oy = tonumber(oy), f = {} }
			sites[key] = s
			local fs = s.f[fac] or { n = 0, min = 1e9, max = 0, sum = 0, combat = 0, following = 0 }
			s.f[fac] = fs
			local p = getSceneObject(tonumber(oid))
			if p ~= nil and s.ox ~= nil and s.oy ~= nil then
				local cre = CreatureObject(p)
				local okd, dead = pcall(function() return cre:isDead() end)
				if not (okd and dead) then
					local so = SceneObject(p)
					local dx, dy = so:getWorldPositionX() - s.ox, so:getWorldPositionY() - s.oy
					local d = math.sqrt(dx * dx + dy * dy)
					fs.n = fs.n + 1
					fs.sum = fs.sum + d
					if d < fs.min then fs.min = d end
					if d > fs.max then fs.max = d end
					local okc, c = pcall(function() return cre:isInCombat() end)
					if okc and c then fs.combat = fs.combat + 1 end
					local okf, fo = pcall(function() return AiAgent(p):getFollowObject() end)
					if okf and fo ~= nil then fs.following = fs.following + 1 end
				end
			end
		end
	end
	local keys = {}
	for k, _ in pairs(sites) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local s = sites[k]
		local facs = {}
		for f, _ in pairs(s.f) do facs[#facs + 1] = f end
		table.sort(facs)
		for _, f in ipairs(facs) do
			local fs = s.f[f]
			if fs.n > 0 then
				printf(string.format("WARSITEDIST: %-20s %-8s alive=%d dist min=%.0f avg=%.0f max=%.0f inCombat=%d following=%d\n",
					k, f, fs.n, fs.min, fs.sum / fs.n, fs.max, fs.combat, fs.following))
			end
		end
	end
	printf("WARSITEDIST: end\n")
end

--- test warReadoutsRender (B33 slice 3): every surface's lines from the
-- live state -- the galaxy report, every pin, the arrival lines and the
-- actions at every front, and the transitions the announcer would send
-- next (a dry run: the snapshot is read, not written).
function Tests:warReadoutsRender()
	printf("WARREADOUTS: begin\n")
	local ok, err = pcall(function()
		local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
		if st == nil or WarLines == nil then
			printf("WARREADOUTS: no war state or no WarLines on this thread\n")
			return
		end
		for _, line in ipairs(WarLines.report(st, nil, true)) do
			printf("WARREADOUTS: report | " .. line .. "\n")
		end
		local ids = {}
		for id, _ in pairs(st.regions) do ids[#ids + 1] = id end
		table.sort(ids)
		for _, id in ipairs(ids) do
			printf("WARREADOUTS: pin | " .. WarLines.pin(st, id) .. "\n")
		end
		for _, fr in ipairs(st.fronts or {}) do
			for _, line in ipairs(WarLines.arrival(st, fr.region)) do
				printf("WARREADOUTS: arrival " .. tostring(fr.region) .. " | " .. line .. "\n")
			end
			for _, line in ipairs(WarLines.actions(st, fr.region)) do
				printf("WARREADOUTS: action " .. tostring(fr.region) .. " | " .. line .. "\n")
			end
		end
		local key = (WarAnnounce ~= nil and WarAnnounce.SNAPSHOT_KEY) or "warannounce:snapshot"
		local last = WarLines.unpackSnapshot(readStringData(key))
		local lines, snap = WarLines.transitions(st, last)
		printf("WARREADOUTS: transitions pending=" .. #lines .. " last=" .. tostring(last ~= nil) .. " snapshot=" .. WarLines.packSnapshot(snap) .. "\n")
		for _, line in ipairs(lines) do
			printf("WARREADOUTS: transition | " .. line .. "\n")
		end
	end)
	if not ok then
		printf("WARREADOUTS: failed: " .. tostring(err) .. "\n")
	end
	printf("WARREADOUTS: end\n")
end

--- test warSitesCheck: how many sites each live front is assaulted at, and
-- where each fresh site would stand (the ring point, or the navmesh point
-- walkableOrigin moves it to). Read-only.
function Tests:warSitesCheck()
	printf("WARSITES: begin\n")
	local ok, err = pcall(function()
		local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
		if st == nil or WarBattle == nil or WarBattle.sitesWanted == nil then
			printf("WARSITES: no war state or no WarBattle.sitesWanted on this thread\n")
			return
		end
		printf("WARSITES: alive combatants=" .. tostring(WarBattle.aliveCombatants()) .. " budget=" .. tostring(WarBattle.TOTAL_NPC_BUDGET) .. "\n")
		-- B43: the street slot, the street fights standing now (from the roster), each front's street origin
		printf("WARSITES: " .. ((WarBattle.STREET_SITE ~= nil and WarBattle.STREET_SITE > WarBattle.MAX_SITES_PER_REGION) and "PASS" or "FAIL")
			.. " the street slot sits above the fresh-site range (" .. tostring(WarBattle.STREET_SITE) .. " > " .. tostring(WarBattle.MAX_SITES_PER_REGION) .. ")\n")
		local streets = {}
		local raw = readStringData(WarBattle.ROSTER_KEY) or ""
		for rec in string.gmatch(raw, "[^;]+") do
			local f = {}
			for field in string.gmatch(rec .. "|", "([^|]*)|") do f[#f + 1] = field end
			if f[3] == tostring(WarBattle.STREET_SITE) then
				local k = tostring(f[2]) .. " " .. tostring(f[4])
				streets[k] = (streets[k] or 0) + 1
			end
		end
		local anyStreets = false
		for k, n in pairs(streets) do
			anyStreets = true
			printf("WARSITES: streets | " .. k .. " x" .. tostring(n) .. "\n")
		end
		if not anyStreets then
			printf("WARSITES: streets | none standing\n")
		end
		for _, f in ipairs(WarBattle.fronts()) do
			local coords = WarReport.COORDS[f.id]
			local zone = WarReport.PLANET_OF[f.id]
			if coords ~= nil and zone ~= nil and WarBattle.streetOrigin ~= nil then
				local sx, sy = WarBattle.streetOrigin(zone, coords, f.id)
				printf(string.format("WARSITES: streets origin %s -> (%.0f, %.0f)%s\n", tostring(f.id), sx, sy,
					(math.abs(sx - coords[1]) > 0.5 or math.abs(sy - coords[2]) > 0.5) and " (moved off the centre)" or ""))
			end
		end
		printf("WARSITES: " .. ((WarBattle.streetFightFollows ~= nil and WarBattle.streetFightFollows("__none__", "rebel", "1") == false) and "PASS" or "FAIL")
			.. " no street fight for an unknown region\n")
		printf("WARSITES: streets note | " .. tostring(WarVoice ~= nil and WarVoice.streetsNote ~= nil and WarVoice.streetsNote("rebel", "Theed") or "none") .. "\n")
		printf("WARSITES: streets broadcast | " .. tostring(WarVoice ~= nil and WarVoice.streetsBroadcast ~= nil and WarVoice.streetsBroadcast("imperial", "Anchorhead") or "none")
			.. " (once per " .. tostring((WarBattle.STREETS_BROADCAST_MS or 0) // 60000) .. " min per town)\n")
		for _, f in ipairs(WarBattle.fronts()) do
			local by = readStringData("warbattle:streets:" .. tostring(f.id))
			if by ~= nil and by ~= "" then
				printf("WARSITES: streets key | " .. tostring(f.id) .. " = " .. tostring(by) .. " since " .. tostring(readData("warbattle:streets_ms:" .. tostring(f.id)) or 0) .. "\n")
			end
		end
		printf("WARSITES: " .. ((WarBattle.streetFightFollows ~= nil and WarBattle.streetFightFollows("nab_theed", "rebel", tostring(WarBattle.STREET_SITE)) == false) and "PASS" or "FAIL")
			.. " a street fight does not follow itself\n")
		for _, f in ipairs(WarBattle.fronts()) do
			local r = st.regions[f.id]
			local besieged = r ~= nil and r.is_capital == true and type(r.siege) == "table" and r.siege.active == true
			local wanted = WarBattle.sitesWanted(f, besieged)
			local coords = WarReport.COORDS[f.id]
			local zone = WarReport.PLANET_OF[f.id]
			printf(string.format("WARSITES: %s intensity=%.2f offensive=%s besieged=%s -> %d site(s)\n",
				tostring(f.id), tonumber(f.intensity) or 0, tostring(f.offensive), tostring(besieged), wanted))
			if coords ~= nil and zone ~= nil then
				for s = 1, wanted do
					local rx, ry = WarBattle.siteOrigin(coords, f.id, s, wanted, s == 1)
					local wx, wy = WarBattle.walkableOrigin(zone, coords, f.id, s, wanted, s == 1)
					local moved = (math.abs(rx - wx) > 0.5 or math.abs(ry - wy) > 0.5)
					printf(string.format("WARSITES:   site %d ring=(%.0f, %.0f)%s\n", s, rx, ry,
						moved and string.format(" -> moved to (%.0f, %.0f)", wx, wy) or ""))
				end
			end
		end
	end)
	if not ok then
		printf("WARSITES: failed: " .. tostring(err) .. "\n")
	end
	printf("WARSITES: end\n")
end

--- test warStreetsStageNow: AN ACTION, not a check -- stages a street fight
-- at the hottest live front right now (B43), exactly as reconcile() would
-- after an attacking line won an outside site, so the mechanism can be seen
-- without waiting for a win: 2 x STREET_LINE_SIZE bodies in the town, the
-- sergeants' shouts, the held slot 9 that the next staging cycle
-- re-attaches. Skips when a street fight already stands there (the roster
-- has slot 9 records), like the real path.
function Tests:warStreetsStageNow()
	printf("WARSTREETS: begin\n")
	local ok, err = pcall(function()
		local fronts = (WarBattle ~= nil and WarBattle.fronts ~= nil) and WarBattle.fronts() or {}
		if #fronts == 0 or WarBattle.stageStreetFight == nil then
			printf("WARSTREETS: no live front or no stageStreetFight on this thread\n")
			return
		end
		local f = fronts[1]
		local held = {}
		local raw = readStringData(WarBattle.ROSTER_KEY) or ""
		for rec in string.gmatch(raw, "[^;]+") do
			local fields = {}
			for field in string.gmatch(rec .. "|", "([^|]*)|") do fields[#fields + 1] = field end
			if fields[2] == f.id and fields[3] == tostring(WarBattle.STREET_SITE) then
				held[f.id .. ":" .. tostring(WarBattle.STREET_SITE)] = true
			end
		end
		printf("WARSTREETS: front " .. tostring(f.id) .. " attacker=" .. tostring(f.attacker) .. " holder=" .. tostring(f.faction)
			.. " follows=" .. tostring(WarBattle.streetFightFollows(f.id, f.attacker, "1")) .. "\n")
		local cycleNo = readData("warbattle:cycle") or 0
		local n = WarBattle.stageStreetFight(f.id, f.attacker, held, cycleNo)
		printf("WARSTREETS: staged " .. tostring(n) .. " bodies at " .. tostring(f.id) .. "\n")
	end)
	if not ok then
		printf("WARSTREETS: failed: " .. tostring(err) .. "\n")
	end
	printf("WARSTREETS: end\n")
end

--- test warRaidStageNow: AN ACTION, not a check -- spawns one raiding party
-- (B44) of the attacker's side at the town of the hottest front, on a
-- meshed point near the centre, set on nobody (a player's hold order sets
-- them on the player), so the spawn, the roster tracking in the garrison
-- slot and the next reconcile's two-sided garrison can be seen.
function Tests:warRaidStageNow()
	printf("WARRAID: begin\n")
	local ok, err = pcall(function()
		local fronts = (WarBattle ~= nil and WarBattle.fronts ~= nil) and WarBattle.fronts() or {}
		if #fronts == 0 or WarBattle.spawnRaid == nil then
			printf("WARRAID: no live front or no spawnRaid on this thread\n")
			return
		end
		local f = fronts[1]
		local zone, coords = WarReport.PLANET_OF[f.id], WarReport.COORDS[f.id]
		local x, y = WarBattle.streetOrigin(zone, coords, f.id)
		local n = WarBattle.spawnRaid(zone, f.id, f.attacker, x + 20, y + 20, WarOrders and WarOrders.RAID_SIZE or 4, nil)
		printf("WARRAID: " .. tostring(n) .. " " .. tostring(f.attacker) .. " raiders at " .. tostring(f.id) .. " (" .. tostring(math.floor(x + 20)) .. ", " .. tostring(math.floor(y + 20)) .. ")\n")
	end)
	if not ok then
		printf("WARRAID: failed: " .. tostring(err) .. "\n")
	end
	printf("WARRAID: end\n")
end

--- test warRestartNotice: AN ACTION -- the galaxy-wide line the restart rule
-- (owner, 2026-09-07: "anytime, announce first") wants two minutes before a
-- restart. deploy/scripts/restart-announced.sh sends it and waits.
function Tests:warRestartNotice()
	local line = "Server restart in two minutes for a war update. Finish the fight you are in; the war itself keeps going, your standing and your orders are safe."
	local ok = pcall(function() warBroadcast(line) end)
	printf("WARRESTART: notice " .. (ok and "sent" or "FAILED") .. " :: " .. line .. "\n")
end

--- test warFinaleCheck (B56): the commanders of the offensives and the
-- capitals in their last hour, from the live state. Read-only.
function Tests:warFinaleCheck()
	printf("WARFINALE: begin\n")
	local ok, err = pcall(function()
		local st = WarReport.state()
		if st == nil then
			printf("WARFINALE: no war state\n")
			return
		end
		for _, f in ipairs(WarBattle.fronts()) do
			local oid = readData(WarBattle.COMMANDER_KEY_PREFIX .. f.id) or 0
			local lost = readData(WarBattle.COMMANDER_LOST_PREFIX .. f.id) or 0
			printf(string.format("WARFINALE: front %s attacker=%s offensive=%s commander=%s oid=%d fallen=%s\n",
				f.id, tostring(f.attacker), tostring(f.offensive), tostring(WarBattle.commanderName(f.id, f.attacker)), oid, tostring(lost > 0)))
		end
		for id, r in pairs(st.regions) do
			if r.is_capital == true then
				printf(string.format("WARFINALE: capital %s holder=%s falls_in=%s finale=%s | %s\n", id, tostring(r.faction),
					tostring(r.falls_in_ticks), tostring(WarLines.finaleAt(st, id)), tostring(WarLines.finaleLine(st, id))))
			end
		end
		printf("WARFINALE: " .. ((WarBattle.commanderName("nab_theed", "rebel") ~= nil and WarBattle.commanderName("nab_theed", "rebel") == WarBattle.commanderName("nab_theed", "rebel")) and "PASS" or "FAIL") .. " a commander name is stable\n")
		printf("WARFINALE: " .. ((WarBattle.commanderName("nab_theed", "nobody") == nil) and "PASS" or "FAIL") .. " no roster, no name\n")
		local fake = { regions = { x = { is_capital = true, faction = "rebel", falls_in_ticks = 2 } } }
		printf("WARFINALE: " .. ((WarLines.lastStand(fake, "x", "rebel") == true and WarLines.lastStand(fake, "x", "imperial") == false) and "PASS" or "FAIL") .. " the last stand is the holder's\n")
		printf("WARFINALE: " .. ((WarVoice.commanderDown("rebel", "Theed", "Major Teo Ranse")):find("has fallen", 1, true) ~= nil and "PASS" or "FAIL") .. " the commander line\n")
	end)
	if not ok then
		printf("WARFINALE: failed: " .. tostring(err) .. "\n")
	end
	printf("WARFINALE: end\n")
end

--- test warRankTable (B20): the faction rank table through the three
-- read-only bindings, ranks 0..22. Nothing is set on anyone. The row past
-- the end shows the -1 that B20 records as the landmine (rank count 22).
function Tests:warRankTable()
	printf("WARRANKTABLE: begin\n")
	local ok, err = pcall(function()
		for rank = 0, 22 do
			local name = getRankName(rank)
			local cost = getRankCost(rank)
			local cap = getFactionPointsCap(rank)
			printf(string.format("WARRANKTABLE: rank=%d name=%s cost=%s cap=%s\n",
				rank, tostring(name), tostring(cost), tostring(cap)))
		end
	end)
	if not ok then
		printf("WARRANKTABLE: failed: " .. tostring(err) .. "\n")
	end
	printf("WARRANKTABLE: end\n")
end

--- test warSpaceCheck (B61 S1): the sky battle, read-only. Three orbits in
-- the export, the module loaded, a cycle within two intervals, and per
-- orbit the picket's side matching the holder with live hull counts.
function Tests:warSpaceCheck()
	printf("WARSPACE: begin\n")
	local ok, err = pcall(function()
		if WarSpace == nil or WarSpace.runCycle == nil then
			printf("WARSPACE: FAIL the WarSpace module is not loaded\n")
			return
		end
		local st = WarReport.state()
		if st == nil or type(st.orbits) ~= "table" then
			printf("WARSPACE: FAIL no orbits in the war state\n")
			return
		end
		local n = 0
		for _ in pairs(st.orbits) do n = n + 1 end
		printf("WARSPACE: " .. ((n == 3) and "PASS" or "FAIL") .. " three orbits exported (" .. tostring(n) .. ")\n")
		local last = readData(WarSpace.LAST_KEY) or 0
		local age = (last > 0) and (getTimestampMilli() - last) or -1
		printf("WARSPACE: " .. ((age >= 0 and age <= 2 * WarSpace.CYCLE_MS) and "PASS" or "FAIL")
			.. " a cycle ran within two intervals (age " .. tostring(math.floor(age / 1000)) .. " s, cycle "
			.. tostring(readData(WarSpace.CYCLE_KEY) or 0) .. ")\n")
		for _, id in ipairs(WarSpace.orbitIds()) do
			local o = st.orbits[id]
			local cfg = WarSpace.ORBITS[id]
			local pside, palive = WarSpace.sweep(WarSpace.PICKET_KEY .. id)
			local aside, aalive = WarSpace.sweep(WarSpace.ATTACK_KEY .. id)
			local holder = o ~= nil and o.faction or "?"
			local declared = (holder == "imperial" or holder == "rebel")
			local good = (not declared) or (pside == holder and #palive > 0)
			local conv = WarSpace.convoyRecord ~= nil and WarSpace.convoyRecord(id) or nil
			local traffic = (o ~= nil and type(o.traffic) == "table") and (tostring(o.traffic.imperial) .. "/" .. tostring(o.traffic.rebel)) or "none"
			printf(string.format("WARSPACE: %s %s -- holder %s, picket %s x%d, attack %s x%d, front %s, traffic %s, convoy %s, zone %s\n",
				good and "PASS" or "FAIL", id, tostring(holder), tostring(pside), #palive, tostring(aside), #aalive,
				(o ~= nil and type(o.front) == "table") and (tostring(o.front.attacker) .. " " .. tostring(o.front.intensity)) or "none",
				traffic, conv and (conv.side .. " x" .. tostring(#conv.oids) .. ((conv.owner or 0) ~= 0 and " owned" or "")) or "none",
				isZoneEnabled(cfg.zone) and "enabled" or "DISABLED"))
		end
		-- B61 S4: the pilot's orders and the hooks between the two modules
		local priced = WarOrders ~= nil and type(WarOrders.POINTS) == "table" and WarOrders.POINTS.escort ~= nil and WarOrders.POINTS.picket ~= nil
		printf("WARSPACE: " .. (priced and "PASS" or "FAIL") .. " escort and picket orders are priced ("
			.. tostring(priced and WarOrders.POINTS.escort) .. ", " .. tostring(priced and WarOrders.POINTS.picket) .. ")\n")
		local hooks = WarSpace.requestConvoy ~= nil and WarSpace.deliveryTarget ~= nil and WarSpace.deliver ~= nil
			and WarSpace.picketState ~= nil and WarSpace.distanceToFreighter ~= nil
			and WarOrders ~= nil and WarOrders.onConvoyDocked ~= nil and WarOrders.onConvoyLost ~= nil and WarOrders.skyCheck ~= nil
		printf("WARSPACE: " .. (hooks and "PASS" or "FAIL") .. " the S4 hooks are present on this thread\n")
		for _, id in ipairs(WarSpace.orbitIds()) do
			local pside, alive = WarSpace.picketState(id)
			local cfg = WarSpace.ORBITS[id]
			local parts, allFine = {}, true
			for _, sd in ipairs({ "imperial", "rebel" }) do
				local target = WarSpace.deliveryTarget(id, sd, st)
				-- the expected landing, from the export alone: the orbit when held,
				-- else the first port of the sky the side holds, else the orbit
				local expected = id
				if not (st.orbits[id] ~= nil and st.orbits[id].faction == sd) then
					for _, rid in ipairs(cfg.ports or {}) do
						if expected == id and st.regions[rid] ~= nil and st.regions[rid].faction == sd then expected = rid end
					end
				end
				local fine = (target == expected)
				allFine = allFine and fine
				parts[#parts + 1] = sd .. " -> " .. tostring(target) .. (fine and "" or (" (expected " .. tostring(expected) .. ")"))
			end
			local chain = (readData(WarSpace.INTERCEPT_KEY .. id) or 0) == 1
			printf(string.format("WARSPACE: %s %s -- picket %s x%d live now%s; an owned convoy lands: %s\n",
				allFine and "PASS" or "FAIL", id, tostring(pside), alive, chain and " (intercepting)" or "", table.concat(parts, ", ")))
		end
	end)
	if not ok then
		printf("WARSPACE: FAIL error " .. tostring(err) .. "\n")
	end
	printf("WARSPACE: end\n")
end

--- test warGrantSkills (owner's tool): award the skills listed in
-- log/war_grant.txt ("<firstname> <skill>" per line) with their whole
-- prerequisite tree, then rename the file to war_grant.done. The player
-- must be known to the name map (a character that existed at boot).
function Tests:warGrantSkills()
	printf("WARGRANT: begin\n")
	local ok, err = pcall(function()
		local path = "log/war_grant.txt"
		local f = io.open(path, "r")
		if f == nil then
			printf("WARGRANT: nothing to do (" .. path .. " not found)\n")
			return
		end
		local lines = {}
		for line in f:lines() do lines[#lines + 1] = line end
		f:close()
		for _, line in ipairs(lines) do
			local name, skill = string.match(line, "^%s*(%S+)%s+(%S+)%s*$")
			if name ~= nil and skill ~= nil then
				local pPlayer = getPlayerByName(name)
				if pPlayer == nil then
					printf("WARGRANT: FAIL " .. name .. ": no such player\n")
				else
					local had = CreatureObject(pPlayer):hasSkill(skill)
					awardSkill(pPlayer, skill)
					local has = CreatureObject(pPlayer):hasSkill(skill)
					printf("WARGRANT: " .. (has and "PASS" or "FAIL") .. " " .. name .. " " .. skill
						.. (had and " (already had it)" or (has and " (awarded with prerequisites)" or " (awardSkill refused: unknown skill, or the player object is not loaded)")) .. "\n")
					if has then
						pcall(function() CreatureObject(pPlayer):sendSystemMessage("[War] The quartermaster signed off your " .. skill .. ".") end)
					end
				end
			elseif line ~= "" then
				printf("WARGRANT: skipped line: " .. line .. "\n")
			end
		end
		os.rename(path, "log/war_grant.done")
	end)
	if not ok then
		printf("WARGRANT: FAIL error " .. tostring(err) .. "\n")
	end
	printf("WARGRANT: end\n")
end

--- test warSpaceConvoyNow (B61 S4): fly one unowned Rebel convoy over
-- Tatooine now (the export's own kind: no owner, no delivery row), so the
-- convoy path runs with nobody in the zone. Watch screenlog for
-- "convoy launched", then "is in (docked)" or "was lost" within two cycles.
function Tests:warSpaceConvoyNow()
	if WarSpace == nil or WarSpace.requestConvoy == nil then
		printf("WARSPACE: FAIL the WarSpace module (S4) is not loaded\n")
		return
	end
	local ok, got = pcall(WarSpace.requestConvoy, "tat_orbit", "rebel", 0)
	printf("WARSPACE: convoy request over Tatooine (rebel, unowned): " .. tostring(ok and got or got) .. "\n")
	local rec = WarSpace.convoyRecord("tat_orbit")
	if rec ~= nil then
		local pF = getSceneObject(rec.oids[1])
		printf(string.format("WARSPACE: convoy %s x%d owner %s, freighter %s at %s\n", rec.side, #rec.oids, tostring(rec.owner),
			pF and "present" or "MISSING", pF and string.format("%.0f %.0f %.0f", SceneObject(pF):getWorldPositionX(), SceneObject(pF):getWorldPositionZ(), SceneObject(pF):getWorldPositionY()) or "?"))
	end
end

--- test warSpaceCycleNow (B61 S1): run one sky cycle at once (spawns and reports).
function Tests:warSpaceCycleNow()
	if WarSpace == nil or WarSpace.runCycle == nil then
		printf("WARSPACE: FAIL the WarSpace module is not loaded\n")
		return
	end
	local ok, err = pcall(function() WarSpace.runCycle() end)
	printf("WARSPACE: cycle " .. (ok and "ran" or ("failed: " .. tostring(err))) .. "\n")
end

--- test warTravelCheck (B60): the server's holders file (WarTravel.h) agrees
-- with the export, city by city, through the warHolderOf binding. Read-only.
function Tests:warTravelCheck()
	printf("WARTRAVEL: begin\n")
	local ok, err = pcall(function()
		if warHolderOf == nil then
			printf("WARTRAVEL: FAIL the warHolderOf binding is not registered (old binary?)\n")
			return
		end
		local st = WarReport.state()
		if st == nil or type(st.regions) ~= "table" then
			printf("WARTRAVEL: no war state\n")
			return
		end
		-- B61 S3: the sky rows (space_<planet> / orbit) agree with the export's orbits block
		if type(st.orbits) == "table" then
			local okSky, badSky = 0, 0
			for oid, o in pairs(st.orbits) do
				local got = warHolderOf("space_" .. tostring(o.planet), "orbit")
				if got == o.faction then okSky = okSky + 1 else badSky = badSky + 1 end
			end
			printf("WARTRAVEL: " .. ((badSky == 0 and okSky > 0) and "PASS" or "FAIL") .. " sky rows agree for " .. tostring(okSky) .. " of " .. tostring(okSky + badSky) .. " orbits\n")
		end
		local pass, fail = 0, 0
		for rid, c in pairs(WarLines.CITY_OF) do
			local want = st.regions[rid] and st.regions[rid].faction or "?"
			local got = warHolderOf(c.zone, c.city)
			if got == want then
				pass = pass + 1
			else
				fail = fail + 1
				printf("WARTRAVEL: FAIL " .. rid .. " export=" .. tostring(want) .. " server=" .. tostring(got) .. "\n")
			end
		end
		printf("WARTRAVEL: " .. ((fail == 0) and "PASS" or "FAIL") .. " holders agree for " .. pass .. " of " .. (pass + fail) .. " cities\n")
		printf("WARTRAVEL: " .. ((warHolderOf("corellia", "no_such_city") == "") and "PASS" or "FAIL") .. " an unknown city has no holder\n")
	end)
	if not ok then
		printf("WARTRAVEL: failed: " .. tostring(err) .. "\n")
	end
	printf("WARTRAVEL: end\n")
end

--- test warAllCheck: every readout probe in one console command, each in its
-- own pcall so one failing cannot hide the others. Grep WARALL for the
-- summary, then the probe's own marker for its lines.
function Tests:warAllCheck()
	printf("WARALL: begin\n")
	local probes = { "warReadoutsRender", "warStandingsCheck", "warOrdersCheck", "warDigestCheck", "warSquadProbe", "warSitesCheck", "warDeployCheck", "warWindowCheck", "warConvoyCheck", "warGatesCheck", "warAdvanceCheck", "warFinaleCheck", "warTravelCheck", "warSpaceCheck" }
	for _, name in ipairs(probes) do
		local fn = Tests[name]
		if type(fn) ~= "function" then
			printf("WARALL: " .. name .. " -- not defined on this thread\n")
		else
			local ok, err = pcall(fn, Tests)
			printf("WARALL: " .. name .. " -- " .. (ok and "ran" or ("FAILED: " .. tostring(err))) .. "\n")
		end
	end
	printf("WARALL: end\n")
end
