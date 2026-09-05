--[[
  custom_scripts/screenplays/warreport/war_tick_tally.lua

  Layer 1 of the feedback stack (owner ruling, 2026-09-04): a player who does
  the thing that moves the war should SEE it register, immediately, in
  in-universe terms -- not discover it fifteen minutes later as a map pin.

  WHAT IT TRACKS. A per-player, per-region running total for the CURRENT
  fifteen-minute window. That window is exactly what the simulation evaluates:
  the cron fires */15, so its tick boundaries are the quarter hours, and
  floor(os.time() / 900) lands on the same boundaries (epoch multiples of 900
  are quarter hours in UTC). "This window" therefore means "the window the
  sim is about to read", which is the only reason the readout can honestly
  tell a player their effort is about to count.

  WHAT IT SAYS. Tiered, in WarVoice's words, never a number:
    counted  -- below the force threshold, or thresholds not available
    force    -- this player alone has cleared player_forced_front_min_contrib
    cap      -- this player alone has cleared player_contrib_cap_region
  The thresholds come from WAR_STATE.thresholds, written by
  bridge/export_war_state.lua from warsim/config.lua. They are NOT duplicated
  here: if the deployed state predates that field, the readout simply stays
  on the "counted" tier rather than ever showing a stale or invented cut-off.

  HOW IT HOOKS. Exactly the wrapper pattern war_contrib_counter.lua uses, for
  exactly its reasons: wrap WarContrib.record rather than every call site, and
  re-install on every include because a reload re-runs war_contrib.lua's
  unconditional `function WarContrib.record` and would silently drop us. The
  counter wraps first (screenplays.lua order); we wrap whatever record is by
  the time we load. Each wrapper checks its own _installedWrapperRef, so the
  two never double-wrap and never fight.

  SAME THREAD LIMIT AS THE COUNTER. add() resolves the player by OID on the
  calling thread; if that fails the add is dropped, as the counter's is. Not
  fixed here -- documented so nobody spends a session on it.

  RATE LIMIT. One readout per player per MSG_COOLDOWN_S. At twelve NPCs a
  site this would otherwise be a firehose. Suppression loses nothing: the
  tally keeps accumulating and the next line reports the whole of it.

  STORAGE. screenPlayState on the creature, in centipoints, same idiom as
  the counter. Keys:
    war_tick_bucket        the window the pts_* keys belong to
    war_tick_lastmsg       epoch seconds of the last readout sent
    war_tick_pts_<region>  centipoints this window, one key per region
  A bucket change zeroes every pts key, so nothing accumulates across
  windows and the key set is bounded by the region list.
]]

WarTickTally = WarTickTally or {}

WarTickTally.BUCKET_SECONDS = 900
WarTickTally.MSG_COOLDOWN_S = 10

WarTickTally.KEY_BUCKET  = "war_tick_bucket"
WarTickTally.KEY_LASTMSG = "war_tick_lastmsg"
WarTickTally.KEY_PTS     = "war_tick_pts_"

local function bucketNow()
	return math.floor(os.time() / WarTickTally.BUCKET_SECONDS)
end

local function ptsKey(regionId)
	return WarTickTally.KEY_PTS .. tostring(regionId)
end

--- Thresholds from the deployed state, or nil when it does not carry them.
local function thresholds()
	if WAR_STATE == nil or type(WAR_STATE.thresholds) ~= "table" then
		return nil
	end
	local t = WAR_STATE.thresholds
	if type(t.force_front) ~= "number" or type(t.cap_region) ~= "number" then
		return nil
	end
	return t
end

--- Zero every region's window total. Called when the bucket rolls.
local function resetWindow(creature)
	if WarReport == nil or WarReport.regionIds == nil then
		return
	end
	local ids = WarReport.regionIds()
	for i = 1, #ids do
		creature:setScreenPlayState(0, ptsKey(ids[i]))
	end
end

