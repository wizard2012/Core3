--[[
  custom_scripts/screenplays/warreport/war_contrib_hook.lua

  Wires live combat into the war_contrib spool (war_contrib.lua, backlog
  B14's game-side writer -- see that file's header for the spool/flusher
  design this rides on). Scope for THIS pass, per the task brief: combat
  kills only -- `npc_kill_faction` and `pvp_kill`. mission_completed,
  presence_hour, installation_destroyed and base_delivery are on
  WarContrib.VALID_SOURCES already but are NOT wired here.

  HOW A KILL IS DETECTED: CreatureManagerImplementation.cpp's destruction
  path calls `player->notifyObservers(ObserverEventType::KILLEDCREATURE,
  destructedObject)` once per credited player -- for a solo kill, the top
  damage player; for a grouped kill, once for EVERY member of the credited
  group (see that source for the exact loop). This is the same signal
  ordinary kill-quest screenplays use (see
  screenplays/tasks/safety_measures/safety_measures.lua's
  notifyKilledCreature for the pattern this file follows). We ride that
  existing credit decision rather than inventing a second one from raw
  damage -- Core3 has already decided who "gets" this kill; we just tax it.

  WHY REGISTRATION IS AT LOGIN, NOT start(): KILLEDCREATURE is a per-object
  observer (registerObserver on the SceneObject itself), not a global
  event, so it must be attached to every player individually. Login is the
  natural "runs for every relevant object anyway" moment, exactly the
  pattern custom_scripts/screenplays/warreport/war_login.lua already uses
  for the same PlayerTriggers.playerLoggedIn wrap (see that file's header
  for why a monkey-patch and not a playerTriggers.lua edit). Two
  independent wraps of the same function chain safely -- each stashes the
  function it captured into its OWN field
  (_warContribOriginalLoggedIn here, _warReportOriginalLoggedIn there), so
  load order between the two files does not matter and neither can clobber
  the other's original.

  RELOAD BOUNDARY (see CLAUDE.md's reload-lua.sh section):
    - install() (the playerLoggedIn wrap, and therefore the
      createObserver(KILLEDCREATURE, ...) call inside it) only runs again
      for LOGINS AFTER a reload picks up this file -- a player already
      online when this file first loads has no observer until their next
      login. That part is a registration, same category as a global
      screenplay's start(), even though it happens to live outside one.
    - onKilledCreature's BODY -- faction/victim checks, region lookup,
      points, the WarContrib.record() call -- dispatches by STRING name
      (createObserver's 3rd/4th args), so editing this function and running
      reload-lua.sh changes what already-registered observers do on their
      very next kill, with no relogin and no restart.sh needed. This is the
      overwhelming majority of this file's logic.

  REGION ATTRIBUTION: WarReport.regionAt(zoneName, x, y) (war_report.lua) --
  containment against the same town-centre coordinates
  (WarReport.COORDS) the login report and battle staging already use, radii
  taken from the same authoritative planet region tables COORDS itself
  cites. A kill outside every mapped town's bounds resolves to nil and
  WRITES NOTHING -- per the task brief, no guessing.

  DOUBLE-COUNTING: exactly one WarContrib.record() call per notifyObservers
  call. notifyObservers already fires once per credited player (Core3's own
  dedup -- see above), not once per damage tick/DoT tick/pet swing, so a
  group kill correctly produces one contribution per group member (each
  member is a distinct killer, contributing separately, same as if they had
  each landed a solo kill) and a solo kill produces exactly one. Pet
  damage is not separately credited here: KILLEDCREATURE fires on the
  owning PLAYER object, never on the pet (pets are not player creatures and
  are never the observer target), so a pet kill folds into its owner's
  single credit exactly the way Core3's own kill-quest observers already
  treat it -- there is no separate "pet kill" event to double-count.

  FAIL-SAFE CONTRACT: the entire body runs inside one pcall. Any error --
  a nil the code did not expect, WarContrib.record() itself failing to open
  its spool file -- is caught, logged, and swallowed. The handler always
  returns 0 (keep observer) even on failure. This function is invoked
  synchronously from inside Core3's kill-credit/death path
  (CreatureManagerImplementation's destroy handling calls notifyObservers
  before returning), so an uncaught Lua error here would propagate into
  that path -- pcall is what keeps a broken war hook from being able to
  affect combat at all.
]]

WarContribHook = ScreenPlay:new {
	screenplayName = "WarContribHook",

	-- DESIGN.md S:5.5's own contribution-source table (PROVISIONAL) --
	-- reused verbatim, not re-derived. Consistency check against the
	-- sim's calibration (warsim/scenarios/player_model.lua,
	-- POINTS_PER_PLAYER_PER_TICK = 3.0 per player per 1-hour tick,
	-- DESIGN.md H2/11.4): DESIGN 5.5 already prices presence_hour at 1.00
	-- and npc_kill_faction at 0.15, so "~3 points/tick from one casual
	-- player" (DESIGN 5.5's own worked example) decomposes cleanly as
	-- 1.00 (being present) + ~13 baseline NPC kills * 0.15 = 1.95, total
	-- ~2.95 ~= 3 -- a wholly ordinary hour of GCW-mob grinding, not an
	-- edge case. pvp_kill's 2.00 is ~13x npc_kill_faction's 0.15, matching
	-- the table's own framing of PvP as a higher-stakes overlay on the
	-- same ledger, not a separate scoring path. Neither number is invented
	-- here; both are copied from the table this project already shipped.
	NPC_KILL_POINTS = 0.15,
	PVP_KILL_POINTS = 2.00,
}

registerScreenPlay("WarContribHook", true)

function WarContribHook:start()
	-- Nothing to schedule globally -- see header: registration happens per
	-- player, at login, via the wrap installed below.
end

--- Wrap PlayerTriggers:playerLoggedIn to attach a KILLEDCREATURE observer
-- to every logging-in player. Idempotent across reloads (see header).
function WarContribHook:install()
	if PlayerTriggers == nil or type(PlayerTriggers) ~= "table" then
		printf("WarContribHook: PlayerTriggers is not a table -- combat contribution hook disabled.\n")
		return
	end

	if PlayerTriggers._warContribOriginalLoggedIn ~= nil then
		return -- already wrapped in this VM incarnation
	end

	PlayerTriggers._warContribOriginalLoggedIn = PlayerTriggers.playerLoggedIn

	PlayerTriggers.playerLoggedIn = function(triggersSelf, pPlayer)
		-- Vanilla behaviour (and any other wrapper already chained in,
		-- e.g. WarReportLogin's) first and unconditionally.
		local okOrig = pcall(function()
			if PlayerTriggers._warContribOriginalLoggedIn ~= nil then
				PlayerTriggers._warContribOriginalLoggedIn(triggersSelf, pPlayer)
			end
		end)
		if not okOrig then
			printf("WarContribHook: original playerLoggedIn raised; contribution hook continues.\n")
		end

		if pPlayer == nil then
			return
		end

		pcall(function()
			-- drop+create rather than a hasObserver check: cheap, and
			-- correct whether this is a first login or a relog that
			-- already carries the observer from a prior session.
			dropObserver(KILLEDCREATURE, "WarContribHook", "onKilledCreature", pPlayer)
			createObserver(KILLEDCREATURE, "WarContribHook", "onKilledCreature", pPlayer)
		end)
	end
end

--- KILLEDCREATURE handler. `pPlayer` is the credited killer (the object the
-- observer is registered on); `pVictim` is the destroyed creature. Must
-- return a number (1 = remove observer, 0 = keep) -- ScreenPlayObserver
-- logs an error and treats a missing/non-number return as "keep" if this
-- doesn't, so every path below explicitly returns 0.
function WarContribHook:onKilledCreature(pPlayer, pVictim, arg2)
	local ok, err = pcall(function()
		if pPlayer == nil or pVictim == nil then
			return
		end
		if WarContrib == nil or WarContrib.record == nil then
			return -- war_contrib.lua failed to load on this thread
		end

		local killerFaction = CreatureObject(pPlayer):getFaction()
		if killerFaction ~= FACTIONIMPERIAL and killerFaction ~= FACTIONREBEL then
			return -- neutral killer: no GCW stake in this kill
		end

		local opposingFaction = FACTIONREBEL
		if killerFaction == FACTIONREBEL then
			opposingFaction = FACTIONIMPERIAL
		end

		local victimFaction = CreatureObject(pVictim):getFaction()
		if victimFaction ~= opposingFaction then
			return -- same-faction, neutral, or non-GCW victim: does not count
		end

		local isVictimPlayer = SceneObject(pVictim):isPlayerCreature()
		local source = isVictimPlayer and "pvp_kill" or "npc_kill_faction"
		local points = isVictimPlayer and WarContribHook.PVP_KILL_POINTS or WarContribHook.NPC_KILL_POINTS

		local zoneName = SceneObject(pPlayer):getZoneName()
		local x = SceneObject(pPlayer):getWorldPositionX()
		local y = SceneObject(pPlayer):getWorldPositionY()

		local regionId = nil
		if WarReport ~= nil and WarReport.regionAt ~= nil then
			regionId = WarReport.regionAt(zoneName, x, y)
		end
		if regionId == nil then
			-- Layer 1 of the feedback stack: a kill that earns nothing should
			-- SAY so, once in a while, or a player standing 45m outside
			-- Anchorhead's attribution circle never learns why their effort is
			-- going nowhere. Cooldown-gated so it teaches rather than nags.
			pcall(function()
				if WarVoice == nil or WarVoice.noWarZone == nil then
					return
				end
				local oid = SceneObject(pPlayer):getObjectID()
				local key = tostring(oid) .. ":war:nowarzone"
				local last = readData(key)
				local now = getTimestampMilli()
				if last ~= nil and last > 0 and (now - last) < 60000 then
					return
				end
				writeData(key, now)
				CreatureObject(pPlayer):sendSystemMessage(WarVoice.noWarZone())
			end)
			return -- no mapped war region here -- record nothing, per brief
		end

		local factionStr = "imperial"
		if killerFaction == FACTIONREBEL then
			factionStr = "rebel"
		end

		local characterId = SceneObject(pPlayer):getObjectID()

		local recorded, reason = WarContrib.record(factionStr, regionId, source, points, characterId)
		if not recorded then
			printf("WarContribHook: WarContrib.record rejected (" .. tostring(reason)
				.. ") faction=" .. tostring(factionStr) .. " region=" .. tostring(regionId)
				.. " source=" .. tostring(source) .. "\n")
		end
	end)

	if not ok then
		printf("WarContribHook:onKilledCreature failed, swallowed: " .. tostring(err) .. "\n")
	end

	return 0 -- always keep the observer registered
end

WarContribHook:install()
