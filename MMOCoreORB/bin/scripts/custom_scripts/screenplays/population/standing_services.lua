--[[
  custom_scripts/screenplays/population/standing_services.lua

  Phase 1 (D15 / docs/DESIGN-POPULATION.md S4.3, S4.7): the two standing
  service NPCs -- the field medic and the travelling performer -- as one
  screenplay. Spawns them at their currently-computed sites
  (placement.lua), re-evaluates on a timer, and carries the conversation
  handlers that charge a fee, gate on a cooldown, and call the one buff
  affordance Lua has (enhanceCharacter()) or the wound/BF setters.

  FAIL-SAFE CONTRACT (docs/AGENTS.md's own rule, applied here)
  ---------------------------------------------------------------
  PopulationServices:refreshKind() calls PopulationPlacement.loadWarState()
  and does NOTHING if it returns nil (missing/malformed war_state.lua) --
  existing providers are left exactly where they are; no crash, no
  despawn, no effect on anything else in the server. A missing or
  malformed population_config.lua (POPULATION_* tables absent) is handled
  the same way one level up: every function below that reads a POPULATION_*
  global guards with a type/nil check before using it, per-function, so a
  broken config file degrades to "no provider changes this pass" rather
  than a Lua error that could propagate into anything else
  reloadscreenplays touches.

  CONTRACT P / CONTRACT L (docs/DESIGN-POPULATION.md S7.1)
  ---------------------------------------------------------------
  These NPCs never call anything that increments context.population or
  writes war_contribution_ledger. They are plain AiAgents with a
  conversation handler; nothing here touches swgwar at all (verified by
  inspection: no SQL, no bridge write path is reachable from this file).
]]

PopulationServices = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "PopulationServices",

	-- how often the standing timer re-checks placement (S4.7.6's
	-- deferral needs to be retried periodically, and a circuit boundary
	-- needs to be noticed within a reasonable window). Not a war tunable;
	-- purely how chatty this file is about re-polling the generated file.
	REFRESH_INTERVAL_MS = 600 * 1000,
}

registerScreenPlay("PopulationServices", true)

-- ============================================================ helpers ===

local function sharedNpcKey(providerId)
	return "population:" .. providerId .. ":npcOid"
end

local function sharedAreaKey(providerId)
	return "population:" .. providerId .. ":areaOid"
end

local function siteTableFor(kind, regionId)
	if kind == "medic" then
		return POPULATION_AID_POSTS[regionId]
	elseif kind == "performer" then
		return POPULATION_CANTINAS[regionId]
	end
	return nil
end

-- ===================================================== lifecycle entry ==

function PopulationServices:start()
	self:refreshAll()
	createEvent(self.REFRESH_INTERVAL_MS, "PopulationServices", "circuitCheck", "", "")
end

--- Self-rescheduling timer tick. Also callable directly
-- (runLuaFunction PopulationServices:refreshAll, or the Tests hook) to
-- force an immediate re-evaluation without waiting for the timer --
-- reloadscreenplays does NOT re-run an already-started screenplay's
-- start() (docs/AGENTS.md trap 13), so this is how a config change (the
-- POPULATION_SERVICES off-switch included) becomes visible sooner than
-- the next scheduled tick.
function PopulationServices:circuitCheck()
	self:refreshAll()
	createEvent(self.REFRESH_INTERVAL_MS, "PopulationServices", "circuitCheck", "", "")
end

function PopulationServices:refreshAll()
	self:refreshKind("medic")
	self:refreshKind("performer")
end

-- ========================================================= placement ====