--- Add `points` for `characterId` at `regionId` in the current window, then
-- maybe speak. Never raises.
function WarTickTally:add(characterId, regionId, points)
	local oid = tonumber(characterId)
	local pts = tonumber(points)
	if oid == nil or oid <= 0 or pts == nil or pts <= 0 or regionId == nil then
		return
	end

	local pPlayer = getSceneObject(oid)
	if pPlayer == nil or not SceneObject(pPlayer):isPlayerCreature() then
		return -- not resolvable on this thread; same limit as the counter
	end
	local creature = CreatureObject(pPlayer)

	local nowBucket = bucketNow()
	if creature:getScreenPlayState(WarTickTally.KEY_BUCKET) ~= nowBucket then
		resetWindow(creature)
		creature:setScreenPlayState(nowBucket, WarTickTally.KEY_BUCKET)
	end

	local key = ptsKey(regionId)
	local centi = creature:getScreenPlayState(key) + math.floor((pts * 100) + 0.5)
	creature:setScreenPlayState(centi, key)

	WarTickTally:maybeSpeak(pPlayer, creature, regionId, centi / 100.0)
end

--- Send one readout if the cooldown has passed.
function WarTickTally:maybeSpeak(pPlayer, creature, regionId, windowPts)
	local nowS = os.time()
	local last = creature:getScreenPlayState(WarTickTally.KEY_LASTMSG)
	if last ~= nil and last > 0 and (nowS - last) < WarTickTally.MSG_COOLDOWN_S then
		return
	end
	creature:setScreenPlayState(nowS, WarTickTally.KEY_LASTMSG)

	if WarVoice == nil or WarVoice.readout == nil then
		return -- voice table not loaded on this thread; say nothing wrong
	end

	local tier = "counted"
	local t = thresholds()
	if t ~= nil then
		if windowPts >= t.cap_region then
			tier = "cap"
		elseif windowPts >= t.force_front then
			tier = "force"
		end
	end

	local faction = (creature:getFaction() == FACTIONREBEL) and "rebel" or "imperial"
	local name = regionId
	if WarReport ~= nil and WarReport.regionName ~= nil then
		name = WarReport.regionName(regionId)
	end

	pcall(function()
		creature:sendSystemMessage(WarVoice.readout(faction, name, tier))
	end)
end

--- Wrap WarContrib.record, exactly as war_contrib_counter.lua does.
function WarTickTally._install()
	if WarContrib == nil or type(WarContrib) ~= "table" or WarContrib.record == nil then
		printf("WarTickTally: WarContrib.record not visible; window tally disabled on this thread.\n")
		return
	end
	if WarTickTally._installedWrapperRef == WarContrib.record then
		return -- this exact wrapper is already installed; do not double-wrap
	end

	local rawRecord = WarContrib.record
	local wrapped = function(faction, regionId, source, points, characterId)
		local recorded, reason = rawRecord(faction, regionId, source, points, characterId)
		if recorded then
			pcall(function() WarTickTally:add(characterId, regionId, points) end)
		end
		return recorded, reason
	end

	WarContrib.record = wrapped
	WarTickTally._installedWrapperRef = wrapped
end

WarTickTally._install()

--- Server-side proof this thread has the tally wrapped in and can see the
-- thresholds the readout tiers on. Cannot prove a player sees a line.
function Tests:warTickTallyCheck()
	printf("WARTICKTALLY: begin\n")
	printf("WARTICKTALLY: wrapper installed=" .. tostring(WarTickTally._installedWrapperRef ~= nil
		and WarTickTally._installedWrapperRef == WarContrib.record) .. "\n")
	printf("WARTICKTALLY: WarVoice loaded=" .. tostring(WarVoice ~= nil and WarVoice.readout ~= nil) .. "\n")
	local t = thresholds()
	if t == nil then
		printf("WARTICKTALLY: thresholds ABSENT from WAR_STATE -- readout will stay on the counted tier\n")
	else
		printf("WARTICKTALLY: thresholds force_front=" .. tostring(t.force_front)
			.. " cap_region=" .. tostring(t.cap_region) .. "\n")
	end
	printf("WARTICKTALLY: bucket now=" .. tostring(bucketNow()) .. " (" .. tostring(WarTickTally.BUCKET_SECONDS) .. "s windows)\n")
	if WarVoice ~= nil then
		printf("WARTICKTALLY: sample :: " .. WarVoice.readout("imperial", "Doaba Guerfel", "force") .. "\n")
		printf("WARTICKTALLY: sample :: " .. tostring(WarVoice.dispatch("Doaba Guerfel", "imperial", 3, 7)) .. "\n")
	end
	printf("WARTICKTALLY: end\n")
end
