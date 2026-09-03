--[[
  custom_scripts/screenplays/warreport/war_donate.lua

  The recruiter-hand-in half of the "materiel_donation" channel docs/DESIGN-
  VICTORY.md designates (materiel_delivery is mission-based and out of scope
  here). WarContrib.record's spool/flusher pipeline (war_contrib.lua) and the
  simulator's contribution fold already exist and already accept this source
  -- see this file's edit to war_contrib.lua's VALID_SOURCES. Nothing wrote
  those rows until now. This is the writer.

  WHY A SELF-LINKED CONVERSATION OPTION, NOT A NEW CONVERSATION SCREEN
  ----------------------------------------------------------------------
  ConversationOption:addOption(text, linkedScreenID) takes a literal string
  fine (ConversationScreen.h -- no "@" prefix means UnicodeString, not an stf
  key) -- that part is proven three times over already (see the task brief;
  war_recruiter.lua's own header makes the same point for spoken lines).
  What is NOT true is that a NEW linkedScreenID can be invented from Lua:
  ConversationObserverImplementation::getNextConversationScreen resolves the
  next screen with `convoTemp->getScreen(lastConversationScreen->
  getOptionLink(selectedOption))` -- a lookup into the COMPILED .conv
  template -- entirely in C++, before any Lua screen handler ever runs.
  LuaConversationTemplate's only Lua-exposed lookups are getScreen(existing
  id) and getInitialScreen(); there is no addScreen. So a linkedScreenID that
  is not already a real screen in the recruiter's .conv resource resolves to
  nil and the conversation silently ends.

  The fix used here: link the new option back to THE SAME screen ID it was
  offered on (greet_member_start_covert/overt/covert2/overt2 -- see
  OFFER_SCREENS below). That ID trivially already exists -- it is the screen
  the player is looking at. Reselecting it re-resolves the same template
  screen, and our wrap of RecruiterConvoHandler.runScreenHandlers (same
  monkey-patch shape as war_recruiter.lua's, chained the same way -- own
  stash field, vanilla/prior-wrap chain called first and unconditionally) is
  invoked again for that screen ID. The one piece of information it gets
  back is (screenID, selectedOption index). We record, per player per
  screen ID, the exact index our own option will occupy the moment we add
  it (screen:getOptionCount() before addOption == that option's index after
  -- Vector append semantics), in shared memory, and consult it on the next
  visit to that screen ID: a match means "the donate option was just
  clicked," a non-match (or no stored index) means the player picked
  something else on this screen, or nothing at all. The stored index is
  deleted the instant it is consulted, so it can only ever fire once per
  render.

  This never touches the recruiter's actual join/promotion/bribe/purchase
  branches -- our wrap calls the full existing chain FIRST, unconditionally,
  and only appends our option to whatever screen that chain already
  produced.

  THE TWO-STEP CONFIRMATION IS THE SUI ROUND TRIP, NOT A SECOND CONVO SCREEN
  ---------------------------------------------------------------------------
  Step 1 (WarDonate:offer): itemizes eligible root-inventory items, prices
  them, and opens an SUI MESSAGE BOX (LuaSuiManager:sendMessageBox, same
  binding chassisDealerConvoHandler.lua and junk_dealer.lua's sibling
  windows use) whose BODY TEXT is the itemization and whose OK button reads
  "Confirm donation." SUI text is exactly as free-form as a conversation
  option (see the same client-message plumbing junk_dealer.lua's
  "@loot_dealer:..." keys ride, or hologrind_jedi_manager.lua's fully
  literal SUI body for proof neither box type needs an stf key). The exact
  manifest (item object IDs + priced points) is stashed in shared memory
  keyed off the player, NOT recomputed from a live inventory scan when the
  box is answered -- what the player was shown is what executes.
  Step 2 (WarDonate:confirmDonation): the SUI callback. eventIndex == 1 is
  Cancel (see chassisDealerConvoHandler.lua:109's same convention) and takes
  nothing, records nothing. Anything else re-validates every stashed item
  (still exists, still parented directly under the SAME player's inventory,
  still eligible under isEligible -- an item could have been moved,
  equipped, or otherwise changed state in between) before destroying
  anything, so a stale manifest can only shrink, never fabricate an item
  that was not actually there.

  VALUATION -- quality-weighted, bounded, and named at the top of the file
  ---------------------------------------------------------------------------
  getMaxCondition() (LuaTangibleObject.cpp, live) is written from the
  crafting experimental attribute at craft time and varies by quality across
  both weapons and armor, per the task brief -- exactly the signal the owner
  ruled donations should be weighted by. POINTS_PER_CONDITION_POINT converts
  it to a materiel rate; MAX_POINTS_PER_ITEM hard-caps any single item
  regardless of condition, and MAX_ITEMS_PER_DONATION caps the whole hand-in
  batch, so one transaction has a known ceiling
  (MAX_POINTS_PER_ITEM * MAX_ITEMS_PER_DONATION) independent of whatever cap
  the simulator separately enforces per region/faction -- the task brief is
  explicit this value must be a rate, not a safety mechanism on its own.
  DONATE_COOLDOWN_MS additionally rate-limits repeat hand-ins per player,
  the same shared-memory cooldown idiom war_recruiter.lua's brief() already
  uses.

  CLOSING THE TWO NAMED LAUNDERING LOOPS
  -----------------------------------------
  1. factionPerkData.lua loop: perk items are BOUGHT with materiel (their
     `cost` fields, spent via faction standing/points elsewhere in
     recruiterScreenplay.lua). If a perk item could be donated back for
     materiel points, players could cycle materiel -> perk item -> materiel
     at whatever rate this file's valuation formula happens to produce,
     independent of the perk's actual cost -- free arbitrage. FORBIDDEN
     TEMPLATES below is built by walking rebelRewardData and
     imperialRewardData (factionPerkData.lua's own live tables, loaded
     earlier in the include chain -- see screenplays.lua) and collecting
     every reward entry's `item` template path, so it can never drift out of
     sync with that file by hand-copying. Any donated item whose
     getTemplateObjectPath() is in that set is rejected outright.
  2. Junk dealer loop: junk_dealer.lua already buys any item with
     getJunkValue() > 0 for cash (screenplays/junk_dealer/junk_dealer.lua:
     getEligibleJunk/sellItem). If this file accepted an item with a
     positive junk value, a player could choose per item whichever payout
     (cash from the junk dealer, or materiel from here) is worth more that
     day -- a floating-rate arbitrage between two independently-tuned
     currencies. isEligible below rejects ANY item with getJunkValue() > 0,
     full stop, so no donatable item has a cash-dealer alternative to
     arbitrage against; the two channels' item sets are disjoint by
     construction, not merely by convention.
]]

WarDonate = WarDonate or {}

-- ---------------------------------------------------------------------------
-- Tunables -- POLICY choices the owner will want to retune. Nothing below
-- this block should ever contain a bare number doing the same job.
-- ---------------------------------------------------------------------------

-- Materiel points awarded per point of an item's getMaxCondition(). 0.01
-- means a 1500-maxCondition crafted rifle is worth 15.0 points before the
-- per-item cap below; a rough-quality 300-maxCondition item is worth 3.0.
WarDonate.POINTS_PER_CONDITION_POINT = 0.01

-- Hard per-item ceiling, independent of condition, so no single absurdly
-- high-maxCondition item (or a future content patch that raises the
-- ceiling on crafted stats) can spike one donation arbitrarily.
WarDonate.MAX_POINTS_PER_ITEM = 15.0

-- How many eligible items one hand-in sweeps at most (the highest-value
-- ones, by points, are kept; the rest are simply left in the player's
-- inventory -- donate again for another batch).
WarDonate.MAX_ITEMS_PER_DONATION = 5

-- Minimum time between two SUCCESSFUL donations from the same player. This
-- is a belt-and-braces per-player throttle, not a substitute for the
-- simulator's own per-region/per-faction contribution cap (warsim already
-- owns that) -- see header.
WarDonate.DONATE_COOLDOWN_MS = 5 * 60 * 1000

