--[[
  custom_scripts/screenplays/warreport/war_voice.lua

  Every player-facing war string, in one place, in-universe.

  OWNER RULING (2026-09-04): broadcasts and readouts use in-universe dialogue,
  not server speak. No "tick", no "contest", no "points", no "pressure". The
  only numbers a player ever sees are diegetic ones -- how many fighters were
  in a push. Thresholds still exist (war_state.lua carries them, see
  war_tick_tally.lua) but they select a TIER of phrasing; they are never
  displayed.

  WHY ONE TABLE. Three modules speak to players about the war -- the per-kill
  readout (war_tick_tally.lua), the arrival message (war_presence.lua) and the
  galaxy dispatch (war_announce.lua). If each carried its own strings, tuning
  the voice would mean touching logic in three files and the three would
  drift. Everything below is data; changing it is a reload, never a logic
  change. Nothing in here reads game state.

  Load order: this file must be included BEFORE any of the three consumers.
  screenplays.lua puts it ahead of war_contrib.lua for exactly that reason.
]]

WarVoice = WarVoice or {}

-- "imperial" / "rebel" (lower-case strings, the same vocabulary
-- WarContrib.record() takes) -> who is speaking to the player.
WarVoice.COMMAND = {
	imperial = "Imperial Command",
	rebel    = "Alliance Intelligence",
}

-- The side, as a noun a dispatch can use.
WarVoice.SIDE = {
	imperial = "the Empire",
	rebel    = "the Alliance",
}

-- The side's troops, as a subject.
WarVoice.FORCES = {
	imperial = "Imperial forces",
	rebel    = "Rebel forces",
}

-- The OTHER side's garrison, as an object of the push. Keyed by the pushing
-- faction, so a lookup by who is attacking reads naturally.
WarVoice.ENEMY_GARRISON = {
	imperial = "the Rebel garrison",
	rebel    = "the Imperial garrison",
}

local function lc(faction)
	return string.lower(tostring(faction or ""))
end

local function pick(tbl, faction, fallback)
	return tbl[lc(faction)] or fallback
end

--- Per-kill readout. `tier` is one of:
--   "counted"  below the force threshold, or thresholds unknown
--   "force"    this player's effort this window has forced a front
--   "cap"      the region can absorb no more this window
function WarVoice.readout(faction, regionName, tier)
	local who = pick(WarVoice.COMMAND, faction, "Command")
	local where = tostring(regionName or "the front")

	if tier == "cap" then
		return string.format("%s, %s: the line can absorb no more. Hold what you have taken.", who, where)
	elseif tier == "force" then
		if lc(faction) == "rebel" then
			return string.format("%s, %s: the Alliance is sending fighters on your word.", who, where)
		end
		return string.format("%s, %s: High Command is committing forces on your reports.", who, where)
	end

	return string.format("%s, %s: your kills are noted. Keep the pressure on -- the garrison is wavering.", who, where)
end

--- Kill outside any mapped war region. Teaches, does not scold.
function WarVoice.noWarZone()
	return "No war zone here -- command has no use for these kills."
end

--- Presence line when ground changed hands recently. `faction` is the CAPTOR.
function WarVoice.captureNote(faction)
	return string.format("%s took a position here within the hour.", pick(WarVoice.FORCES, faction, "Enemy forces"))
end

--- Map a contest change (this window's delta, in the sim's 0..100 units) to
-- a phrase. Positive delta means the push is working. The bands are the only
-- place the sim's units appear, and they appear as a phrase, not a number.
function WarVoice.deltaTier(delta)
	delta = tonumber(delta) or 0
	if delta >= 15 then return "breaking" end
	if delta >= 5  then return "wavering" end
	if delta >= 1  then return "pressing" end
	return nil -- nothing worth a dispatch line
end

local TIER_PHRASE = {
	pressing = "has %s on the back foot",
	wavering = "has %s wavering",
	breaking = "has %s close to breaking",
}

--- One galaxy dispatch line. `players` is a diegetic count and the only
-- number allowed. Returns nil when the delta is not worth a line.
function WarVoice.dispatch(regionName, faction, players, delta)
	local tier = WarVoice.deltaTier(delta)
	if tier == nil then
		return nil
	end

	players = tonumber(players) or 0
	local strength
	if players <= 0 then
		strength = ""
	elseif players == 1 then
		strength = ", one fighter strong,"
	else
		strength = string.format(", %d fighters strong,", players)
	end

	local side = pick(WarVoice.SIDE, faction, "an unknown force")
	local article = (lc(faction) == "imperial") and "an Imperial push" or "a Rebel push"
	local enemy = pick(WarVoice.ENEMY_GARRISON, faction, "the garrison")

	return string.format("WAR DISPATCH -- %s: %s%s %s.",
		tostring(regionName or "the front"), article, strength,
		string.format(TIER_PHRASE[tier], enemy))
end

--- Supply line, for later surfaces (kept here so the vocabulary exists in one
-- place from day one). `status` is war_state.lua's supply_status string.
function WarVoice.supply(regionName, status)
	status = tostring(status or "")
	if status == "cut" then
		return string.format("Supply lines to %s are cut. The garrison there is starving.", tostring(regionName))
	elseif status == "strained" then
		return string.format("Supply to %s is thin. Every crate matters.", tostring(regionName))
	end
	return nil
end
