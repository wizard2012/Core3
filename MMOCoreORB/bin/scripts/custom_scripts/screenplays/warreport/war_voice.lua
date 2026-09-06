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

--- Supply line on arrival. `status` is war_state.lua's supply_status, whose
-- vocabulary is exactly: "connected", "degraded", "cut"
-- (bridge/war_state_writer.lua supply_status_for). Nothing for connected.
function WarVoice.supply(regionName, status)
	status = tostring(status or "")
	if status == "cut" then
		return string.format("Supply lines to %s are cut. The garrison here is on quarter rations.", tostring(regionName))
	elseif status == "degraded" then
		return string.format("Supply to %s is thin. Every crate that gets through matters.", tostring(regionName))
	end
	return nil
end

--- Arrival line for a town that is HELD, not contested: the spread layer's
-- garrison. `faction` is the holder.
function WarVoice.held(regionName, faction)
	local forces = pick(WarVoice.FORCES, faction, "Unknown forces")
	return string.format("%s hold %s. Patrols on the streets.", forces, tostring(regionName))
end

--- Dispatch line when a region's supply status changed this cycle.
function WarVoice.supplyChange(regionName, fromStatus, toStatus)
	toStatus = tostring(toStatus or "")
	fromStatus = tostring(fromStatus or "")
	local where = tostring(regionName or "the front")
	if toStatus == "cut" then
		return string.format("WAR DISPATCH -- supply lines to %s have been cut.", where)
	elseif toStatus == "connected" and (fromStatus == "cut" or fromStatus == "degraded") then
		return string.format("WAR DISPATCH -- supply to %s is flowing again.", where)
	elseif toStatus == "degraded" and fromStatus == "connected" then
		return string.format("WAR DISPATCH -- the road to %s is under strain.", where)
	end
	return nil
end

--- Courier lines. `faction` is the courier's own side.
function WarVoice.courierIssued(regionName, faction)
	local who = pick(WarVoice.COMMAND, faction, "Command")
	return string.format("%s: this crate is bound for %s. Get it there in one piece.", who, tostring(regionName))
end

function WarVoice.courierDelivered(regionName, faction)
	local who = pick(WarVoice.COMMAND, faction, "Command")
	return string.format("%s: crate received at %s. The garrison eats tonight because of you.", who, tostring(regionName))
end

function WarVoice.courierSpoiled(regionName)
	return string.format("The crate for %s sat too long and is no use to anyone now.", tostring(regionName))
end

function WarVoice.courierAlready(regionName)
	return string.format("You are already carrying a crate for %s. Deliver that one first.", tostring(regionName))
end

-- Battle chatter (docs/DESIGN-BATTLES.md 3.3): what a line says at contact,
-- when a wave arrives, when it falls back, when it breaks. Spoken by the
-- squad's sergeant in spatial chat; prefixed with the front's officer when
-- the sim exported one for that side ("Captain Tannor: hold the line!").
WarVoice.BATTLE = {
	contact  = { imperial = "Contact! Rebel line ahead -- advance!",           rebel = "Contact front! Imperial line -- move up!" },
	-- slice 4: the capital assault -- a besieged capital's lines say so
	siege      = { imperial = "The capital is under siege -- take the gates!",     rebel = "Storm the capital -- for the Alliance!" },
	siege_hold = { imperial = "This is the capital. Nobody gets past us.",         rebel = "They are at the capital -- hold, or it all ends here!" },
	hold     = { imperial = "Hold this line. Nobody falls back without orders.", rebel = "Hold here! Make them come to us!" },
	wave     = { imperial = "Reinforcements on the line! Close it up!",        rebel = "Fresh squad coming in -- form on me!" },
	fallback = { imperial = "Fall back to the marker and regroup!",            rebel = "Fall back! Regroup at the marker!" },
	breaking = { imperial = "The line is breaking -- hold, damn you!",         rebel = "They are through -- every man for himself!" },
	-- Slice C: walkers.
	walker      = { imperial = "Walker support is up -- advance behind the AT-ST!", rebel = "Our walker is up -- push with it!" },
	walker_down = { imperial = "The walker is down! Hold the line!",               rebel = "We lost the walker -- hold what we have!" },
	-- Slice D: command. %s is the commander's name.
	command_taken  = { imperial = "Squad -- form on %s! Orders are theirs now.",   rebel = "Squad, form on %s -- they have the line!" },
	order_attack   = { imperial = "Engage the target! Weapons free!",             rebel = "On that one -- take it down!" },
	order_hold     = { imperial = "Hold position. Nobody moves.",                  rebel = "Hold here! Dig in!" },
	order_fallback = { imperial = "Fall back on the commander -- move!",           rebel = "Back to the commander -- go, go!" },
	dismissed      = { imperial = "Resuming command. Good hunting.",               rebel = "I have the squad again. Thanks for the help." },
	released       = { imperial = "Commander down -- I have the squad!",           rebel = "We lost the commander -- on me!" },
}

function WarVoice.battle(kind, faction, officer)
	local tbl = WarVoice.BATTLE[kind]
	if tbl == nil then
		return nil
	end
	local line = pick(tbl, faction, nil)
	if line == nil then
		return nil
	end
	if officer ~= nil and officer ~= "" then
		return tostring(officer) .. ": " .. line
	end
	return line
end

function WarVoice.courierNothing()
	return "Every friendly garrison is supplied. Come back when a line is cut."
end