-- How long a rendered "Donate materiel" option stays armed before a select
-- on that index is treated as stale and ignored (guards against a player
-- sitting on an old screen for a long time, then coincidentally picking the
-- same numeric slot on a much later, differently-composed render).
WarDonate.OPTION_ARM_WINDOW_MS = 5 * 60 * 1000

WarDonate.SOURCE = "materiel_donation"

WarDonate.DONATE_OPTION_TEXT = "Donate crafted goods to the war effort."

-- Screens on which the player has already been recognized as a MEMBER of
-- this recruiter's own faction (recruiterConvoHandler.lua's getInitialScreen
-- only reaches these when faction == recruiter's faction). Deliberately
-- excludes show_gcw_score (reachable before/without membership) and every
-- neutral/enemy/hated screen -- donating war materiel is a faction-member
-- action, not something a stranger does by wandering up.
WarDonate.OFFER_SCREENS = {
	["greet_member_start_covert"]  = true,
	["greet_member_start_overt"]   = true,
	["greet_member_start_covert2"] = true,
	["greet_member_start_overt2"]  = true,
}

-- ---------------------------------------------------------------------------
-- Forbidden-template set (laundering loop #1 -- see header)
-- ---------------------------------------------------------------------------

local forbiddenTemplatesCache = nil

local function buildForbiddenTemplates()
	local set = {}
	local sources = { rebelRewardData, imperialRewardData }

	for _, rewardData in ipairs(sources) do
		if type(rewardData) == "table" then
			for categoryName, category in pairs(rewardData) do
				-- Skip the *List sidecar arrays (factionPerkData.lua pairs
				-- e.g. weaponsArmorList with weaponsArmor) -- those hold
				-- plain string keys, not reward entries with an .item field.
				if type(category) == "table" and string.match(categoryName, "List$") == nil then
					for _, entry in pairs(category) do
						if type(entry) == "table" and type(entry.item) == "string" then
							set[entry.item] = true
						end
					end
				end
			end
		end
	end

	return set
end

--- Lazily built, then cached for the life of this Lua VM -- factionPerkData's
-- tables are static content data, not something that changes at runtime.
function WarDonate:forbiddenTemplates()
	if forbiddenTemplatesCache == nil then
		forbiddenTemplatesCache = buildForbiddenTemplates()
	end
	return forbiddenTemplatesCache
end

-- ---------------------------------------------------------------------------
-- Eligibility + valuation
-- ---------------------------------------------------------------------------

--- Returns true if pItem may be donated, or false plus a short reason.
-- Root-of-inventory and "not equipped" are enforced by the CALLER only ever
-- handing this items pulled directly from getSlottedObject("inventory")'s
-- own container listing (gatherManifest below) -- equipped items live in
-- other slots entirely and a sub-container's contents are never visited, so
-- neither case can reach this function in the first place.
function WarDonate:isEligible(pItem)
	if pItem == nil then
		return false, "missing"
	end

	local sceno = SceneObject(pItem)
	local tano = TangibleObject(pItem)

	-- Never destroy a container with something still inside it.
	if sceno:getContainerObjectsSize() ~= 0 then
		return false, "container"
	end

	if tano:isNoTrade() then
		return false, "no_trade"
	end

	if tano:isBroken() or tano:isSliced() then
		return false, "broken_or_sliced"
	end

	-- Laundering loop #2 -- see header. Reject outright, no exceptions.
	if tano:getJunkValue() > 0 then
		return false, "junk_arbitrage"
	end

	-- Laundering loop #1 -- see header.
	local templatePath = sceno:getTemplateObjectPath()
	if templatePath ~= nil and WarDonate:forbiddenTemplates()[templatePath] then
		return false, "faction_perk_item"
	end

	local maxCondition = tano:getMaxCondition()
	if maxCondition == nil or maxCondition <= 0 then
		return false, "no_condition"
	end

	return true, nil
end

--- Quality-weighted points for one already-eligible item. Callers must
-- check isEligible first -- this does not repeat those checks, only prices.
function WarDonate:pointsFor(pItem)
	local maxCondition = TangibleObject(pItem):getMaxCondition()
	local points = maxCondition * WarDonate.POINTS_PER_CONDITION_POINT

	if points > WarDonate.MAX_POINTS_PER_ITEM then
		points = WarDonate.MAX_POINTS_PER_ITEM
	end

	return points
end

--- Sweeps the player's root inventory (direct children of the "inventory"
-- slot only -- never recurses into a sub-container, so nothing not at the
-- root of the inventory is ever considered) for eligible items, prices
-- each, sorts richest-first, and caps at MAX_ITEMS_PER_DONATION.
function WarDonate:gatherManifest(pPlayer)
	local manifest = {}

	local pInventory = CreatureObject(pPlayer):getSlottedObject("inventory")
	if pInventory == nil then
		return manifest
	end

	local pInv = SceneObject(pInventory)

	for i = 0, pInv:getContainerObjectsSize() - 1, 1 do
		local pItem = pInv:getContainerObject(i)

		if pItem ~= nil then
			local eligible = WarDonate:isEligible(pItem)

			if eligible then
				table.insert(manifest, {
					oid = SceneObject(pItem):getObjectID(),
					name = SceneObject(pItem):getDisplayedName(),
					points = WarDonate:pointsFor(pItem),
				})
			end
		end
	end

	table.sort(manifest, function(a, b) return a.points > b.points end)

	while #manifest > WarDonate.MAX_ITEMS_PER_DONATION do
		table.remove(manifest)
	end

	return manifest
