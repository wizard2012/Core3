--[[
  custom_scripts/screenplays/starterpack/starter_pack.lua

  Reusable "new player starter pack" grant. Built for the ask in
  docs/decisions.d (owner, verbatim): "this game is hard as a single player
  so we need to make systems that work around that."

  This file is ONLY the mechanism + the tunable contents. It does NOT wire
  itself into character creation -- the owner wants to tune CONTENTS first.
  When that's settled, the hook is one line: call StarterPack.grant(pPlayer)
  from wherever new characters are finalized (e.g. the character-creation
  screenplay or CreatureObjectImplementation's post-create path).

  HOW TO TUNE: edit StarterPack.ITEMS below. Every entry needs a verified
  template path (see the per-item comments for how each was checked against
  this pinned build) -- an unverified path is exactly the "grant silently
  fails" failure mode this was built to avoid.

  IDEMPOTENCY: StarterPack.grant() writes a per-character flag
  ("<oid>:starterpack:granted") the first time it completes ANY items (not
  only a clean run -- see below). A second call with no `force` argument is
  a no-op: it returns immediately with alreadyGranted = true and grants
  nothing. This means a re-run after a PARTIAL failure (say, three items
  landed and one didn't) does NOT retry the missing item on its own --
  re-running requires `force = true`, which is deliberate: an accidental
  double-invocation (e.g. a screenplay path called twice) must never hand
  out two carbines, and the every-item-is-independent design below means a
  human checking the probe output can already see exactly what's missing
  and re-grant deliberately rather than the mechanism guessing.

  FAULT ISOLATION: every single item grant runs inside its own pcall. A
  bad/renamed template on one line throws, is caught, is recorded as a
  failure in the returned results table, and every other item still runs.
  Nothing here ever throws out to the caller -- StarterPack.grant() itself
  cannot error even if EVERY item fails (e.g. player has no inventory
  object for some reason); it just returns an all-failed results table.

  RETURNS from StarterPack.grant(pPlayer, force):
    { alreadyGranted = true }                              -- no-op case
    { alreadyGranted = false, results = { {key=, label=,
        ok=true/false, location=/error=}, ... } }           -- normal case
    nil                                                     -- pPlayer was nil
]]

StarterPack = {}

-- ---------------------------------------------------------------------
-- CONTENTS -- this is the only part meant to be edited to retune the pack.
-- ---------------------------------------------------------------------
--
-- Every "weapon"/"item" entry is granted via the core-exposed giveItem()
-- Lua function straight into the player's main inventory container.
-- "vehicle" entries use giveControlDevice() into the datapad instead,
-- because a rideable vehicle is a ControlDevice, not a plain tangible --
-- see DirectorManager::giveControlDevice in
-- src/server/zone/managers/director/DirectorManager.cpp.
--
-- MEDICINE ITEMS REMOVED: medicine templates require medicineUse skill modifier
-- (e.g. crafted_stimpack_sm_s1_b.lua:48 sets medicineUse = 5). Fresh characters
-- have healing_ability = 0 (StimPack.idl:104 checks player.getSkillMod("healing_ability")
-- < super.medicineUseRequired), and healing_ability appears in disabledWearableSkillMods,
-- so NO equipment can work around the gate. Result: every medicine item in this build
-- requires at least science_medic_novice (the ONLY source of healing_ability in the
-- skill tree). NO self-heal item exists at zero Medic skill. Stimpacks granted here
-- were INERT and have been removed. Future tuning must account for this gate.
-- CERTIFICATION-GATED ITEMS REMOVED: Character creation grants exactly ONE starting
-- skill, selected by profession (PlayerCreationManager::addProfessionStartingItems:
-- auto startingSkill = professionData->getSkill()). Marksman gets combat_marksman_novice
-- and cert_carbine_dh17; Artisan, Brawler, Medic, Scout, and Entertainer get their
-- respective profession novice skills and NO Marksman certs. Any certification-gated
-- item is INERT for 5 out of 6 starting professions. A pack given to every new player
-- cannot contain items 83% of players cannot use. DH-17 carbine (required cert_carbine_dh17)
-- has been removed for this reason. Future tuning must account for this gate.
-- TESTING NOTE: When adding items to this pack, verify usability against a fresh
-- character from EVERY starting profession (Marksman, Artisan, Brawler, Medic, Scout,
-- Entertainer). Both defects found so far (stimpacks and carbine) came from testing
-- against a single profession and assuming that was typical.
StarterPack.ITEMS = {
	{
		key = "backpack",
		label = "Backpack (worn container)",
		type = "item",
		template = "object/tangible/wearables/backpack/backpack_s01.iff",
		-- Lands in inventory unworn; the player must equip it (wear) to
		-- get the capacity bonus. Intentionally not auto-equipped here --
		-- see the report for why.
	},
	{
		key = "carbine_accuracy_buff",
		label = "Carbine accuracy buff (5 charges, +10 accuracy / 300s)",
		type = "item",
		template = "object/tangible/skill_buff/skill_buff_carbine_accuracy.iff",
		-- Paired to the granted weapon on purpose: this is a doctor/
		-- entertainer-shaped buff a solo player has no other way to get,
		-- but it is a temporary combat AID (5 uses, 5-minute duration
		-- each), not a stat that trivialises fights outright.
	},
	{
		key = "landspeeder_x34",
		label = "X-34 landspeeder",
		type = "vehicle",
		-- No piloting certification exists for ground vehicles in this
		-- build (verified: no certificationsRequired in
		-- object/mobile/vehicle/landspeeder_x34.lua), so this is usable
		-- immediately. Delivered straight into the datapad as a ready
		-- control device (skips the deed/"use to redeem" step) --
		-- confirmed both templates exist and are registered:
		controlDeviceTemplate = "object/intangible/vehicle/landspeeder_x34_pcd.iff",
		generatedTemplate = "object/mobile/vehicle/landspeeder_x34.iff",
		-- Travel is the single biggest solo-friction item for a brand
		-- new character with no group to shuttle them around.
	},
	{
		key = "speederbike_swoop",
		label = "Swoop bike",
		type = "vehicle",
		-- Also certification-free: verified no certificationsRequired in
		-- object/mobile/vehicle/speederbike_swoop.lua, same as the X-34.
		controlDeviceTemplate = "object/intangible/vehicle/speederbike_swoop_pcd.iff",
		generatedTemplate = "object/mobile/vehicle/speederbike_swoop.iff",
		-- TUNING NOTE: the swoop is faster than the X-34 above, so a pack
		-- containing both is arguably redundant -- the X-34 becomes dead
		-- weight the moment a player summons the swoop. Kept both for now
		-- because the owner asked for the swoop additively; when tuning
		-- the pack for real, pick one.
	},
}

-- ---------------------------------------------------------------------
-- MECHANISM -- shouldn't need edits when retuning contents above.
-- ---------------------------------------------------------------------

local function grantOneItem(pInventory, pDatapad, def)
	if def.type == "vehicle" then
		if pDatapad == nil then
			return false, nil, "player has no datapad"
		end
		local pItem = giveControlDevice(pDatapad, def.controlDeviceTemplate, def.generatedTemplate, -1, false)
		if pItem == nil then
			return false, nil, "giveControlDevice returned nil (template missing/rejected)"
		end
		return true, "datapad", nil
	else
		if pInventory == nil then
			return false, nil, "player has no inventory container"
		end
		local pItem = giveItem(pInventory, def.template, -1)
		if pItem == nil then
			return false, nil, "giveItem returned nil (template missing/rejected/no room)"
		end
		return true, "inventory", nil
	end
end

--- Grant the starter pack to a player.
--
-- @param pPlayer the target CreatureObject (userdata), as passed around by
--        every other custom_scripts/screenplays function in this project.
-- @param force if true, grants again even if the per-character flag is
--        already set. Without force, a second call on an already-granted
--        character is a documented no-op (see file header).
-- @return nil if pPlayer is nil; otherwise a results table, see file header.
function StarterPack.grant(pPlayer, force)
	if pPlayer == nil then
		return nil
	end

	local oid = SceneObject(pPlayer):getObjectID()
	local dataKey = oid .. ":starterpack:granted"

	if not force and readData(dataKey) == 1 then
		return { alreadyGranted = true }
	end

	local pInventory = SceneObject(pPlayer):getSlottedObject("inventory")
	local pDatapad = SceneObject(pPlayer):getSlottedObject("datapad")

	local results = {}

	for i = 1, #StarterPack.ITEMS do
		local def = StarterPack.ITEMS[i]
		local ok, success, location, failReason = pcall(grantOneItem, pInventory, pDatapad, def)

		if not ok then
			-- grantOneItem itself threw (shouldn't normally happen, since
			-- giveItem/giveControlDevice are designed to return nil rather
			-- than throw -- but a bad def table, e.g. a nil template
			-- string, would throw here instead of inside them).
			results[#results + 1] = { key = def.key, label = def.label, ok = false, error = tostring(success) }
		elseif success then
			results[#results + 1] = { key = def.key, label = def.label, ok = true, location = location }
		else
			results[#results + 1] = { key = def.key, label = def.label, ok = false, error = failReason }
		end
	end

	writeData(dataKey, 1)

	return { alreadyGranted = false, results = results }
end
