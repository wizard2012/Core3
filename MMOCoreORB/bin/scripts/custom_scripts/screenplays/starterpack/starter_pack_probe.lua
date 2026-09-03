--[[
  custom_scripts/screenplays/starterpack/starter_pack_probe.lua

  Console-callable proof that StarterPack.grant() actually lands every item
  on a real character, following the pattern in
  custom_scripts/screenplays/warreport/war_probe.lua (that is where this
  project's probes live and are tracked -- screenplays/tests/tests.lua is
  covered by the Core3 submodule's own .gitignore and would not survive a
  fresh clone).

  Prints, per item: attempted, whether it was created, and where it landed
  (inventory / datapad). A silently-failed item shows up as an explicit
  FAIL line with the reason giveItem/giveControlDevice gave -- it never
  shows up as a blank.

  Run:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test starterPackGrantDuros\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep STARTERPACK ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -20"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports No Sockets found even on a healthy server.
]]

-- Duros Surool, the one live character this was built for.
local DUROS_OID = 281474994078640

local function runGrant(oid, force)
	printf("STARTERPACK: begin (oid=" .. tostring(oid) .. ", force=" .. tostring(force) .. ")\n")

	if StarterPack == nil or StarterPack.grant == nil then
		printf("STARTERPACK: FAIL -- StarterPack table/grant() not visible on this thread; starter_pack.lua did not load\n")
		return
	end

	local pPlayer = getSceneObject(oid)
	if pPlayer == nil then
		printf("STARTERPACK: FAIL -- getSceneObject(" .. tostring(oid) .. ") returned nil; character not resolvable on this thread (offline / wrong oid / not spawned in this zone)\n")
		return
	end

	local name = "?"
	local okName, gotName = pcall(function() return SceneObject(pPlayer):getDisplayedName() end)
	if okName then
		name = tostring(gotName)
	end
	printf("STARTERPACK: resolved player oid=" .. tostring(oid) .. " name=" .. name .. "\n")

	local result = StarterPack.grant(pPlayer, force)

	if result == nil then
		printf("STARTERPACK: FAIL -- StarterPack.grant returned nil (pPlayer was nil going in)\n")
		return
	end

	if result.alreadyGranted then
		printf("STARTERPACK: NO-OP -- already granted to this character; pass force=true to re-run\n")
		printf("STARTERPACK: end\n")
		return
	end

	local okCount, failCount = 0, 0
	for i = 1, #result.results do
		local r = result.results[i]
		if r.ok then
			okCount = okCount + 1
			printf("STARTERPACK: OK   " .. r.key .. " (" .. r.label .. ") -> " .. tostring(r.location) .. "\n")
		else
			failCount = failCount + 1
			printf("STARTERPACK: FAIL " .. r.key .. " (" .. r.label .. ") -- " .. tostring(r.error) .. "\n")
		end
	end

	printf("STARTERPACK: summary " .. okCount .. " ok, " .. failCount .. " failed, " .. #result.results .. " total\n")
	printf("STARTERPACK: end\n")
end

--- Grant (or no-op re-confirm) the starter pack to Duros Surool.
function Tests:starterPackGrantDuros()
	runGrant(DUROS_OID, false)
end

--- Force-regrant to Duros Surool, bypassing the idempotency flag. For
-- deliberate re-testing only -- see starter_pack.lua's file header on why
-- a plain re-run is a no-op instead of retrying failed items on its own.
function Tests:starterPackForceRegrantDuros()
	runGrant(DUROS_OID, true)
end

--- Grant to an arbitrary online character by object id, for testing this
-- against characters other than Duros without editing this file.
function Tests:starterPackGrantOid(oidString)
	local oid = tonumber(oidString)
	if oid == nil then
		printf("STARTERPACK: FAIL -- could not parse oid from '" .. tostring(oidString) .. "'\n")
		return
	end
	runGrant(oid, false)
end
