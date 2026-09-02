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
