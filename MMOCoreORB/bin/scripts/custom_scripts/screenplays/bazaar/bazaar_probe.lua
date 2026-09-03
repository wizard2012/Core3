--[[
  custom_scripts/screenplays/bazaar/bazaar_probe.lua

  Stage S1 console-callable proof for the bazaar-stocking binding (see
  docs/DECISIONS.md). S1 adds three DirectorManager Lua functions
  (bazaarBotList / bazaarBotCancel / bazaarBotCounts) and two CityRegion
  ones (getBazaarCount / getBazaar), and nothing else -- no stocking
  policy, no items, no ghost sellers yet. This probe proves those five
  are callable and that real bazaar terminals are findable through them.
  It does NOT list, cancel, or create anything.

  Extended post-S1 to also exercise the four latent defects a verifier found
  (out-of-range getBazaar index, nil description, non-player seller, oversized
  price) and prove each is now handled cleanly rather than crashing the
  server or silently mis-behaving. Still does NOT list, cancel, or create
  anything real: every bazaarBotList() call below uses a bogus itemOid (1)
  that fails validation before any listing would be created.

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

	local pFirstTerminal = nil

	for i = 0, count - 1 do
		local pTerminal = region:getBazaar(i)

		if pTerminal == nil then
			printf("BAZAARPROBE: terminal[" .. i .. "] = nil (index-vs-key lookup would show up here as gaps)\n")
		else
			if pFirstTerminal == nil then
				pFirstTerminal = pTerminal
			end

			local terminal = SceneObject(pTerminal)
			local oid = terminal:getObjectID()
			local got = terminal:getGameObjectType()
			local isBazaar = (got == GOT_BAZAAR)

			printf("BAZAARPROBE: terminal[" .. i .. "] oid=" .. tostring(oid)
				.. " gameObjectType=0x" .. string.format("%x", got)
				.. " isBazaarTerminal=" .. tostring(isBazaar) .. "\n")
		end
	end

	-- Defect fix 1: LuaCityRegion::getBazaar had no bounds check -- a bad index used to
	-- throw ArrayIndexOutOfBoundsException uncaught on this console `test` path and
	-- terminate the server. Both calls below must return nil, and this probe reaching
	-- "end" (and the server still answering afterward) is the proof the process survived.
	local pNeg = region:getBazaar(-1)
	printf("BAZAARPROBE: getBazaar(-1) = " .. tostring(pNeg) .. " (expect nil)\n")

	local pOOB = region:getBazaar(9999)
	printf("BAZAARPROBE: getBazaar(9999) = " .. tostring(pOOB) .. " (expect nil)\n")

	local pSeller = getSceneObject(DUROS_OID)

	if pSeller == nil then
		printf("BAZAARPROBE: bazaarBotList/bazaarBotCounts SKIPPED -- getSceneObject(" .. DUROS_OID .. ") returned nil (character not resolvable on this thread)\n")
	else
		local ownerBefore, totalBefore = bazaarBotCounts(pSeller)
		printf("BAZAARPROBE: bazaarBotCounts(Duros) BEFORE ownerListings=" .. tostring(ownerBefore)
			.. " totalBazaarForSale=" .. tostring(totalBefore) .. "\n")

		if pFirstTerminal == nil then
			printf("BAZAARPROBE: bazaarBotList tests SKIPPED -- no live bazaar terminal found\n")
		else
			-- Defect fix 2: a nil description used to segfault (lua_tostring returns NULL,
			-- UnicodeString(const char*) calls strlen on it unconditionally). itemOid=1 is
			-- not a real object, so this never reaches addSaleItem -- it only proves the
			-- nil-description path itself doesn't crash.
			local code1 = bazaarBotList(pSeller, 1, pFirstTerminal, nil, 100)
			printf("BAZAARPROBE: bazaarBotList(nil description, bogus itemOid) = " .. tostring(code1) .. " (expect no crash)\n")

			-- Minor fix: an oversized 64-bit price used to get truncated to a small int
			-- *before* the MAXBAZAARPRICE check, silently passing as a tiny valid price.
			-- Must now be rejected outright as INVALIDSALEPRICE (4).
			local code2 = bazaarBotList(pSeller, 1, pFirstTerminal, "probe", 4294967301)
			printf("BAZAARPROBE: bazaarBotList(oversized price 4294967301) = " .. tostring(code2) .. " (expect 4 = INVALIDSALEPRICE)\n")

			-- Defect fix 3: a non-player seller (e.g. an AiAgent) used to null-deref inside
			-- checkSaleItem (seller->getPlayerObject()->getVendorCount(), and
			-- getPlayerObject() is null for anything that isn't a player creature).
			-- Spawn a disposable NPC purely to exercise this guard, then despawn it.
			local pMobile = spawnMobile(PROBE_ZONE, "womp_rat", 0, PROBE_X, 0, PROBE_Y, 0, 0)

			if pMobile == nil then
				printf("BAZAARPROBE: non-player-seller test SKIPPED -- spawnMobile failed\n")
			else
				local code3 = bazaarBotList(pMobile, 1, pFirstTerminal, "probe", 100)
				printf("BAZAARPROBE: bazaarBotList(non-player seller) = " .. tostring(code3) .. " (expect no crash)\n")

				HelperFuncs:despawnMobileTask(pMobile)
			end
		end

		local ownerAfter, totalAfter = bazaarBotCounts(pSeller)
		printf("BAZAARPROBE: bazaarBotCounts(Duros) AFTER ownerListings=" .. tostring(ownerAfter)
			.. " totalBazaarForSale=" .. tostring(totalAfter) .. "\n")
	end

	printf("BAZAARPROBE: end\n")
end
