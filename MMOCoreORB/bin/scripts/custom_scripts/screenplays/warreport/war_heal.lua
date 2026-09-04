--[[
  war_heal.lua -- healing a friendly faction NPC at a front feeds the war.

  WHY THIS EXISTS. docs/BACKLOG.md B11's ruling says "crafters as well as
  combatants must be able to affect it". A Medic was the clearest
  non-combatant with no path in at all: until the C++ change that ships
  alongside this file, a player could not even heal the NPCs fighting on their
  own side -- every heal command redirected to the healer for any non-pet
  AiAgent. See HealTargetPolicy.h for that half.

  This half turns the heal into war materiel. It is deliberately the SAME
  shape as war_donate.lua's crafted-goods hand-in: a MATERIEL channel, never a
  COMBAT one. warsim/sim/channels.lua's header is explicit that staying off
  M.COMBAT is what keeps a channel out of pressure/front selection, and a
  channel is never both. Healing your own side must not conjure attack
  pressure; it feeds supply_stock.

  SCOPE, STATED PLAINLY. The C++ change lets a player heal ANY same-faction
  NPC anywhere. This file only makes it COUNT at a war region, and only on the
  NPCs war_battle.lua spawns, because those are the only friendly NPCs that
  are at a front by construction and whose OIDs are already tracked. Healing a
  recruiter in a safe city still works and still gives medical XP -- it simply
  earns no materiel, because there is no front to attribute it to. Do not
  "fix" that by registering an observer on every faction NPC in the galaxy.

  WHY THE OBSERVER GOES ON THE NPC, NOT THE PLAYER. Unlike KILLEDCREATURE
  (which war_contrib_hook.lua registers on the player), HEALINGRECEIVED is
  notified on the TARGET -- CreatureObjectImplementation.cpp:1320 calls
  asCreatureObject()->notifyObservers(HEALINGRECEIVED, healer, amount). There
  is no "healing performed" event on the healer, so registration has to follow
  the healed object. war_battle.lua registers one per spawned NPC and its
  existing cleanup reaps them with the object.

  DOUBLE-COUNTING AND THE CAP. Exactly one WarContrib.record() per notify.
  Beyond that this channel does NOT invent its own throttle: the materiel
  channels are already bounded per tick by materiel_contrib_cap_region and
  materiel_contrib_cap_faction (both 3.0 in warsim/config.lua), and
  apply_materiel_delivery clamps the result at materiel_stock_max. So a medic
  parked at a front cannot flood the war no matter how much they heal -- the
  ceiling is the sim's, not this file's. Medical XP is NOT capped by any of
  that and is a known, accepted cost (owner ruling 2026-09-04).

  EVERY PATH RETURNS 0. Core3 treats a non-zero observer return as "remove
  this observer", which would silently detach the hook after the first heal.
  war_contrib_hook.lua's header records that trap; this file obeys it, and
  wraps the body in pcall so a nil the code did not expect cannot kill the
  observer either.
]]

WarHeal = ScreenPlay:new {}

-- Materiel per point of HAM healed. Deliberately small: a full heal of a
-- badly hurt trooper is worth a fraction of a crafted-goods donation, and the
-- per-tick caps above are the real ceiling anyway. Tunable by ruling, not by
-- feel -- record the reason in docs/DECISIONS.md if this moves.
WarHeal.MATERIEL_PER_HEALED_POINT = 0.002

-- Below this, ignore the heal entirely. Stops a stream of 1-point ticks from
-- each writing a spool row for a rounding-error amount of materiel.
WarHeal.MIN_HEAL_TO_COUNT = 50

--- Register the healing hook on one spawned NPC.
-- Called by war_battle.lua for each combatant it stages. Safe to call on a nil
-- pointer (returns false) so the caller does not need its own guard.
function WarHeal.attach(pNpc)
	if pNpc == nil then
		return false
	end

	local ok = pcall(function()
		createObserver(HEALINGRECEIVED, "WarHeal", "onHealingReceived", pNpc)
	end)

	return ok
end

--- HEALINGRECEIVED: pNpc is the healed NPC, pHealer is who healed it,
-- amount is the HAM actually restored.
function WarHeal:onHealingReceived(pNpc, pHealer, amount)
	pcall(function()
		if pNpc == nil or pHealer == nil then
			return
		end
		if WarContrib == nil or WarContrib.record == nil then
			return -- war_contrib.lua failed to load on this thread
		end

		local healed = tonumber(amount) or 0
		if healed < WarHeal.MIN_HEAL_TO_COUNT then
			return
		end

		-- Only a player earns war credit. NPC medics healing each other must
		-- never feed the ledger: AiAgentImplementation.cpp:2118 fires this
		-- same event for AI-on-AI heals, and this project already ships an
		-- NPC medic that heals people.
		if not SceneObject(pHealer):isPlayerCreature() then
			return
		end

		local healerFaction = CreatureObject(pHealer):getFaction()
		if healerFaction ~= FACTIONIMPERIAL and healerFaction ~= FACTIONREBEL then
			return -- neutral healer: no GCW stake
		end

		-- Same-faction only. The C++ policy already refuses to apply a heal to
		-- anything else, but this is the ledger boundary and re-checks rather
		-- than trusting a caller it does not own.
		local npcFaction = CreatureObject(pNpc):getFaction()
		if npcFaction ~= healerFaction then
			return
		end

		local zoneName = SceneObject(pHealer):getZoneName()
		local x = SceneObject(pHealer):getWorldPositionX()
		local y = SceneObject(pHealer):getWorldPositionY()

		local regionId = nil
		if WarReport ~= nil and WarReport.regionAt ~= nil then
			regionId = WarReport.regionAt(zoneName, x, y)
		end
		if regionId == nil then
			return -- not at a mapped war region: record nothing
		end

		local points = healed * WarHeal.MATERIEL_PER_HEALED_POINT
		if points <= 0 then
			return
		end

		local factionStr = "imperial"
		if healerFaction == FACTIONREBEL then
			factionStr = "rebel"
		end

		local characterId = SceneObject(pHealer):getObjectID()

		local recorded, reason = WarContrib.record(factionStr, regionId,
			"materiel_support", points, characterId)

		if not recorded then
			printf("WarHeal: WarContrib.record rejected (" .. tostring(reason)
				.. ") faction=" .. tostring(factionStr) .. " region="
				.. tostring(regionId) .. " points=" .. tostring(points) .. "\n")
		end
	end)

	return 0
end
