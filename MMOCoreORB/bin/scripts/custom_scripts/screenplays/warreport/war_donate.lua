--[[
  custom_scripts/screenplays/warreport/war_donate.lua

  The recruiter-hand-in half of the "materiel_donation" channel docs/DESIGN-
  VICTORY.md designates (materiel_delivery is mission-based and out of scope
  here). WarContrib.record's spool/flusher pipeline (war_contrib.lua) and the
  simulator's contribution fold already exist and already accept this source
  -- see this file's edit to war_contrib.lua's VALID_SOURCES. Nothing wrote
  those rows until now. This is the writer.

  REAL CONVERSATION SCREENS, NOT A SELF-LINK WORKAROUND (revised)
  -------------------------------------------------------------------------
  An earlier version of this file linked its donate option back to the SAME
  screen ID it was offered on, because ConversationObserverImplementation::
  getNextConversationScreen resolves getScreen(id) in C++ against a COMPILED
  template, and LuaConversationTemplate exposes no addScreen -- true, but
  incomplete: it is true of the .conv/IFF-backed template type, and false of
  this recruiter's actual template. The recruiter's conversation is
  templateType = "Lua" (mobile/conversations/recruiter/
  {rebel,imperial}_recruiter_conv.lua), built from plain ConvoScreen:new{}
  tables and ConvoTemplate:addScreen. ConversationTemplate::readObject
  (server/zone/objects/creature/conversation/ConversationTemplate.cpp) walks
  that Lua `screens` array ONCE AT BOOT and materializes a real
  ConversationScreen per entry into the SAME `screens` map getScreen() looks
  up at runtime -- so a screen added there is exactly as real as any stock
  screen, no workaround needed. The two new screens this adds --
  `donate_review` and `donate_execute` -- live in those two files, not here.

  Trade-off taken deliberately: mobile/ is boot-loaded (see CLAUDE.md's
  reload/rebuild/restart table), so a change to either conv file needs
  restart.sh (45-55s), not reload-lua.sh (~1.5s) -- accepted, because a
  genuine screen is far easier to reason about and verify than index
  tracking in shared memory on the one path in the game that destroys
  player property, and because the earlier mechanism's "arm key" could
  linger for a window on a screen a player merely visited without donating.
  That class of bug does not exist here: donate_review and donate_execute
  are reachable ONLY via the options this file adds -- there is nothing to
  arm or expire.

  What THIS file still does, exactly as before: it wraps
  RecruiterConvoHandler.runScreenHandlers (own stash field,
  _warDonateOriginalRSH; vanilla + any earlier wrap, e.g.
  war_recruiter.lua's, called first and unconditionally) to (a) append the
  donate option, as literal text, to the four "you are already a member"
  screens, and (b) react to donate_review (itemize) and donate_execute
  (execute) by name.

  THE TWO-STEP CONFIRMATION IS NOW TWO REAL SCREENS
  ---------------------------------------------------
  Step 1, donate_review: WarDonate:offer stashes the priced manifest for
  this player in shared memory and calls
  LuaConversationScreen(screen):setCustomDialogText(...) (a real Lua
  binding, LuaConversationScreen.cpp -- literal runtime text, same as
  covert_complete's and confirm_resign's existing customDialogText usage in
  the very same conv files) with the itemization. Its two static options
  are "Confirm donation" -> donate_execute and "Never mind." -> "" (ends
  the conversation, same convention every other "no" response in these
  files already uses). If nothing is eligible, the options are replaced
  with a single acknowledgement and nothing is stashed.
  Step 2, donate_execute: WarDonate:confirmDonation reads the stash,
  re-validates, and -- per the fix below -- only ever destroys what it has
  ALREADY successfully recorded.

  RECORD FIRST, DESTROY ONLY ON SUCCESS -- THE ORDERING FIX
  -------------------------------------------------------------------------
  An earlier version scheduled createEvent(10, "WarDonate", "destroyItem",
  ...) for each item INSIDE the re-validation loop, then called
  WarContrib.record afterward and only printf()'d on failure. A verifier
  reproduced this host-side: with log/warcontrib/ unwritable (the exact
  failure mode this project has already hit once, for the same bind-mounted
  log/ directory, when it turned up root-owned -- see CLAUDE.md's "deployed
  war_state.lua can end up root-owned" trap), WarContrib.record returns
  false, "open_failed" -- but the items were already gone, no spool line was
  written, no message told the player, and the per-player cooldown was
  still armed, throttling a player who had just been robbed for nothing.

  Fixed order: re-validate and price (unchanged) -> call WarContrib.record
  with the final total -> ONLY IF it returns true, schedule the destroys and
  arm the cooldown -> if it returns false, destroy nothing, arm nothing, and
  tell the player plainly that the donation could not be completed and their
  goods are untouched (the reason is also printf()'d for the log).

  Trade-off, stated rather than left implicit: this means a crash or
  process death in the narrow window between WarContrib.record returning
  true and the scheduled destroys actually firing could leave a player
  credited for items that still physically exist -- a double-counted
  materiel donation. That is the strictly better failure direction: a
  player who keeps both the credit and the goods has a visible, recoverable
  discrepancy (an admin can remove the duplicate item, or simply accept the
  windfall); a player who loses both has nothing to recover and no way to
  prove it happened. The window is bounded and small BY CONSTRUCTION, not
  merely by hope: every destroy for this donation is scheduled via
  createEvent(10, ...) (a 10ms delay -- the same delay junk_dealer.lua's own
  destroyItem event uses) in a tight loop immediately following the
  recorded == true check, with no intervening I/O, network wait, or other
  blocking call between the record succeeding and the last destroy being
  scheduled.

  The entire body of confirmDonation runs inside one pcall, so a Lua error
  partway through re-validation or the destroy-scheduling loop cannot leave
  the function having destroyed some items under a manifest it never
  finished pricing -- see the wrapping in confirmDonation below.

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
  uses -- and, per the fix above, is only ever armed on an actual recorded
  donation.

  CLOSING THE TWO NAMED LAUNDERING LOOPS
  -----------------------------------------
  1. factionPerkData.lua loop: perk items are BOUGHT with materiel (their
     cost fields, spent via faction standing/points elsewhere in
     recruiterScreenplay.lua). If a perk item could be donated back for
     materiel points, players could cycle materiel -> perk item -> materiel
     at whatever rate this file's valuation formula happens to produce,
     independent of the perk's actual cost -- free arbitrage. FORBIDDEN
     TEMPLATES below is built by walking rebelRewardData and
     imperialRewardData (factionPerkData.lua's own live tables, loaded
     earlier in the include chain -- see screenplays.lua) and collecting
     every reward entry's `item` template path, so it can never drift out of
     sync with that file by hand-copying. Any donated item whose
     getTemplateObjectPath() is in that set is rejected outright. KNOWN
     COLLATERAL, recorded rather than hidden: several of the rebel/imperial
     weaponsArmor entries reuse plain crafted-weapon templates as their perk
     reward item (carbine_laser, pistol_scout_blaster, the melee "sword_02"
     entry mislabeled metal_staff, lance_staff_metal, and the two mine
     templates) -- a player who crafts one of those exact weapons cannot
     donate it either, even though it was never bought as a perk. Accepted:
     the alternative (matching perk items by something other than template
     path) would be far more fragile, and these five templates are a small
     fraction of the game's craftable weapon catalogue.
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

  KNOWN LIMITATIONS, RECORDED RATHER THAN DISCOVERED LATER
  -------------------------------------------------------------------------
  Eligibility is "any tradeable, empty, junkValue == 0, maxCondition > 0
  item at inventory root" with the richest MAX_ITEMS_PER_DONATION such items
  auto-selected -- the player does not pick which items go. This sweeps in
  non-perk deeds and other maxCondition > 0 items whose "quality" is not
  really crafting-experimentation-driven (a deed's maxCondition is
  typically a template default, not a crafted stat). Both the auto-select
  and the deed inclusion are accepted for this pass as reasonably defensible
  defaults, not oversights -- flagged here for the owner to retune if not.
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

-- Minimum time between two SUCCESSFULLY RECORDED donations from the same
-- player. Only ever armed when WarContrib.record actually returns true --
-- see confirmDonation. Belt-and-braces per-player throttle, not a
-- substitute for the simulator's own per-region/per-faction contribution
-- cap (warsim already owns that).
WarDonate.DONATE_COOLDOWN_MS = 5 * 60 * 1000

WarDonate.SOURCE = "materiel_donation"

WarDonate.DONATE_OPTION_TEXT = "Donate crafted goods to the war effort."

-- The two real screens added to mobile/conversations/recruiter/
-- {rebel,imperial}_recruiter_conv.lua for this feature.
WarDonate.REVIEW_SCREEN = "donate_review"
WarDonate.EXECUTE_SCREEN = "donate_execute"

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

	-- A courier crate is worth materiel only where it is bound for. Letting
	-- it be donated here would pay twice for one item (or once for zero
	-- travel). war_courier.lua stamps every crate it issues with its owner.
	local courierOwner = readData(tostring(sceno:getObjectID()) .. ":war:courier:owner")
	if courierOwner ~= nil and courierOwner > 0 then
		return false, "courier_crate"
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
-- Manifest stash (between the review screen and the execute screen)
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
-- Step 1 (donate_review): itemize + stash the manifest
-- ---------------------------------------------------------------------------

--- Called when the player enters the donate_review screen. Mutates the
-- already-cloned `screen` in place (setCustomDialogText / removeAllOptions
-- / addOption all act on the same underlying ConversationScreen the
-- template produced -- see LuaConversationScreen.cpp) so the itemization
-- reaches the player on the very screen the conv template already routed
-- them to. Nothing is destroyed here -- this step only looks and prices.
function WarDonate:offer(pPlayer, screen)
	if pPlayer == nil or screen == nil then
		return
	end

	local manifest = WarDonate:gatherManifest(pPlayer)

	if #manifest == 0 then
		deleteStringData(manifestKey(pPlayer))
		screen:setCustomDialogText(
			"You have nothing eligible to donate -- no-trade, broken, sliced, "
			.. "junk-sellable, and faction-perk items never qualify, and only "
			.. "loose items at the top level of your inventory are considered.")
		screen:removeAllOptions()
		screen:addOption("Understood.", "")
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

	screen:setCustomDialogText(body)
	-- Options are the static "Confirm donation" / "Never mind." pair
	-- already defined on the donate_review screen in the conv template --
	-- nothing to add here.
end

-- ---------------------------------------------------------------------------
-- Step 2 (donate_execute): record first, destroy only on success
-- ---------------------------------------------------------------------------

function WarDonate:destroyItem(pItem)
	if pItem == nil then
		return
	end

	SceneObject(pItem):destroyObjectFromWorld()
	SceneObject(pItem):destroyObjectFromDatabase()
end

--- Called when the player enters the donate_execute screen (i.e. selected
-- "Confirm donation" on donate_review). pNpc is the SAME NPC object
-- runScreenHandlers already received as its own third argument for this
-- exact conversation turn -- no session lookup needed. Entirely
-- pcall-wrapped: a Lua error anywhere in here must not be able to leave a
-- half-completed donation.
function WarDonate:confirmDonation(pPlayer, pNpc, screen)
	if pPlayer == nil then
		return
	end

	local ok, err = pcall(function()
		WarDonate:_confirmDonation(pPlayer, pNpc, screen)
	end)

	if not ok then
		printf("WarDonate:confirmDonation failed, swallowed: " .. tostring(err) .. "\n")
		if screen ~= nil then
			pcall(function()
				screen:setCustomDialogText("Something went wrong and your donation could not be processed. Nothing was taken.")
			end)
		end
	end
end

function WarDonate:_confirmDonation(pPlayer, pNpc, screen)
	local key = manifestKey(pPlayer)
	local raw = readStringData(key)
	deleteStringData(key)

	local manifest = deserializeManifest(raw)
	if #manifest == 0 then
		if screen ~= nil then
			screen:setCustomDialogText("There was nothing staged to donate.")
		end
		return
	end

	local playerOid = SceneObject(pPlayer):getObjectID()
	local cooldownKey = playerOid .. ":war:lastDonation"
	local last = readData(cooldownKey)
	local now = getTimestampMilli()

	if last ~= nil and last > 0 and (now - last) < WarDonate.DONATE_COOLDOWN_MS then
		if screen ~= nil then
			screen:setCustomDialogText("You've donated recently -- give the quartermasters time to catch up. Nothing was taken.")
		end
		return
	end

	if pNpc == nil then
		if screen ~= nil then
			screen:setCustomDialogText("The quartermaster stepped away. Nothing was taken -- try again.")
		end
		return
	end

	-- Resolve region/faction BEFORE re-validating or recording anything --
	-- a recruiter this doesn't map to a war region takes nothing, per the
	-- same "never guess" rule war_contrib_hook.lua follows for kills.
	local zoneName = SceneObject(pNpc):getZoneName()
	local x = SceneObject(pNpc):getWorldPositionX()
	local y = SceneObject(pNpc):getWorldPositionY()

	local regionId = nil
	if WarReport ~= nil and WarReport.regionAt ~= nil then
		regionId = WarReport.regionAt(zoneName, x, y)
	end

	local faction = (recruiterScreenplay ~= nil) and recruiterScreenplay:getRecruiterFaction(pNpc) or nil

	if regionId == nil or faction == nil then
		if screen ~= nil then
			screen:setCustomDialogText("This outpost has no bearing on the front lines -- your goods are still yours. Nothing was taken.")
		end
		return
	end

	-- Re-validate every stashed item against the LIVE object graph. An item
	-- can only have moved, been equipped, sold, or changed state since it
	-- was itemized -- never appear from nowhere -- so this can only shrink
	-- the manifest, never grow it. NOTHING IS DESTROYED IN THIS LOOP.
	local pInventory = CreatureObject(pPlayer):getSlottedObject("inventory")
	if pInventory == nil then
		if screen ~= nil then
			screen:setCustomDialogText("Could not reach your inventory. Nothing was taken.")
		end
		return
	end
	local inventoryOid = SceneObject(pInventory):getObjectID()

	local validItems = {}
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
				table.insert(validItems, pItem)
			end
		end
	end

	if totalPoints <= 0 then
		if screen ~= nil then
			screen:setCustomDialogText("Nothing was still eligible by the time the quartermaster checked -- nothing was taken.")
		end
		return
	end

	-- RECORD FIRST. Only on a confirmed success do we touch the player's
	-- items or the cooldown -- see this file's header for the ordering
	-- rationale and the bounded window that follows a success.
	local characterId = playerOid
	local recorded, reason = WarContrib.record(faction, regionId, WarDonate.SOURCE, totalPoints, characterId)

	if not recorded then
		printf("WarDonate: WarContrib.record rejected (" .. tostring(reason)
			.. ") faction=" .. tostring(faction) .. " region=" .. tostring(regionId)
			.. " points=" .. tostring(totalPoints) .. "\n")
		if screen ~= nil then
			screen:setCustomDialogText(
				"The quartermaster's ledger could not be reached -- your donation was NOT recorded "
				.. "and nothing was taken. Please try again in a moment.")
		end
		return
	end

	-- Recorded successfully -- NOW destroy, immediately and in a tight
	-- loop with no intervening blocking call (see header for the bounded-
	-- window reasoning), and arm the cooldown.
	for i = 1, #validItems do
		createEvent(10, "WarDonate", "destroyItem", validItems[i], "")
	end

	writeData(cooldownKey, now)

	if screen ~= nil then
		screen:setCustomDialogText(string.format(
			"You hand over %s to the %s war effort at %s -- %.1f materiel points.",
			table.concat(takenNames, ", "), faction, WarReport.regionName(regionId), totalPoints))
	end
end

-- ---------------------------------------------------------------------------
-- The conversation wiring
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
			if result == nil or pPlayer == nil then
				return
			end

			local screen = LuaConversationScreen(result)
			if screen == nil then
				return
			end

			local screenID = screen:getScreenID()

			if screenID == WarDonate.REVIEW_SCREEN then
				WarDonate:offer(pPlayer, screen)
				return
			end

			if screenID == WarDonate.EXECUTE_SCREEN then
				WarDonate:confirmDonation(pPlayer, pNpc, screen)
				return
			end

			if pNpc ~= nil and WarDonate.OFFER_SCREENS[screenID] then
				local recruiterFaction = recruiterScreenplay:getRecruiterFaction(pNpc)
				local playerFaction = recruiterScreenplay:getFactionFromHashCode(CreatureObject(pPlayer):getFaction())

				if recruiterFaction ~= nil and recruiterFaction == playerFaction then
					screen:addOption(WarDonate.DONATE_OPTION_TEXT, WarDonate.REVIEW_SCREEN)
				end
			end
		end)

		return result
	end
end

WarDonate:install()
