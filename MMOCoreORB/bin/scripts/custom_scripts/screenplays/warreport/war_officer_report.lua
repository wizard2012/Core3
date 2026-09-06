--[[
  custom_scripts/screenplays/warreport/war_officer_report.lua

  Gap 1 + Gap 2's on-demand surface: a "Report" radial menu option on the
  existing capital briefing officers (war_officer.lua), which answers "how
  do I see my own contribution and where supply stands" as a concrete,
  discoverable, player-initiated action instead of only ambient speech.

  A SIBLING FILE, NOT AN EDIT TO war_officer.lua -- deliberately. That file
  is depended on by this same feature area already (its POSTS table, its
  spawn/respawn lifecycle) and per this project's own established pattern
  (see this directory's other menu-adjacent files, and the "sibling file,
  not a shared-file edit" precedent the task itself calls out), a new
  capability rides alongside it rather than growing it. This file wires
  itself to the SAME spawned officer NPCs by reading the exact shared-
  memory keys war_officer.lua already writes for its own respawn logic
  (writeSharedMemory("warofficer:npc:"..region, oid) in spawnPost) -- it
  spawns nothing of its own.

  THE CORRECTED "RADIALS NEED .stf" BELIEF (state this plainly; it matters
  beyond this file): war_officer.lua's own header argues a radial menu
  cannot be built here because "a radial menu entry is also an .stf label."
  That is false. ObjectMenuResponse.h:93/106/116 (addRadialMenuItem) takes
  `const UnicodeString& text` -- a literal string parameter, not a StringId
  lookup -- and LuaObjectMenuResponse::addRadialMenuItem (line 33) passes a
  plain Lua string straight through with no "@file:key" parsing anywhere in
  that path. This is not a new discovery in the abstract: this exact
  codebase already ships plain-text radial labels today, unrelated to this
  feature -- screenplays/events/buffTerminalMenuComponent.lua's
  addRadialMenuItem(20, 3, "Get Buffs") and addRadialMenuItem(21, 3, "Clear
  Wounds") are literal text, not .stf keys, and multiple other components in
  this same screenplays/ tree mix literal-text and "@..." items in the same
  fillObjectMenuResponse function with no distinction in how the engine
  treats them. war_officer.lua's belief was simply never checked against
  the one call site that would have disproved it. Worth revisiting anywhere
  else in this codebase a feature was scoped down or skipped on the same
  "radials need client string tables" assumption -- population_conversations
  .lua and CLAUDE.md's own Trap 23 already record this same false premise
  having been corrected once before, for conversation options and SUI list
  boxes; this is a third, independent confirmation of the same wrong belief
  recurring for a third UI surface.

  NO C++, NO NEW TEMPLATE: the radial is attached at runtime via
  SceneObject:setObjectMenuComponent("WarOfficerReportMenuComponent") on
  the already-spawned officer object -- the exact mechanism
  screenplays/village/phase3/fs_counterstrike/fs_cs_commander.lua already
  uses on its own spawnMobile()'d NPC ("FsCampCommanderMenuComponent"). The
  component itself is a plain Lua global table with fillObjectMenuResponse
  and handleObjectMenuSelect methods, resolved by name -- no ObjectMenuComponent
  subclass, no .idl change, no mobile/ template edit (which would need
  restart.sh, not reload-lua.sh).

  WHY A POLLING ATTACH LOOP INSTEAD OF HOOKING SPAWN DIRECTLY: this file
  does not call into war_officer.lua's spawnPost/respawnForRegion (that
  would be exactly the "edit the file another feature depends on" this is
  avoiding). setObjectMenuComponent is a property of the live in-memory
  SceneObject, not something that survives that object being destroyed and
  a new one spawned in its place -- and war_officer.lua's own
  respawnForRegion does exactly that whenever a capital changes hands. So
  attachAll() re-scans and re-attaches on an interval, self-healing after
  any respawn with no coupling to when or why one happened. Re-attaching to
  an NPC that already has the component is harmless (it just re-sets the
  same value).

  RELOAD BOUNDARY: this file is screenplay-side (reload-lua.sh territory).
  start() only runs once at boot for a global screenplay (see
  war_officer.lua's own header on this point) so the attach/rescan
  schedule is set up once; but fillObjectMenuResponse and
  handleObjectMenuSelect are looked up BY NAME on the current Lua VM at the
  moment a player actually opens the radial or selects an item, so editing
  their bodies and running reload-lua.sh changes behaviour on the very next
  right-click, with no relogin and no restart.sh needed -- same boundary
  war_contrib_hook.lua documents for its own KILLEDCREATURE handler.
]]

WarOfficerReportMenu = ScreenPlay:new {
	screenplayName = "WarOfficerReportMenu",

	-- First attach attempt fires after WarOfficer's own 20s first spawn
	-- delay (war_officer.lua's spawnDelayMs) so the officers already exist
	-- by the time this runs on a fresh boot.
	ATTACH_DELAY_MS = 25000,

	-- Self-heal interval: re-scan and re-attach so a captured capital's
	-- freshly respawned officer (a NEW SceneObject, per war_officer.lua's
	-- respawnForRegion) picks up the Report radial too, without this file
	-- needing to know when a capture happened.
	RESCAN_INTERVAL_MS = 5 * 60 * 1000,
}

registerScreenPlay("WarOfficerReportMenu", true)

function WarOfficerReportMenu:start()
	createEvent(WarOfficerReportMenu.ATTACH_DELAY_MS, "WarOfficerReportMenu", "attachAll", nil, "")
end

function WarOfficerReportMenu:attachAll(pObject, args)
	local attached = 0

	local ok, err = pcall(function()
		if WarOfficer == nil or WarOfficer.POSTS == nil then
			printf("WarOfficerReportMenu: WarOfficer.POSTS not visible; Report radial disabled this pass.\n")
			return
		end

		for i = 1, #WarOfficer.POSTS do
			local region = WarOfficer.POSTS[i].region
			local oid = readSharedMemory("warofficer:npc:" .. region)
			if oid ~= nil and oid > 0 then
				local pNpc = getSceneObject(oid)
				if pNpc ~= nil then
					SceneObject(pNpc):setObjectMenuComponent("WarOfficerReportMenuComponent")
					attached = attached + 1
				end
			end
		end
	end)

	if not ok then
		printf("WarOfficerReportMenu:attachAll failed, swallowed: " .. tostring(err) .. "\n")
	else
		printf("WarOfficerReportMenu: Report radial attached to " .. attached .. " officer(s)\n")
	end

	createEvent(WarOfficerReportMenu.RESCAN_INTERVAL_MS, "WarOfficerReportMenu", "attachAll", nil, "")
end

WarOfficerReportMenuComponent = {}

function WarOfficerReportMenuComponent:fillObjectMenuResponse(pSceneObject, pMenuResponse, pPlayer)
	if pSceneObject == nil or pPlayer == nil then
		return
	end

	local menuResponse = LuaObjectMenuResponse(pMenuResponse)
	menuResponse:addRadialMenuItem(20, 3, "Report")
end

function WarOfficerReportMenuComponent:handleObjectMenuSelect(pSceneObject, pPlayer, selectedID)
	if pSceneObject == nil or pPlayer == nil then
		return 0
	end

	if selectedID == 20 then
		pcall(function() WarOfficerReportMenuComponent:sendReport(pPlayer, pSceneObject) end)
	end

	return 0
end

--- Sends the requesting player their personal lifetime contribution total
-- (Gap 1) followed by the front-scoped supply overview (Gap 2). Both are
-- plain sendSystemMessage() calls -- see war_report.lua's own header on why
-- that, and not a new UI screen, is the only option here.
--- The officer's own region: the post whose shared-memory NPC id is this
-- officer (war_officer.lua's spawnPost writes warofficer:npc:<region>).
function WarOfficerReportMenuComponent:regionOf(pOfficer)
	if pOfficer == nil or WarOfficer == nil or WarOfficer.POSTS == nil then
		return nil
	end
	local oid = SceneObject(pOfficer):getObjectID()
	for i = 1, #WarOfficer.POSTS do
		local region = WarOfficer.POSTS[i].region
		if readSharedMemory("warofficer:npc:" .. region) == oid then
			return region
		end
	end
	return nil
end

function WarOfficerReportMenuComponent:sendReport(pPlayer, pOfficer)
	local creature = CreatureObject(pPlayer)

	-- Slice 7: the lifetime line comes from the export's standings (the
	-- ledger's own numbers, WarStandings.officerLines below); the game-side
	-- running counter is the fallback for an export without them.
	local st0 = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	if not (st0 ~= nil and type(st0.standings) == "table" and WarStandings ~= nil) then
		local totalText = "0.00"
		if WarContribCounter ~= nil then
			totalText = WarContribCounter:formatTotal(pPlayer)
		end
		creature:sendSystemMessage("Your war contribution (lifetime): " .. totalText .. " points.")
	end
	-- Slice 3 (DESIGN-WAR-V2 4.4): the full report, galaxy-wide, then what
	-- a player can do at this town, with the sim's numbers.
	local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	if WarLines ~= nil and WarLines.report ~= nil and st ~= nil and type(st.factions) == "table" then
		local lines = WarLines.report(st, nil, true)
		for i = 1, #lines do
			creature:sendSystemMessage(lines[i])
		end
		local region = WarOfficerReportMenuComponent:regionOf(pOfficer)
		local acts = (region ~= nil) and WarLines.actions(st, region) or {}
		if #acts > 0 then
			creature:sendSystemMessage("What you can do here:")
			for i = 1, #acts do
				creature:sendSystemMessage("  " .. acts[i])
			end
		end
		-- Slice 7: the standings -- players counted on each side, this
		-- player's place, the top of their side.
		if WarStandings ~= nil and WarStandings.officerLines ~= nil then
			for _, line in ipairs(WarStandings.officerLines(pPlayer, st)) do
				creature:sendSystemMessage(line)
			end
		end
	end

	if WarReport ~= nil and WarReport.supplyOverview ~= nil then
		local lines = WarReport.supplyOverview()
		for i = 1, #lines do
			creature:sendSystemMessage(lines[i])
		end
	end
end