end

-- ---------------------------------------------------------------------------
-- Manifest stash (between the itemize step and the SUI confirm callback)
-- ---------------------------------------------------------------------------

local function manifestKey(pPlayer)
	return SceneObject(pPlayer):getObjectID() .. ":war:donateManifest"
end

--- oid1:pts1,oid2:pts2,... -- every field is a plain integer or a
-- fixed-format decimal, so there is nothing to escape.
local function serializeManifest(manifest)
	local parts = {}

	for i = 1, #manifest do
		table.insert(parts, manifest[i].oid .. ":" .. string.format("%.4f", manifest[i].points))
	end

	return table.concat(parts, ",")
end

local function deserializeManifest(s)
	local manifest = {}

	if s == nil or s == "" then
		return manifest
	end

	for oidStr, ptsStr in string.gmatch(s, "(%d+):([%d%.]+)") do
		table.insert(manifest, { oid = tonumber(oidStr), points = tonumber(ptsStr) })
	end

	return manifest
end

-- ---------------------------------------------------------------------------
-- Step 1: itemize + open the confirmation SUI
-- ---------------------------------------------------------------------------

function WarDonate:offer(pPlayer, pNpc)
	if pPlayer == nil or pNpc == nil then
		return
	end

	local manifest = WarDonate:gatherManifest(pPlayer)

	if #manifest == 0 then
		CreatureObject(pPlayer):sendSystemMessage(
			"You have nothing eligible to donate -- no-trade, broken, sliced, "
			.. "junk-sellable, and faction-perk items never qualify, and only "
			.. "loose items at the top level of your inventory are considered.")
		return
	end

	writeStringData(manifestKey(pPlayer), serializeManifest(manifest))

	local lines = {}
	local total = 0

	for i = 1, #manifest do
		table.insert(lines, string.format("%s -- %.1f pts", manifest[i].name, manifest[i].points))
		total = total + manifest[i].points
	end

	local body = "This will DESTROY the following items and convert them to war materiel:\n\n"
		.. table.concat(lines, "\n")
		.. string.format("\n\nTotal: %.1f materiel points. This cannot be undone.", total)

	local suiManager = LuaSuiManager()
	suiManager:sendMessageBox(pNpc, pPlayer, "Donate materiel", body, "Confirm donation", "WarDonate", "confirmDonation")
