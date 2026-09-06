--[[
  custom_scripts/screenplays/warreport/war_contrib_counter.lua

  Gap 1 (backlog B14's missing read side): a player has never been able to
  see their own contribution to the war. war_contrib.lua's WarContrib.record
  is WRITE-ONLY -- it appends to a host-flushed spool and Core3 Lua has no
  database access at all (see that file's header), so a personal total
  cannot be read back from the ledger. This module keeps an entirely
  separate, game-side running counter instead: it never reads the ledger,
  never touches SQL, and is updated at the exact moment a contribution is
  recorded, from the same in-memory call that already validated it.

  HOW: wrap WarContrib.record, not every call site. war_contrib_hook.lua is
  the only real caller today (combat kills), but future sources
  (mission_completed, base_delivery, presence_hour -- all already on
  WarContrib.VALID_SOURCES but unwired) will all go through that same
  function, so wrapping it here covers them automatically with no further
  changes required when they land.

  WHY THE WRAPPER RE-INSTALLS ON EVERY INCLUDE (this is the subtle part):
  reload-lua.sh's version bump makes a stale thread re-run the ENTIRE
  screenplays.lua include chain on its next screenplay call -- not just
  this file. war_contrib.lua is in that chain too (screenplays.lua:24, this
  file is added after it) and its own top-level `function WarContrib.record
  (...)` statement runs again on every such reload, which UNCONDITIONALLY
  reassigns WarContrib.record back to the plain, uncounted definition --
  wiping out any wrapper installed by a previous load of this file. A guard
  keyed on a side field (e.g. "have I ever wrapped this WarContrib table
  before") would see its own stale marker survive that reassignment and
  wrongly skip re-wrapping, leaving the counter silently dead after the
  very first reload. So the guard instead compares WarContrib.record
  (identity, not existence) against the exact wrapper function object this
  module installed last time: unequal means war_contrib.lua just reset it
  to raw (or this is the first load ever) and a fresh wrap is needed; equal
  means this file's own top-level call ran twice in the same include pass
  (should not happen, but would otherwise double-wrap and double-count) and
  is skipped.

  PERSISTENCE: setScreenPlayState/getScreenPlayState on the CreatureObject
  (CreatureObject.idl -- Lua-bound via LuaCreatureObject::setScreenPlayState
  /getScreenPlayState), the same per-character persisted-state mechanism
  war_officer.lua's neighbours in this codebase already rely on for
  per-player memory (e.g. screenplays/tasks/rori/risha_sinan.lua's
  CreatureObject(pPlayer):setScreenPlayState(1, "risha_sinan")). Signature
  is setScreenPlayState(value, screenPlayName) -- value first -- and
  getScreenPlayState(screenPlayName) returns 0 for a character that has
  never had this key set, so "no contribution yet" and "explicitly zero"
  are indistinguishable, which is exactly the right default for a running
  total. No new persistence mechanism, no database write, per the task
  brief's constraints.

  STORAGE UNIT: the underlying value is a uint64 (unsigned long), so it
  cannot hold a fraction directly, but contribution points ARE fractional
  today (npc_kill_faction = 0.15, pvp_kill = 2.00 -- war_contrib_hook.lua).
  This module stores CENTIPOINTS (points * 100, rounded to the nearest
  integer) and divides back by 100.0 only at display time (total()/
  formatTotal()), so two decimal places of precision survive every add.

  LIFETIME-CUMULATIVE, NOT SESSION-SCOPED -- DECISION AND WHY: a per-login-
  session counter is cheap (it could just live in local screenplay-event
  data with no persistence at all) but resets to zero on every relog, which
  reads as broken to a player who logs back in and finds their number gone
  ("where did my points go?".) A lifetime-cumulative counter never
  surprises the player this way and is simpler to reason about -- there is
  exactly one value, and it only ever grows. The cost is that it also never
  resets on its own, including across a future war "season" boundary if one
  is ever implemented. Recommended anyway, because no season concept exists
  in this codebase today (verified: nothing in this worktree defines one),
  so there is nothing to reset against yet. FLAG FOR LATER: whoever
  implements a season boundary must explicitly zero this counter (call
  setScreenPlayState(0, WarContribCounter.STATE_KEY) for every character,
  or simply bump STATE_KEY to a new string so old totals read back as 0
  under the new key) as part of that work -- it will not happen on its own.

  FAIL-SAFE CONTRACT: WarContribCounter:add() is always called from inside
  the wrapper's own pcall, mirroring war_contrib_hook.lua's rule that a
  broken war-visibility feature must never be able to affect anything else
  (here: must never turn a successful WarContrib.record() into a failed
  one). A characterId that cannot be resolved to a live SceneObject on this
  thread (an invalid id, or the test-only synthetic ids war_probe.lua's
  warContribHookCheck passes) simply does not advance the counter for that
  one event -- the spool write this rides on has already succeeded either
  way.
]]

WarContribCounter = WarContribCounter or {}

WarContribCounter.STATE_KEY = "war_contrib_total"

--- Adds `points` to characterId's lifetime running total. Never raises.
function WarContribCounter:add(characterId, points)
	local oid = tonumber(characterId)
	local pts = tonumber(points)
	if oid == nil or oid <= 0 or pts == nil or pts <= 0 then
		return
	end

	local pObj = getSceneObject(math.floor(oid))
	if pObj == nil then
		return -- not resolvable on this thread right now; nothing to add to
	end

	local creature = CreatureObject(pObj)
	local currentCentipoints = creature:getScreenPlayState(WarContribCounter.STATE_KEY)
	local addCentipoints = math.floor((pts * 100) + 0.5)
	-- setScreenPlayState ORs the value into what is stored (LuaCreatureObject.cpp);
	-- it does not assign. Clear the old value first, then set the new one --
	-- found 2026-09-06 (slice 7 verifier); until then this total was an
	-- OR-accumulation, not a sum, from its second add.
	local current = math.tointeger(tonumber(currentCentipoints)) or 0
	if current > 0 then
		creature:removeScreenPlayState(current, WarContribCounter.STATE_KEY)
	end
	creature:setScreenPlayState(current + addCentipoints, WarContribCounter.STATE_KEY)
end

--- Lifetime total in points (fractional), for display. 0 for a character
-- with no recorded contribution yet -- never nil.
function WarContribCounter:total(pPlayer)
	if pPlayer == nil then
		return 0
	end
	local centipoints = CreatureObject(pPlayer):getScreenPlayState(WarContribCounter.STATE_KEY)
	return centipoints / 100.0
end

--- "142.35" style formatting, fixed 2 decimals.
function WarContribCounter:formatTotal(pPlayer)
	return string.format("%.2f", WarContribCounter:total(pPlayer))
end

--- (Re)installs the WarContrib.record wrapper. See header for why this
-- must run, unconditionally, every time this file loads -- including every
-- reload-lua.sh, not just the first.
function WarContribCounter._install()
	if WarContrib == nil or type(WarContrib) ~= "table" or WarContrib.record == nil then
		printf("WarContribCounter: WarContrib.record not visible; running-total counter disabled on this thread.\n")
		return
	end

	if WarContribCounter._installedWrapperRef == WarContrib.record then
		return -- this exact wrapper is already installed; do not double-wrap
	end

	local rawRecord = WarContrib.record

	local wrapped = function(faction, regionId, source, points, characterId)
		local recorded, reason = rawRecord(faction, regionId, source, points, characterId)

		if recorded then
			pcall(function() WarContribCounter:add(characterId, points) end)
		end

		return recorded, reason
	end

	WarContrib.record = wrapped
	WarContribCounter._installedWrapperRef = wrapped
end

WarContribCounter._install()