function PopulationServices:refreshKind(kind)
	if type(POPULATION_PROVIDERS) ~= "table" then
		return
	end

	local providerCfg = POPULATION_PROVIDERS[kind]
	if providerCfg == nil or type(providerCfg.count) ~= "number" then
		return
	end

	if type(POPULATION_SERVICES) ~= "table" or not POPULATION_SERVICES[kind] then
		for i = 1, providerCfg.count do
			self:retireProvider(kind .. "_" .. i)
		end
		return
	end

	local warState = PopulationPlacement.loadWarState()
	if warState == nil then
		-- FAIL SAFE: leave every provider of this kind exactly as is.
		return
	end

	-- The owner's front-region guarantee (supersedes D15's scarcity-only
	-- placement for active-battle cities specifically): the first
	-- `guaranteed` provider ids of each kind are pinned directly to the
	-- current ranked front regions (same signal war_battle.lua stages
	-- fights at -- see PopulationPlacement.frontRegions()), one provider
	-- per front, in rank order. This deliberately bypasses BOTH the
	-- toward_front/away_from_front bias (a guarantee is a harder
	-- requirement than a soft preference) AND min_separation = "planet"
	-- for these slots only -- three front regions can legitimately all
	-- land on the same planet (e.g. all three Tatooine cities hot at
	-- once), and the guarantee must still hold in that case rather than
	-- silently failing. Providers beyond `guaranteed` are the original
	-- ambient roaming pool, unchanged, and continue to respect
	-- min_separation among themselves for spread.
	local front = PopulationPlacement.frontRegions()
	local guaranteedCount = 0
	if type(providerCfg.guaranteed) == "number" then
		guaranteedCount = providerCfg.guaranteed
	end

	local usedPlanets = {}
	-- Regions the guaranteed slots took this pass. Roamers skip them: a
	-- roamer drawn to a front that already has its guaranteed provider put
	-- two identical NPCs on one spot.
	local usedRegions = {}
	for i = 1, providerCfg.count do
		local providerId = kind .. "_" .. i
		local regionId = nil

		if i <= guaranteedCount and front[i] ~= nil then
			local candidate = front[i].id
			if siteTableFor(kind, candidate) ~= nil then
				regionId = candidate
			else
				-- No site of this kind exists at this front region at all
				-- (e.g. tat_anchorhead has no cantina in this build --
				-- see population_config.lua's POPULATION_CANTINAS comment).
				-- The guarantee cannot be met by placement alone; flag it
				-- rather than silently doing nothing.
				printf("PopulationServices: front region " .. tostring(candidate) ..
					" has no " .. kind .. " site configured -- guarantee cannot be met for " ..
					providerId .. "\n")
			end
		end

		if regionId == nil then
			-- Either not a guaranteed slot, fewer active fronts than
			-- guaranteed slots right now, or the guaranteed site above was
			-- unavailable -- fall back to the normal roaming computation so
			-- the slot still gives ambient coverage instead of sitting idle.
			local ok, computed = pcall(PopulationPlacement.computeSite, kind, providerId, warState, usedPlanets, usedRegions)
			if ok then
				regionId = computed
			end
		end

		if regionId ~= nil then
			usedRegions[regionId] = true
			if i > guaranteedCount then
				-- Only the ambient roamers track/avoid each other's
				-- planets; guaranteed slots are deliberately exempt (see
				-- above).
				local planet = POPULATION_REGION_PLANET[regionId]
				if planet ~= nil then
					usedPlanets[planet] = true
				end
			end

			self:applyPlacement(kind, providerId, regionId)
		end
	end
end

function PopulationServices:applyPlacement(kind, providerId, regionId)
	local applied = PopulationPlacement.getAppliedRegion(providerId)
	local npcOid = readSharedMemory(sharedNpcKey(providerId))
	local pNpc = nil
	if npcOid ~= nil and npcOid ~= 0 then
		pNpc = getSceneObject(npcOid)
	end

	if applied == regionId and pNpc ~= nil then
		return -- already correctly placed and alive
	end

	if pNpc ~= nil then
		-- S4.7.6: never relocate a provider a player is standing next to.
		-- Defer -- keep the current applied region, retry next pass.
		local ok, numNearby = pcall(function() return AiAgent(pNpc):getNumberOfPlayersInRange() end)
		if ok and numNearby ~= nil and numNearby > 0 then
			return
		end

		self:despawnProvider(providerId, pNpc, true)
	end

	self:spawnProvider(kind, providerId, regionId)
end

function PopulationServices:retireProvider(providerId)
	local npcOid = readSharedMemory(sharedNpcKey(providerId))
	if npcOid ~= nil and npcOid ~= 0 then
		local pNpc = getSceneObject(npcOid)
		self:despawnProvider(providerId, pNpc, true)
	end
end

function PopulationServices:despawnProvider(providerId, pNpc, sayGoodbye)
	if pNpc ~= nil then
		if sayGoodbye then
			spatialChat(pNpc, "I'm needed elsewhere. Take care of yourself.")
		end
		SceneObject(pNpc):destroyObjectFromWorld()
	end

	writeSharedMemory(sharedNpcKey(providerId), 0)

	local areaOid = readSharedMemory(sharedAreaKey(providerId))
	if areaOid ~= nil and areaOid ~= 0 then
		local pArea = getSceneObject(areaOid)
		if pArea ~= nil then
			SceneObject(pArea):destroyObjectFromWorld()
		end
		writeSharedMemory(sharedAreaKey(providerId), 0)
	end
end

function PopulationServices:spawnProvider(kind, providerId, regionId)
	local siteTable = siteTableFor(kind, regionId)
	if siteTable == nil then
		return
	end

	local template = (kind == "medic") and "medic" or "entertainer"
	local pNpc = spawnMobile(siteTable.zone, template, -1, siteTable.x, siteTable.z, siteTable.y, siteTable.heading, siteTable.cell)

	if pNpc == nil then
		return
	end

	-- Neither the "medic" nor "entertainer" townsperson template ships
	-- CONVERSABLE (verified: mobile/townsperson/medic.lua has no
	-- optionsBitmask at all; entertainer.lua's is AIENABLED only) --
	-- setOptionBit ORs it in at runtime without touching the template
	-- (no restart.sh, no new mobile/ file). setConvoTemplate then points
	-- this specific instance at our conversation, the same runtime
	-- mechanism screenplays/poi/tatooine_jawa_traders.lua already uses to
	-- give one shared junk-dealer template several different
	-- conversations.
	TangibleObject(pNpc):setOptionBit(CONVERSABLE)
	AiAgent(pNpc):addObjectFlag(AI_STATIONARY)

	-- Named for what they are. The stock townsperson templates render as
	-- "<random name> (a medic)" / "(an entertainer)", and the cities already
	-- spawn stock medics and entertainers in the same hospitals and cantinas
	-- (corellia_coronet.lua has one 6 m from the performer's spot), so an
	-- identically-named pair read as a double spawn. The ours is the one you
	-- can talk to; now it is also the one that says so.
	pcall(function()
		SceneObject(pNpc):setCustomObjectName((kind == "medic") and "Field Medic" or "Travelling Performer")
	end)

	local convoTemplate = (kind == "medic") and "PopulationMedicConvoTemplate" or "PopulationPerformerConvoTemplate"
	AiAgent(pNpc):setConvoTemplate(convoTemplate)

	local npcOid = SceneObject(pNpc):getObjectID()
	writeStringData(npcOid .. ":population:providerId", providerId)
	writeStringData(npcOid .. ":population:kind", kind)
	writeStringData(npcOid .. ":population:region", regionId)

	writeSharedMemory(sharedNpcKey(providerId), npcOid)
	PopulationPlacement.setAppliedRegion(providerId, regionId)

	if kind == "performer" then
		self:spawnDwellArea(providerId, siteTable)
	end
end

-- ============================================== performer dwell (S4.3) ==
--
-- "Be inside the cantina for 60 seconds" is implemented with a
-- spawnActiveArea + ENTEREDAREA/EXITEDAREA observer pair storing the
-- entry timestamp in screenplay data (S4.3) -- no polling, no per-NPC
-- timer. Radius is centred on the performer's own spot inside the cantina
-- cell (this design has no hand-collected interior bounding box for each
-- of the 12 cantinas, so the area approximates "near the performer"
-- rather than "anywhere in the room" -- flagged, not hidden).

PopulationServices.DWELL_RADIUS_M = 15
PopulationServices.DWELL_MS = 60 * 1000

function PopulationServices:spawnDwellArea(providerId, siteTable)
	local pArea = spawnActiveArea(siteTable.zone, "object/active_area.iff",
		siteTable.x, siteTable.z, siteTable.y, self.DWELL_RADIUS_M, siteTable.cell)

	if pArea == nil then
		return
	end

	local areaID = SceneObject(pArea):getObjectID()
	createObserver(ENTEREDAREA, "PopulationServices", "dwellEntered", pArea)
	createObserver(EXITEDAREA, "PopulationServices", "dwellExited", pArea)

	writeSharedMemory(sharedAreaKey(providerId), areaID)
end

function PopulationServices:dwellEntered(pArea, pPlayer)
	if pPlayer == nil or not SceneObject(pPlayer):isPlayerCreature() then
		return 0
	end

	writeData(SceneObject(pPlayer):getObjectID() .. ":population:dwellStart", getTimestampMilli())

	return 0
end

function PopulationServices:dwellExited(pArea, pPlayer)
	if pPlayer == nil or not SceneObject(pPlayer):isPlayerCreature() then
		return 0
	end

	deleteData(SceneObject(pPlayer):getObjectID() .. ":population:dwellStart")

	return 0
end

-- ============================================================== fees ====

function PopulationServices:feeFor(kind, regionId)
	local feeCfg = POPULATION_FEES[kind]
	if feeCfg == nil then
		return 0
	end

	local frontier = false
	local warState = PopulationPlacement.loadWarState()
	if warState ~= nil and regionId ~= nil and warState.regions[regionId] ~= nil then
		frontier = warState.regions[regionId].frontier == true
	end

	local fee = feeCfg.base
	if frontier then
		fee = math.floor(fee * feeCfg.frontier_mult)
	end

	return fee
end

-- ======================================================== the services ==
--
-- Called from the conversation handlers below (and directly from the
-- Phase-1 acceptance test in screenplays/tests/tests.lua). Each is:
-- cooldown check -> funds check -> charge -> effect -> cooldown set. The
-- ordering matters for the acceptance test's "a refused attempt charges
-- nothing" assertion: cooldown/funds are checked and can refuse BEFORE
-- any credits move.

PopulationServices.MEDIC_COOLDOWN_NAME = "population_medic_buff"
PopulationServices.PERFORMER_COOLDOWN_NAME = "population_performer_clear"

--- Returns true on success, false (with a message already sent) on
-- refusal. `regionId` may be nil (e.g. the acceptance test's standalone
-- subject) -- feeFor() treats that as "not frontier".
function PopulationServices:deliverMedic(pPlayer, regionId)
	if not CreatureObject(pPlayer):checkCooldownRecovery(self.MEDIC_COOLDOWN_NAME) then
		CreatureObject(pPlayer):sendSystemMessage("The medic's last treatment hasn't worn off yet.")
		return false
	end

	local fee = self:feeFor("medic", regionId)

	if CreatureObject(pPlayer):getCashCredits() < fee then
		CreatureObject(pPlayer):sendSystemMessage("You can't afford the medic's fee of " .. fee .. " credits.")
		return false
	end

	CreatureObject(pPlayer):subtractCashCredits(fee)

	-- The actual heal (this used to be missing entirely -- enhanceCharacter()
	-- below is a buff, not a heal; verified PlayerManagerImplementation.cpp:
	-- 6666-6685 never touches current HAM damage or wound pools). Doctors
	-- heal the physical pools; the performer (deliverPerformer, below)
	-- clears MIND -- mirroring the real SWG medic/entertainer split this
	-- file's header already documents. healDamage's signature is
	-- (damageHealed, pool) -- see LuaCreatureObject::healDamage and its
	-- existing callers in screenplays/tests/tests.lua -- and
	-- CreatureObjectImplementation::healDamage clamps the result to
	-- maxValue - wounds itself (verified CreatureObjectImplementation.cpp:
	-- ~1261-1280), so passing an oversized amount is safe and just means
	-- "heal to full"; it is never a subtraction or an overflow risk.
	--
	-- ORDER MATTERS: setWounds() must run BEFORE healDamage(). Verified in
	-- CreatureObjectImplementation::setWounds -- clearing a wound only
	-- raises the CEILING (maxHam - wounds); for a primary pool (HEALTH/
	-- ACTION/MIND) it does NOT also raise current HAM back up to that new
	-- ceiling. healDamage()'s own ceiling check
	-- (maxValue = maxHamList.get(type) - wounds.get(type)) reads whatever
	-- wounds are in effect AT CALL TIME, so healing before clearing wounds
	-- would cap the heal at the OLD, still-wounded ceiling.
	CreatureObject(pPlayer):setWounds(HEALTH, 0)
	CreatureObject(pPlayer):setWounds(CONSTITUTION, 0)
	CreatureObject(pPlayer):setWounds(STAMINA, 0)
	CreatureObject(pPlayer):setWounds(ACTION, 0)
	CreatureObject(pPlayer):setWounds(STRENGTH, 0)
	CreatureObject(pPlayer):setWounds(QUICKNESS, 0)

	CreatureObject(pPlayer):healDamage(999999, HEALTH)
	CreatureObject(pPlayer):healDamage(999999, ACTION)
	CreatureObject(pPlayer):healDamage(999999, MIND)

	-- Keep the buff too -- real and working on its own, just not a heal by
	-- itself.
	CreatureObject(pPlayer):enhanceCharacter()

	CreatureObject(pPlayer):addCooldown(self.MEDIC_COOLDOWN_NAME, POPULATION_COOLDOWN_MS.medic)

	CreatureObject(pPlayer):sendSystemMessage("The medic treats your wounds and patches you up. (" .. fee .. " credits)")

	return true
end

--- `requireDwell` defaults to true (the real conversation path); the
-- acceptance test passes false to exercise the buff/fee/cooldown path
-- without needing a live active-area dwell.
function PopulationServices:deliverPerformer(pPlayer, regionId, requireDwell)
	if requireDwell ~= false then
		local dwellStart = readData(SceneObject(pPlayer):getObjectID() .. ":population:dwellStart")
		if dwellStart == nil or dwellStart == 0 or (getTimestampMilli() - dwellStart) < self.DWELL_MS then
			CreatureObject(pPlayer):sendSystemMessage("Stick around a while first.")
			return false
		end
	end

	if not CreatureObject(pPlayer):checkCooldownRecovery(self.PERFORMER_COOLDOWN_NAME) then
		CreatureObject(pPlayer):sendSystemMessage("You were just here. Give it some time.")
		return false
	end

	local fee = self:feeFor("performer", regionId)

	if CreatureObject(pPlayer):getCashCredits() < fee then
		CreatureObject(pPlayer):sendSystemMessage("You can't afford the performer's fee of " .. fee .. " credits.")
		return false
	end

	CreatureObject(pPlayer):subtractCashCredits(fee)
	CreatureObject(pPlayer):setShockWounds(0)
	CreatureObject(pPlayer):setWounds(MIND, 0)
	CreatureObject(pPlayer):addCooldown(self.PERFORMER_COOLDOWN_NAME, POPULATION_COOLDOWN_MS.performer)

	CreatureObject(pPlayer):sendSystemMessage("The performance leaves you refreshed. (" .. fee .. " credits)")

	return true
end

-- ConvoTemplate/ConvoScreen definitions (PopulationMedicConvoTemplate,
-- PopulationPerformerConvoTemplate) live in
-- custom_scripts/mobile/population_conversations.lua, NOT here --
-- ConvoTemplate is only defined in the Lua state mobile/serverobjects.lua's
-- chain loads, confirmed live (loading it here raised "attempt to index a
-- nil value (global 'ConvoTemplate')" on every boot/reload).
--
-- conv_handler (screenplays/conv_handler.lua), conversely, is only
-- defined in THIS state (DirectorManager's screenplays.lua chain) -- so
-- the two luaClassHandler classes below belong here, exactly mirroring
-- vanilla's own split: mobile/conversations/misc/bartender_conv.lua
-- (ConvoTemplate side) and screenplays/cities/cantinas/bartender_conv_handler.lua
-- (conv_handler side) are two different directory trees for the same
-- reason. C++ dispatches luaClassHandler by name at conversation-open
-- time, so the two pieces never need to share a Lua state.

PopulationMedicConvHandler = conv_handler:new {}

function PopulationMedicConvHandler:getInitialScreen(pPlayer, pNpc, pConvTemplate)
	if pPlayer == nil or pNpc == nil or pConvTemplate == nil then
		return
	end
	return LuaConversationTemplate(pConvTemplate):getScreen("population_medic_start")
end

function PopulationMedicConvHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
	local screen = LuaConversationScreen(pConvScreen)
	local screenID = screen:getScreenID()

	if screenID == "opt_treat" then
		local npcID = SceneObject(pNpc):getObjectID()
		local regionId = readStringData(npcID .. ":population:region")
		PopulationServices:deliverMedic(pPlayer, regionId)
	end

	return pConvScreen
end

PopulationPerformerConvHandler = conv_handler:new {}

function PopulationPerformerConvHandler:getInitialScreen(pPlayer, pNpc, pConvTemplate)
	if pPlayer == nil or pNpc == nil or pConvTemplate == nil then
		return
	end
	return LuaConversationTemplate(pConvTemplate):getScreen("population_performer_start")
end

function PopulationPerformerConvHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
	local screen = LuaConversationScreen(pConvScreen)
	local screenID = screen:getScreenID()

	if screenID == "opt_clear" then
		local npcID = SceneObject(pNpc):getObjectID()
		local regionId = readStringData(npcID .. ":population:region")
		PopulationServices:deliverPerformer(pPlayer, regionId, true)
	end

	return pConvScreen
end
