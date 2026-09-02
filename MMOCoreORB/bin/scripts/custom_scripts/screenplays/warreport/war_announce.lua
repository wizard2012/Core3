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
	if type(flips) ~= "table" or #flips == 0 then
		return -- tick claimed, but nothing changed hands this time
	end

	for i = 1, #flips do
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