end

-- ---------------------------------------------------------------------------
-- Step 2: SUI confirm callback -- destroy, price, and record
-- ---------------------------------------------------------------------------

function WarDonate:destroyItem(pItem)
	if pItem == nil then
		return
	end

	SceneObject(pItem):destroyObjectFromWorld()
	SceneObject(pItem):destroyObjectFromDatabase()
end

function WarDonate:confirmDonation(pPlayer, pSui, eventIndex, arg0)
	if pPlayer == nil then
		return
	end

	local key = manifestKey(pPlayer)
	local raw = readStringData(key)
	deleteStringData(key)

	-- eventIndex == 1 is Cancel/close on an SUI message box (same
	-- convention chassisDealerConvoHandler.lua's own confirm boxes use).
	-- Nothing is taken, nothing is recorded.
	if eventIndex == 1 then
		return
	end

	local manifest = deserializeManifest(raw)
	if #manifest == 0 then
		return
	end

	local suiBox = LuaSuiBox(pSui)
	local pNpc = suiBox:getUsingObject()
	if pNpc == nil then
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()
	local cooldownKey = playerOid .. ":war:lastDonation"
	local last = readData(cooldownKey)
	local now = getTimestampMilli()

	if last ~= nil and last > 0 and (now - last) < WarDonate.DONATE_COOLDOWN_MS then
		CreatureObject(pPlayer):sendSystemMessage("You've donated recently -- give the quartermasters time to catch up.")
		return
	end

	-- Resolve region/faction BEFORE destroying anything -- a recruiter this
	-- doesn't map to a war region takes nothing, per the same "never guess"
	-- rule war_contrib_hook.lua follows for kills.
	local zoneName = SceneObject(pNpc):getZoneName()
	local x = SceneObject(pNpc):getWorldPositionX()
	local y = SceneObject(pNpc):getWorldPositionY()

	local regionId = nil
	if WarReport ~= nil and WarReport.regionAt ~= nil then
		regionId = WarReport.regionAt(zoneName, x, y)
	end

	local faction = (recruiterScreenplay ~= nil) and recruiterScreenplay:getRecruiterFaction(pNpc) or nil

	if regionId == nil or faction == nil then
		CreatureObject(pPlayer):sendSystemMessage("This outpost has no bearing on the front lines -- your goods are still yours.")
		return
	end

	-- Re-validate every stashed item against the LIVE object graph. An item
	-- can only have moved, been equipped, sold, or changed state since it
	-- was itemized -- never appear from nowhere -- so this can only shrink
	-- the manifest, never grow it.
	local pInventory = CreatureObject(pPlayer):getSlottedObject("inventory")
	if pInventory == nil then
		return
	end
	local inventoryOid = SceneObject(pInventory):getObjectID()

	local totalPoints = 0
	local takenNames = {}

	for i = 1, #manifest do
		local pItem = getSceneObject(manifest[i].oid)

		if pItem ~= nil and SceneObject(pItem):getParentID() == inventoryOid then
			local eligible = WarDonate:isEligible(pItem)

			if eligible then
				local pts = WarDonate:pointsFor(pItem)
				totalPoints = totalPoints + pts
				table.insert(takenNames, SceneObject(pItem):getDisplayedName())
				createEvent(10, "WarDonate", "destroyItem", pItem, "")
			end
		end
	end

	if totalPoints <= 0 then
		CreatureObject(pPlayer):sendSystemMessage("Nothing was still eligible by the time the quartermaster checked -- nothing was taken.")
		return
	end

	writeData(cooldownKey, now)

	local characterId = playerOid
	local recorded, reason = WarContrib.record(faction, regionId, WarDonate.SOURCE, totalPoints, characterId)

	if recorded then
		CreatureObject(pPlayer):sendSystemMessage(string.format(
			"You hand over %s to the %s war effort at %s -- %.1f materiel points.",
			table.concat(takenNames, ", "), faction, WarReport.regionName(regionId), totalPoints))
	else
		printf("WarDonate: WarContrib.record rejected (" .. tostring(reason)
			.. ") faction=" .. tostring(faction) .. " region=" .. tostring(regionId)
			.. " points=" .. tostring(totalPoints) .. "\n")
	end
end

-- ---------------------------------------------------------------------------
-- The conversation option itself
-- ---------------------------------------------------------------------------

function WarDonate:install()
	if RecruiterConvoHandler == nil or type(RecruiterConvoHandler) ~= "table" then
		printf("WarDonate: RecruiterConvoHandler is not a table -- materiel donation disabled, recruiters behave as stock.\n")
		return
	end

	if RecruiterConvoHandler._warDonateOriginalRSH ~= nil then
		return -- already wrapped in this VM incarnation
	end

	RecruiterConvoHandler._warDonateOriginalRSH = RecruiterConvoHandler.runScreenHandlers

	function RecruiterConvoHandler:runScreenHandlers(pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
		-- Vanilla, plus any earlier wrap (e.g. war_recruiter.lua's), first
		-- and unconditionally -- faction joining, promotions, bribes and
		-- briefings must all keep working even if everything below fails.
		local result = pConvScreen
		local okPrev, errPrev = pcall(function()
			local prev = RecruiterConvoHandler._warDonateOriginalRSH
			if prev ~= nil then
				result = prev(self, pConvTemplate, pPlayer, pNpc, selectedOption, pConvScreen)
			end
		end)
		if not okPrev then
			printf("WarDonate: chained runScreenHandlers raised: " .. tostring(errPrev) .. "\n")
			return result
		end

		pcall(function()
			if result == nil or pPlayer == nil or pNpc == nil then
				return
			end

			local screen = LuaConversationScreen(result)
			if screen == nil then
				return
			end

			local screenID = screen:getScreenID()
			local playerOid = SceneObject(pPlayer):getObjectID()
			local idxKey = playerOid .. ":war:donateOptIdx:" .. tostring(screenID)
			local timeKey = idxKey .. ":t"

			-- Did the player just select the donate option THIS screen ID
			-- rendered on its previous visit? (self-linked option -- see
			-- header.) Stored as index+1 so 0 unambiguously means "nothing
			-- stored" (shared memory has no distinct nil vs 0). Consumed
			-- immediately either way, so it can only fire once.
			local storedPlusOne = readData(idxKey)
			local storedAt = readData(timeKey)
			deleteData(idxKey)
			deleteData(timeKey)

			if storedPlusOne ~= nil and storedPlusOne > 0 and selectedOption == (storedPlusOne - 1) then
				local fresh = storedAt ~= nil and storedAt > 0
					and (getTimestampMilli() - storedAt) < WarDonate.OPTION_ARM_WINDOW_MS
				if fresh then
					WarDonate:offer(pPlayer, pNpc)
				end
			end

			if WarDonate.OFFER_SCREENS[screenID] then
				local recruiterFaction = recruiterScreenplay:getRecruiterFaction(pNpc)
				local playerFaction = recruiterScreenplay:getFactionFromHashCode(CreatureObject(pPlayer):getFaction())

				if recruiterFaction ~= nil and recruiterFaction == playerFaction then
					local newIndex = screen:getOptionCount()
					screen:addOption(WarDonate.DONATE_OPTION_TEXT, screenID)
					writeData(idxKey, newIndex + 1)
					writeData(timeKey, getTimestampMilli())
				end
			end
		end)

		return result
	end
end

WarDonate:install()
