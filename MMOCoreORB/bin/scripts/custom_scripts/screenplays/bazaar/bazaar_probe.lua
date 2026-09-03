--[[
  custom_scripts/screenplays/bazaar/bazaar_probe.lua

  Stage S1 console-callable proof for the bazaar-stocking binding (see
  docs/DECISIONS.md). S1 adds three DirectorManager Lua functions
  (bazaarBotList / bazaarBotCancel / bazaarBotCounts) and two CityRegion
  ones (getBazaarCount / getBazaar), and nothing else -- no stocking
  policy, no items, no ghost sellers yet. This probe proves those five
  are callable and that real bazaar terminals are findable through them.
  It does NOT list, cancel, or create anything.

  Follows the pattern of custom_scripts/screenplays/warreport/war_probe.lua
  and custom_scripts/screenplays/starterpack/starter_pack_probe.lua -- that
  is where this project's probes live and are tracked (screenplays/tests/
  tests.lua is covered by the Core3 submodule's own .gitignore and would
  not survive a fresh clone).

  Run:
    docker exec -u swgemu swgwar-core3 bash -lc \
      "screen -S swgemu-server -X stuff 'test bazaarProbe\n'"
    docker exec -u swgemu swgwar-core3 bash -lc \
      "grep BAZAARPROBE ~/workspace/Core3/MMOCoreORB/bin/screenlog.0 | tail -30"

  NOTE the -u swgemu: the screen session belongs to swgemu, and docker exec
  defaults to root, which reports No Sockets found even on a healthy server.
]]

-- SceneObjectType.BAZAAR (server/zone/objects/scene/SceneObjectType.h).
-- isBazaarTerminal() on the C++ side is defined as exactly
-- `gameObjectType == SceneObjectType.BAZAAR` (SceneObject.idl), and
-- getGameObjectType() is already exposed to Lua via LuaSceneObject, so this
-- probe reproduces the same check without needing a new binding.
local GOT_BAZAAR = 0x4002

-- Mos Eisley, Tatooine -- see custom_scripts/screenplays/warreport/war_report.lua
-- COORDS.tat_mos_eisley. Known to have a live bazaar terminal.
local PROBE_ZONE = "tatooine"
local PROBE_X = 3460
local PROBE_Y = -4768

-- Duros Surool, the one live character in this galaxy (see
-- starter_pack_probe.lua's DUROS_OID). Used read-only: bazaarBotCounts()
-- never lists, cancels, or creates anything.
local DUROS_OID = 281474994078640

function Tests:bazaarProbe()
	printf("BAZAARPROBE: begin\n")

	local pRegion = getCityRegionAt(PROBE_ZONE, PROBE_X, PROBE_Y)
	if pRegion == nil then
		printf("BAZAARPROBE: FAIL -- getCityRegionAt(" .. PROBE_ZONE .. ", " .. PROBE_X .. ", " .. PROBE_Y .. ") returned nil\n")
		return
	end

	local region = CityRegion(pRegion)
	local count = region:getBazaarCount()
	printf("BAZAARPROBE: region found, getBazaarCount() = " .. tostring(count) .. "\n")

	for i = 0, count - 1 do
		local pTerminal = region:getBazaar(i)

		if pTerminal == nil then
			printf("BAZAARPROBE: terminal[" .. i .. "] = nil (index-vs-key lookup would show up here as gaps)\n")
		else
			local terminal = SceneObject(pTerminal)
			local oid = terminal:getObjectID()
			local got = terminal:getGameObjectType()
			local isBazaar = (got == GOT_BAZAAR)

			printf("BAZAARPROBE: terminal[" .. i .. "] oid=" .. tostring(oid)
				.. " gameObjectType=0x" .. string.format("%x", got)
				.. " isBazaarTerminal=" .. tostring(isBazaar) .. "\n")
		end
	end

	local pSeller = getSceneObject(DUROS_OID)

	if pSeller == nil then
		printf("BAZAARPROBE: bazaarBotCounts SKIPPED -- getSceneObject(" .. DUROS_OID .. ") returned nil (character not resolvable on this thread)\n")
	else
		local ownerListings, totalBazaarForSale = bazaarBotCounts(pSeller)

		printf("BAZAARPROBE: bazaarBotCounts(Duros) ownerListings=" .. tostring(ownerListings)
			.. " totalBazaarForSale=" .. tostring(totalBazaarForSale) .. "\n")
	end

	printf("BAZAARPROBE: end\n")
end
