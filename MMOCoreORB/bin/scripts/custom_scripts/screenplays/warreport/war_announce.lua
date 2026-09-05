--[[
  custom_scripts/screenplays/warreport/war_announce.lua

  Surface 4 of 4: when a region changes hands, everyone online hears about it.

  This is the surface that makes the sim's flips legible as EVENTS rather than
  as silent state changes. Territory moving on a map nobody is looking at is
  not a war anyone can feel.

  HOW THE FLIP LIST GETS HERE
  ---------------------------
  bridge/export_war_state.lua diffs the state it is about to deploy against
  the one currently deployed, and writes custom_scripts/war/war_flips.lua
  next to war_state.lua. The diff is taken at exactly the moment the game's
  view of the war changes, so the flip list can never disagree with the state
  the spawn bridge is reading -- they are produced by the same write.

  WHY DEDUPLICATION IS MANDATORY, NOT DEFENSIVE
  --------------------------------------------
  reloadscreenplays does not re-run Lua centrally. Each server thread keeps
  its own Lua VM and re-runs screenplays.lua the next time a screenplay
  function executes on that thread (see CLAUDE.md's reload section). So this
  file's top-level code runs ONCE PER THREAD VM, at unpredictable times. A
  naive broadcast here would fire once per thread -- every player would see
  the same "Bestine has fallen" line several times.

  So the announcement is keyed on the flip file's tick, stored in SHARED
  memory (process-wide, not per-VM). The first VM to reach a new tick claims
  it and broadcasts; every later VM sees the tick already claimed and stays
  silent.

  WHY IT IS SILENT ON THE FIRST RUN AFTER A RESTART
  ------------------------------------------------
  Shared memory does not survive a server restart, so after a restart the
  stored tick is absent while war_flips.lua may still hold the last batch.
  Announcing those would tell players about flips that happened while the
  server was down, possibly hours earlier. Instead, an absent stored tick is
  treated as "adopt the current tick silently" -- the first reload AFTER the
  restart announces normally, and history is not replayed at people.

  BROADCAST MECHANISM: broadcastToGalaxy(nil, message), registered as a Lua
  global at DirectorManager.cpp:546. With a nil creature,
  ChatManagerImplementation::broadcastGalaxy adds NO "[name]" prefix (verified
  in source) and sends the bare string to every online player via
  sendSystemMessage. It takes a plain String, so no .stf entry is needed --
  the same constraint that shaped war_officer.lua and war_bartender.lua.
  There are zero other Lua callers of it in the codebase, so this is the
  first use; it is wrapped in pcall accordingly.
]]

WarAnnounce = WarAnnounce or {}

-- Shared-memory key holding the last tick whose flips have been announced.
WarAnnounce.CLAIM_KEY = "swgwar:announce:lastTick"

--- "Bestine has fallen to the Rebellion." -- past tense, faction-neutral
-- phrasing, no numbers. The detail lives with the officer; this is the
-- headline a player hears while doing something else.
function WarAnnounce:lineFor(flip)
	if flip == nil or flip.region == nil then
		return nil
	end

	local name = WarReport ~= nil and WarReport.regionName(flip.region) or flip.region
	local toFaction = string.lower(tostring(flip.to or ""))
	local captor = WarReport ~= nil and WarReport.factionName(toFaction) or toFaction

	if captor == "no one" or captor == "" then
		return nil
	end

	return name .. " has fallen to " .. captor .. "."
end

--- Claim this tick for announcement. Returns true for exactly one caller.
--
-- readSharedMemory returns 0 for an unset key in this codebase's usage, so 0
-- is treated as "nothing stored yet".
function WarAnnounce:claim(tick)
	local stored = readSharedMemory(self.CLAIM_KEY)
	if stored == nil then
		stored = 0
	end

	if stored == 0 then
		-- First sight since a restart: adopt silently, do not replay history.
		writeSharedMemory(self.CLAIM_KEY, tick)
		return false
	end

	if tick <= stored then
		return false -- already announced (or an older file)
	end

	writeSharedMemory(self.CLAIM_KEY, tick)
	return true
end

-- Layer 3 of the feedback stack (owner ruling 2026-09-04): one in-universe
-- line per player push that actually moved its front, galaxy-wide. Data comes
-- from war_flips.lua's `pushes` (the ledger rows the sim consumed this tick)
-- and `deltas` (how far each region's contest moved this export), both
-- written by bridge/export_war_state.lua. Galaxy-wide by constraint -- the
-- server's Lua has only broadcastToGalaxy -- and by choice: a push on Doaba
-- is news to both sides. Capped so a busy tick is a bulletin, not a wall.
--
-- A push by the HOLDER of a region lowers its contest (they are defending),
-- which reads as a negative delta and produces no line in this version.
-- Deliberate for now: "the garrison held" is a weaker beat than "the push is
-- working", and the vocabulary for it is not written yet.
WarAnnounce.DISPATCH_MAX_LINES = 3

function WarAnnounce:dispatch(tick)
	if WAR_FLIPS == nil or WarVoice == nil or WarVoice.dispatch == nil then
		return
	end
	local pushes = WAR_FLIPS.pushes
	local deltas = WAR_FLIPS.deltas
	if type(pushes) ~= "table" or #pushes == 0 or type(deltas) ~= "table" then
		return
	end

	local moved = {}
	for i = 1, #deltas do
		if deltas[i] ~= nil and deltas[i].region ~= nil then
			moved[deltas[i].region] = tonumber(deltas[i].delta) or 0
		end
	end

	local sent = 0
	for i = 1, #pushes do
		if sent >= WarAnnounce.DISPATCH_MAX_LINES then
			break
		end
		local p = pushes[i]
		if p ~= nil and p.region ~= nil and moved[p.region] ~= nil then
			local name = (WarReport ~= nil and WarReport.regionName ~= nil)
				and WarReport.regionName(p.region) or tostring(p.region)
			local line = WarVoice.dispatch(name, p.faction, p.players, moved[p.region])
			if line ~= nil then
				local ok, err = pcall(function() broadcastToGalaxy(nil, line) end)
				if ok then
					sent = sent + 1
					printf("WarAnnounce: dispatch tick=" .. tostring(tick) .. " :: " .. line .. "\n")
				else
					printf("WarAnnounce: dispatch broadcast FAILED: " .. tostring(err) .. "\n")
				end
			end
		end
	end
end

-- Supply dispatch: a region whose supply status changed this export gets one
-- line. Separate small cap from the push dispatch so a bad tick for supply
-- cannot crowd out the pushes, and vice versa.
WarAnnounce.SUPPLY_MAX_LINES = 2

function WarAnnounce:supplyDispatch(tick)
	if WAR_FLIPS == nil or WarVoice == nil or WarVoice.supplyChange == nil then
		return
	end
	local changes = WAR_FLIPS.supply
	if type(changes) ~= "table" or #changes == 0 then
		return
	end

	local sent = 0
	for i = 1, #changes do
		if sent >= WarAnnounce.SUPPLY_MAX_LINES then
			break
		end
		local c = changes[i]
		if c ~= nil and c.region ~= nil then
			local name = (WarReport ~= nil and WarReport.regionName ~= nil)
				and WarReport.regionName(c.region) or tostring(c.region)
			local line = WarVoice.supplyChange(name, c.from, c.to)
			if line ~= nil then
				local ok, err = pcall(function() broadcastToGalaxy(nil, line) end)
				if ok then
					sent = sent + 1
					printf("WarAnnounce: supply tick=" .. tostring(tick) .. " :: " .. line .. "\n")
				else
					printf("WarAnnounce: supply broadcast FAILED: " .. tostring(err) .. "\n")
				end
			end
		end
	end
end

function WarAnnounce:run()
	if WAR_FLIPS == nil or type(WAR_FLIPS) ~= "table" then
		return -- no flip file yet; nothing to say
	end

	local tick = tonumber(WAR_FLIPS.tick) or 0
	if tick <= 0 then
		return
	end

	if not self:claim(tick) then
		return
	end

	local flips = WAR_FLIPS.flips
	if type(flips) ~= "table" then
		flips = {}
	end

	-- The dispatch runs on every claimed tick, flips or not: a front can move
	-- a long way without anything changing hands, and that movement is the
	-- whole point of telling players their push registered.
	pcall(function() WarAnnounce:dispatch(tick) end)
	pcall(function() WarAnnounce:supplyDispatch(tick) end)

	if #flips == 0 then
		return -- tick claimed, dispatch sent, nothing changed hands this time
	end

	for i = 1, #flips do
		-- Reskin the town BEFORE announcing it. The garrison a player turns
		-- around to look at should already match the sentence they just read;
		-- announcing a capture while rebel troopers still stand in the street
		-- is worse than staying silent.
		--
		-- Core3 only re-evaluates an NPC's faction when that individual NPC
		-- dies (onDespawn -> respawn, on a 5 minute timer), so without this a
		-- flip changed only what WOULD spawn, and the town kept its old
		-- garrison indefinitely.
		local flipRegion = flips[i].region
		if flipRegion ~= nil and WarBridge ~= nil and WarBridge.reskinRegion ~= nil then
			local okReskin, errReskin = pcall(function()
				WarBridge.reskinRegion(flipRegion)
			end)
			if not okReskin then
				printf("WarAnnounce: reskinRegion(" .. tostring(flipRegion) .. ") failed: " .. tostring(errReskin) .. "\n")
			end
		end

		-- Officers are spawned mobiles too, and equally do not re-evaluate
		-- their own faction. Respawn them so a captured capital is briefed by
		-- the captor, not by the side that just lost it.
		if WarOfficer ~= nil and WarOfficer.respawnForRegion ~= nil then
			pcall(function() WarOfficer:respawnForRegion(flipRegion) end)
		end

		local line = self:lineFor(flips[i])
		if line ~= nil then
			local ok, err = pcall(function()
				broadcastToGalaxy(nil, line)
			end)
			-- Log either way. broadcastToGalaxy itself logs nothing, so without
			-- this there is no server-side evidence an announcement happened and
			-- "did the player actually see it?" is unanswerable from the logs.
			if ok then
				printf("WarAnnounce: broadcast tick=" .. tostring(tick) .. " :: " .. line .. "\n")
			else
				printf("WarAnnounce: broadcastToGalaxy FAILED: " .. tostring(err) .. "\n")
			end
		end
	end
end

-- Load the flip hand-off, then announce. includeFile paths resolve relative
-- to scripts/screenplays/ regardless of caller (DirectorManager::includeFile),
-- exactly as bridge/war_hook.lua documents for war_state.lua.
pcall(function()
	includeFile("../custom_scripts/war/war_flips.lua")
end)

pcall(function()
	WarAnnounce:run()
end)

--- Prints what THIS thread currently holds for WAR_FLIPS and the shared
-- claim, WITHOUT resetting anything -- unlike warAnnounceRun, which resets
-- the claim first and therefore cannot tell you whether the reload path
-- ever fired on its own.
function Tests:warFlipsTick()
	local t = (WAR_FLIPS ~= nil) and tostring(WAR_FLIPS.tick) or "nil"
	local n = (WAR_FLIPS ~= nil and type(WAR_FLIPS.flips) == "table") and tostring(#WAR_FLIPS.flips) or "nil"
	local c = (WarAnnounce ~= nil) and tostring(readSharedMemory(WarAnnounce.CLAIM_KEY)) or "nil"
	printf("WARFLIPSTICK: thread WAR_FLIPS.tick=" .. t .. " flips=" .. n .. " shared_claim=" .. c .. "\n")
end
