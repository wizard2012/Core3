--[[
  war_squad_probe.lua -- server-side proof that B27 slice 1 is actually wired.

  WHAT THIS CAN AND CANNOT PROVE. It proves the module loaded on this thread,
  that the constants are sane, that war_battle.lua's OID key is readable and
  parses, and that spawnActiveArea genuinely returns an area at a real battle
  coordinate. It CANNOT prove a player gets a squad -- that needs isOvert(),
  isInCombat() and a real client, and per CLAUDE.md in-game behaviour is not
  provable server-side. See docs/IN-GAME-TESTS.md.

  It is a probe, not a test suite: it spawns one throwaway active area and
  destroys it again, so it is safe against the live server.
]]

WarSquadProbe = ScreenPlay:new {}

function Tests:warSquadProbe()
	local pass, fail = 0, 0

	local function check(cond, label)
		if cond then
			pass = pass + 1
			printf("WARSQUADPROBE: PASS " .. label .. "\n")
		else
			fail = fail + 1
			printf("WARSQUADPROBE: FAIL " .. label .. "\n")
		end
	end

	printf("WARSQUADPROBE: begin\n")

	-- [1] module loaded on this thread with its documented shape
	check(WarSquad ~= nil, "WarSquad module is loaded")
	if WarSquad == nil then
		printf("WARSQUADPROBE: end -- 0 pass, 1 fail (module missing)\n")
		return
	end

	check(WarSquad.MAX_TROOPS == 6, "MAX_TROOPS is 6 (D23 slice-1 value)")
	check(WarSquad.AREA_RADIUS_M > 0, "AREA_RADIUS_M is positive")
	check(type(WarSquad.attachSite) == "function", "attachSite is callable")
	check(type(WarSquad.release) == "function", "release is callable")
	check(type(WarSquad.claimFor) == "function", "claimFor is callable")

	-- [2] the Lua bindings this slice depends on actually exist. If any of
	-- these is missing the feature fails SILENTLY -- troops simply never
	-- attach and nothing is logged -- so assert them explicitly.
	check(ENTEREDAREA ~= nil, "ENTEREDAREA constant is exposed to Lua")
	check(EXITEDAREA ~= nil, "EXITEDAREA constant is exposed to Lua")
	check(OVERT ~= nil, "OVERT faction-status constant is exposed to Lua")
	check(FACTIONIMPERIAL ~= nil and FACTIONREBEL ~= nil, "faction constants exposed")

	-- [3] war_battle.lua's tracking key is readable and parses. This is the
	-- ONLY source of which NPCs are claimable -- a second copy of that list
	-- is exactly the drift this project keeps getting bitten by.
	check(WarBattle ~= nil and WarBattle.OIDS_KEY ~= nil, "WarBattle.OIDS_KEY is visible")

	local raw = readStringData(WarBattle.OIDS_KEY)
	local staged = 0
	if raw ~= nil and raw ~= "" then
		for token in string.gmatch(raw, "([^,]+)") do
			if tonumber(token) ~= nil then
				staged = staged + 1
			end
		end
	end
	printf("WARSQUADPROBE: " .. tostring(staged) .. " battle NPC(s) currently staged\n")

	-- Resolve one of them, to prove the OIDs are live objects and not stale.
	if staged > 0 then
		local firstOid = nil
		for token in string.gmatch(raw, "([^,]+)") do
			firstOid = tonumber(token)
			if firstOid ~= nil then break end
		end
		local pNpc = firstOid and getSceneObject(firstOid) or nil
		check(pNpc ~= nil, "first staged OID resolves to a live object")
		if pNpc ~= nil then
			local okAgent = pcall(function()
				-- The three calls the slice actually makes. If AiAgent() or
				-- these methods were not bound, this is where it shows.
				local a = AiAgent(pNpc)
				a:storeFollowObject()
				a:restoreFollowObject()
			end)
			check(okAgent, "AiAgent store/restoreFollowObject are callable on a staged NPC")
		end
	else
		printf("WARSQUADPROBE: no staged NPCs right now -- battle cycle gap, not a failure\n")
	end

	-- [4] spawnActiveArea really returns an area at a real battle coordinate.
	local pArea = WarSquad.attachSite("naboo", 4980, -4604)
	check(pArea ~= nil, "attachSite spawned a proximity area at the Moenia site")
	if pArea ~= nil then
		pcall(function() SceneObject(pArea):destroyObjectFromWorld(false) end)
		printf("WARSQUADPROBE: throwaway area destroyed\n")
	end

	printf("WARSQUADPROBE: end -- " .. tostring(pass) .. " pass, " .. tostring(fail) .. " fail\n")
end
