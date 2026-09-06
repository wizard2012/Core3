--[[
  custom_scripts/screenplays/warreport/war_orders.lua

  Slice 8 (2026-09-06, autonomous run): orders from the officer -- the war
  hands a player a goal, watches them do it, and pays.

  Everything before this told a player the state of the war and what would
  move it; nothing gave them a job. The briefing officer's radial gains
  "Orders": one standing order per character, chosen from the map as it is
  at that moment, in this priority --

    line   Break the enemy's line at a front the player's side is fighting
           (own planet first, then the hottest): kill KILLS_NEEDED of their
           war troopers there. Progress comes from the kill hook's ledger
           records (npc_kill_faction / pvp_kill at that region).
    carry  Carry crates to a friendly town that is losing, dry, cut or
           strained (not a capital): requisition a supply crate and deliver
           it. Completion is the courier's materiel_delivery record there.
    hold   Hold the officer's own town for HOLD_MINUTES: a per-minute check
           counts the minutes the player stands inside the town's bounds.
    mend   (medics only -- a novice box in medic, combat medic or doctor)
           Keep the line standing at a front: heal MEND_POINTS crates' worth
           of the side's troopers there. Progress is the heal hook's
           materiel_support records (war_heal.lua: 0.002 a point of health),
           so it is the one order that moves crates while it is being done.
           Offered first to a medic, before the line orders.
    supply Donate SUPPLY_POINTS crates' worth of crafted goods or resources
           at any recruiter of the side (war_donate.lua's materiel_donation
           records, any town) -- the crafter's order, given after the carry
           orders and before holding.

  A completed order records `mission_completed` points at its town for the
  player's side under the player's character id -- standings and rank, the
  ledger's own unit -- and the next order skips the one just done. Orders
  lapse after EXPIRY_MS; during an intermission no line orders are given
  (the field is cleared and nothing can be broken).

  HOW PROGRESS IS SEEN: this module wraps WarContrib.record exactly the way
  war_contrib_counter.lua does (identity guard, re-installed on every
  include pass because war_contrib.lua resets the function), and observes
  every record that carries a character id. It is included AFTER the
  counter, so the counter sits beneath this wrapper and the completion
  record (written through the function beneath, never through this
  wrapper) still reaches it.

  STATE is shared string data, never a Lua table (every thread has its own
  VM): warorders:<oid> = "type|region|faction|need|done|issuedAt|expiresAt",
  warorders:last:<oid> = "type:region". Lost on a restart, like a lapse.

  The pure parts (candidates, pick, text, rewardText, statusLine, encode,
  decode) are pinned by bridge/tests/t_readouts.lua from the fixture; the
  engine parts by `test warOrdersCheck` (picks for both sides at the live
  officer posts, a synthetic order driven through observe with the record
  stubbed) and a client at an officer.
]]

WarOrders = WarOrders or {}

WarOrders.RADIAL_ID = 21
WarOrders.KILLS_NEEDED = 6
WarOrders.HOLD_MINUTES = 10
WarOrders.HOLD_CHECK_MS = 60 * 1000
WarOrders.EXPIRY_MS = 2 * 60 * 60 * 1000
WarOrders.POINTS = { line = 3.0, carry = 2.0, hold = 2.0, mend = 2.0, supply = 2.0 }
WarOrders.MEND_POINTS = 3.0             -- crates' worth of healing a mend order asks for
WarOrders.SUPPLY_POINTS = 2.0           -- crates' worth of donations a supply order asks for
WarOrders.MEDIC_SKILLS = { "science_medic_novice", "science_combatmedic_novice", "science_doctor_novice" }
WarOrders.SOURCE = "mission_completed"
WarOrders.KEY_PREFIX = "warorders:"
WarOrders.LAST_PREFIX = "warorders:last:"

local function key(oid)
	return WarOrders.KEY_PREFIX .. tostring(oid)
end

local function lastKey(oid)
	return WarOrders.LAST_PREFIX .. tostring(oid)
end

local function other(f)
	if f == "imperial" then
		return "rebel"
	elseif f == "rebel" then
		return "imperial"
	end
	return nil
end

local function adj(f)
	return (WarLines ~= nil and WarLines.ADJ ~= nil and WarLines.ADJ[f]) or tostring(f)
end

local function side(f)
	if WarLines ~= nil and WarLines.side ~= nil then
		return WarLines.side(f)
	end
	return tostring(f)
end

local function name(id)
	if WarLines ~= nil and WarLines.name ~= nil then
		return WarLines.name(id)
	end
	return tostring(id)
end

local function planetOf(id)
	if id == nil or WarLines == nil or WarLines.planetOf == nil then
		return nil
	end
	return WarLines.planetOf(id)
end

local function pointsText(p)
	if WarLines ~= nil and WarLines.pointsText ~= nil then
		return WarLines.pointsText(p)
	end
	return tostring(p) .. " points"
end

-- ------------------------------------------------------------- pure ----

--- "type|region|faction|need|done|issuedAt|expiresAt"
function WarOrders.encode(o)
	return table.concat({
		tostring(o.type), tostring(o.region), tostring(o.faction),
		tostring(math.floor(tonumber(o.need) or 0)), tostring(math.floor((tonumber(o.done) or 0) * 100 + 0.5)),
		tostring(math.floor(tonumber(o.issuedAt) or 0)), tostring(math.floor(tonumber(o.expiresAt) or 0)),
	}, "|")
end

function WarOrders.decode(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local t, r, f, need, done, issued, expires = string.match(raw, "^(%a+)|([%w_]+)|(%a+)|(%d+)|(%d+)|(%d+)|(%d+)$")
	if t == nil then
		return nil
	end
	local d = tonumber(done) / 100
	return {
		type = t, region = r, faction = f,
		need = tonumber(need), done = math.tointeger(d) or d,
		issuedAt = tonumber(issued), expiresAt = tonumber(expires),
	}
end

--- The candidates for a side from an officer's town, in order: the enemy
-- lines at the fronts the side is fighting (own planet first, then the
-- hottest), the friendly towns that need a crate (own planet first, the
-- soonest to fall), then holding the officer's own town. No line orders
-- once a season is won (the field is cleared for the intermission). A
-- medic (isMedic) is offered a mend order at each of those fronts first.
function WarOrders.candidates(st, faction, homeRegion, isMedic)
	local out = {}
	if st == nil or type(st.regions) ~= "table" or faction == nil then
		return out
	end
	local home = planetOf(homeRegion)
	local frozen = type(st.season) == "table" and st.season.winner ~= nil and st.season.winner ~= ""
	local lines = {}
	if not frozen then
		for _, fr in ipairs(st.fronts or {}) do
			local r = st.regions[fr.region]
			if r ~= nil and (fr.attacker == faction or r.faction == faction) then
				lines[#lines + 1] = {
					type = "line", region = fr.region, need = WarOrders.KILLS_NEEDED,
					intensity = tonumber(fr.intensity) or 0, same = (planetOf(fr.region) == home),
				}
			end
		end
	end
	table.sort(lines, function(a, b)
		if a.same ~= b.same then return a.same end
		if a.intensity ~= b.intensity then return a.intensity > b.intensity end
		return a.region < b.region
	end)
	if isMedic then
		for _, c in ipairs(lines) do
			out[#out + 1] = { type = "mend", region = c.region, need = WarOrders.MEND_POINTS, intensity = c.intensity, same = c.same }
		end
	end
	for _, c in ipairs(lines) do
		out[#out + 1] = c
	end
	local carries = {}
	local ids = {}
	for id, _ in pairs(st.regions) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local r = st.regions[id]
		local needy = (r.falls_in_ticks ~= nil) or r.road == "cut" or r.road == "strained"
		if r.faction == faction and not r.is_capital and needy and planetOf(id) ~= nil then
			carries[#carries + 1] = {
				type = "carry", region = id, need = 1,
				falls = tonumber(r.falls_in_ticks) or 1e9, same = (planetOf(id) == home),
			}
		end
	end
	table.sort(carries, function(a, b)
		if a.same ~= b.same then return a.same end
		if a.falls ~= b.falls then return a.falls < b.falls end
		return a.region < b.region
	end)
	for _, c in ipairs(carries) do
		out[#out + 1] = c
	end
	if homeRegion ~= nil and st.regions[homeRegion] ~= nil then
		out[#out + 1] = { type = "supply", region = homeRegion, need = WarOrders.SUPPLY_POINTS }
		out[#out + 1] = { type = "hold", region = homeRegion, need = WarOrders.HOLD_MINUTES }
	end
	return out
end

--- The next order: the first candidate that is not `last` ("type:region").
function WarOrders.pick(st, faction, homeRegion, last, isMedic)
	local cands = WarOrders.candidates(st, faction, homeRegion, isMedic)
	if #cands == 0 then
		return nil
	end
	local chosen = cands[1]
	for _, c in ipairs(cands) do
		if (c.type .. ":" .. c.region) ~= last then
			chosen = c
			break
		end
	end
	return { type = chosen.type, region = chosen.region, need = chosen.need, faction = faction, done = 0 }
end

--- The order as the officer says it.
function WarOrders.text(o, st)
	if o.type == "line" then
		local enemy = other(o.faction)
		return "Break the " .. side(enemy) .. "'s line at " .. name(o.region) .. ": kill " .. tostring(o.need)
			.. " " .. adj(enemy) .. " war troopers there."
	elseif o.type == "carry" then
		local r = st and type(st.regions) == "table" and st.regions[o.region] or nil
		local why = ""
		if r ~= nil then
			local fall = (WarLines ~= nil and WarLines.fallText ~= nil) and WarLines.fallText(r, st) or nil
			if fall ~= nil then
				why = " It " .. fall .. "."
			elseif r.road == "cut" then
				why = " Its road is cut."
			elseif r.road == "strained" then
				why = " Its road is strained."
			end
		end
		return "Carry crates to " .. name(o.region) .. ": requisition a supply crate from a quartermaster and deliver it there." .. why
	elseif o.type == "mend" then
		local health = ""
		if WarHeal ~= nil and tonumber(WarHeal.MATERIEL_PER_HEALED_POINT) ~= nil and WarHeal.MATERIEL_PER_HEALED_POINT > 0 then
			health = " (about " .. tostring(math.floor((tonumber(o.need) or 0) / WarHeal.MATERIEL_PER_HEALED_POINT + 0.5)) .. " points of health)"
		end
		return "Keep the line standing at " .. name(o.region) .. ": heal " .. pointsText(o.need) .. " of " .. adj(o.faction)
			.. " troopers there" .. health .. "."
	elseif o.type == "supply" then
		return "Supply the war: donate " .. pointsText(o.need) .. " of crafted goods or resources at a recruiter of your side."
	end
	return "Hold " .. name(o.region) .. ": stand your ground there for " .. tostring(o.need) .. " minutes."
end

function WarOrders.rewardText(o)
	local pts = WarOrders.POINTS[o.type] or 0
	local hours = math.floor(WarOrders.EXPIRY_MS / 3600000)
	return "Reward: " .. pointsText(pts) .. " on completion. Expires in " .. tostring(hours) .. " h."
end

--- What a completed order reads as.
function WarOrders.doneText(o)
	if o.type == "line" then
		return tostring(o.need) .. " " .. adj(other(o.faction)) .. " troopers down at " .. name(o.region) .. "."
	elseif o.type == "carry" then
		return "Crates delivered to " .. name(o.region) .. "."
	elseif o.type == "mend" then
		return "The line at " .. name(o.region) .. " stood: " .. pointsText(o.need) .. " of healing."
	elseif o.type == "supply" then
		return pointsText(o.need) .. " donated."
	end
	return name(o.region) .. " held."
end

--- "Orders: <text> -- 2 of 6 kills, ~2 h left."
function WarOrders.statusLine(o, st, nowMs)
	local left = math.max(0, (tonumber(o.expiresAt) or 0) - (tonumber(nowMs) or 0))
	local mins = math.floor(left / 60000 + 0.5)
	local leftText
	if mins >= 60 then
		leftText = "~" .. tostring(math.floor(mins / 60 + 0.5)) .. " h left"
	else
		leftText = tostring(mins) .. " min left"
	end
	local progress
	local done = tonumber(o.done) or 0
	if o.type == "line" then
		progress = tostring(math.floor(done)) .. " of " .. tostring(o.need) .. " kills"
	elseif o.type == "hold" then
		progress = tostring(math.floor(done)) .. " of " .. tostring(o.need) .. " minutes"
	elseif o.type == "mend" then
		progress = string.format("%.1f of %.1f crates' worth healed", done, tonumber(o.need) or 0)
	elseif o.type == "supply" then
		progress = string.format("%.1f of %.1f crates' worth donated", done, tonumber(o.need) or 0)
	else
		progress = "not delivered yet"
	end
	return "Orders: " .. WarOrders.text(o, st) .. " -- " .. progress .. ", " .. leftText .. "."
end

-- ----------------------------------------------------------- engine ----

local function factionOf(pPlayer)
	if WarStandings ~= nil and WarStandings.factionOf ~= nil then
		return WarStandings.factionOf(pPlayer)
	end
	local f = CreatureObject(pPlayer):getFaction()
	if f == FACTIONREBEL then
		return "rebel"
	elseif f == FACTIONIMPERIAL then
		return "imperial"
	end
	return nil
end

--- A novice box in medic, combat medic or doctor.
function WarOrders.isMedic(pPlayer)
	local medic = false
	pcall(function()
		local creature = CreatureObject(pPlayer)
		for _, skill in ipairs(WarOrders.MEDIC_SKILLS) do
			if creature:hasSkill(skill) then
				medic = true
				return
			end
		end
	end)
	return medic
end

function WarOrders.active(oid)
	return WarOrders.decode(readStringData(key(oid)))
end

function WarOrders.save(oid, o)
	writeStringData(key(oid), WarOrders.encode(o))
end

function WarOrders.clear(oid)
	writeStringData(key(oid), "")
end

--- The officer's "Orders" radial.
function WarOrders.onRadial(pPlayer, pOfficer)
	local creature = CreatureObject(pPlayer)
	local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
	if st == nil or type(st.regions) ~= "table" then
		creature:sendSystemMessage("The officer has no orders: the war reports nothing yet.")
		return
	end
	local faction = factionOf(pPlayer)
	if faction == nil then
		creature:sendSystemMessage("Orders are for the enlisted. Declare for a side first.")
		return
	end
	local oid = SceneObject(pPlayer):getObjectID()
	local now = getTimestampMilli()
	local o = WarOrders.active(oid)
	if o ~= nil and now >= (o.expiresAt or 0) then
		WarOrders.clear(oid)
		creature:sendSystemMessage("Your orders have lapsed.")
		o = nil
	end
	if o ~= nil then
		creature:sendSystemMessage(WarOrders.statusLine(o, st, now))
		return
	end
	local home = nil
	if WarOfficerReportMenuComponent ~= nil and WarOfficerReportMenuComponent.regionOf ~= nil then
		home = WarOfficerReportMenuComponent:regionOf(pOfficer)
	end
	local last = readStringData(lastKey(oid))
	o = WarOrders.pick(st, faction, home, last, WarOrders.isMedic(pPlayer))
	if o == nil then
		creature:sendSystemMessage("No orders today: nothing on the map needs you right now.")
		return
	end
	o.done = 0
	o.issuedAt = now
	o.expiresAt = now + WarOrders.EXPIRY_MS
	WarOrders.save(oid, o)
	creature:sendSystemMessage("Orders: " .. WarOrders.text(o, st))
	creature:sendSystemMessage(WarOrders.rewardText(o))
	if o.type == "hold" then
		createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
	end
	printf("WarOrders: " .. tostring(oid) .. " took " .. o.type .. " at " .. o.region .. " (" .. faction .. ")\n")
end

--- The order is done: the record, the message, the next order skips it.
function WarOrders.complete(oid, o, pPlayer)
	local pts = WarOrders.POINTS[o.type] or 0
	local recorded, reason = false, "no_record"
	if WarOrders._rawRecord ~= nil then
		recorded, reason = WarOrders._rawRecord(o.faction, o.region, WarOrders.SOURCE, pts, oid)
	end
	writeStringData(lastKey(oid), o.type .. ":" .. o.region)
	WarOrders.clear(oid)
	if pPlayer ~= nil then
		local creature = CreatureObject(pPlayer)
		creature:sendSystemMessage("Orders complete: " .. WarOrders.doneText(o) .. " " .. pointsText(pts) .. " to your name"
			.. (recorded and "." or (" (not recorded: " .. tostring(reason) .. ").")))
		creature:sendSystemMessage("See an officer for new orders.")
	end
	printf("WarOrders: " .. tostring(oid) .. " completed " .. o.type .. " at " .. o.region
		.. " recorded=" .. tostring(recorded) .. "\n")
end

--- Every ledger record with a character id passes through here.
function WarOrders.observe(faction, regionId, source, points, characterId)
	local oid = math.tointeger(tonumber(characterId))
	if oid == nil or oid <= 0 or source == WarOrders.SOURCE then
		return
	end
	local o = WarOrders.active(oid)
	if o == nil then
		return
	end
	local now = getTimestampMilli()
	if now >= (o.expiresAt or 0) then
		WarOrders.clear(oid)
		return
	end
	-- The order's side (a defector's old orders do not complete on the new
	-- side's record -- verifier note, 2026-09-06) and, except for a supply
	-- order (any recruiter of the side), the order's town.
	if o.faction ~= string.lower(tostring(faction)) then
		return
	end
	if o.type ~= "supply" and o.region ~= regionId then
		return
	end
	local pPlayer = getSceneObject(oid)
	if o.type == "line" and (source == "npc_kill_faction" or source == "pvp_kill") then
		o.done = (o.done or 0) + 1
		if o.done >= o.need then
			WarOrders.complete(oid, o, pPlayer)
		else
			WarOrders.save(oid, o)
			if pPlayer ~= nil then
				CreatureObject(pPlayer):sendSystemMessage("Orders: " .. tostring(o.done) .. " of " .. tostring(o.need) .. ".")
			end
		end
	elseif o.type == "carry" and source == "materiel_delivery" then
		o.done = 1
		WarOrders.complete(oid, o, pPlayer)
	elseif (o.type == "mend" and source == "materiel_support") or (o.type == "supply" and source == "materiel_donation") then
		local prev = tonumber(o.done) or 0
		o.done = prev + (tonumber(points) or 0)
		if o.done >= o.need then
			WarOrders.complete(oid, o, pPlayer)
		else
			WarOrders.save(oid, o)
			-- one line per whole crate's worth, not one per heal or hand-in
			if pPlayer ~= nil and math.floor(o.done) > math.floor(prev) then
				CreatureObject(pPlayer):sendSystemMessage(string.format("Orders: %.1f of %.1f crates' worth %s.",
					o.done, o.need, (o.type == "mend") and "healed" or "donated"))
			end
		end
	end
end

--- The per-minute check behind a hold order.
function WarOrders:holdCheck(pPlayer)
	if pPlayer == nil then
		return
	end
	pcall(function()
		local oid = SceneObject(pPlayer):getObjectID()
		local o = WarOrders.active(oid)
		if o == nil or o.type ~= "hold" then
			return
		end
		local now = getTimestampMilli()
		if now >= (o.expiresAt or 0) then
			WarOrders.clear(oid)
			CreatureObject(pPlayer):sendSystemMessage("Your orders have lapsed: " .. name(o.region) .. " was not held.")
			return
		end
		local here = nil
		if WarReport ~= nil and WarReport.regionAt ~= nil then
			here = WarReport.regionAt(SceneObject(pPlayer):getZoneName(),
				SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY())
		end
		if here == o.region then
			o.done = (o.done or 0) + 1
			if o.done >= o.need then
				WarOrders.complete(oid, o, pPlayer)
				return
			end
			WarOrders.save(oid, o)
			if o.done % 5 == 0 then
				CreatureObject(pPlayer):sendSystemMessage("Orders: " .. tostring(o.done) .. " of " .. tostring(o.need)
					.. " minutes at " .. name(o.region) .. ".")
			end
		end
		createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
	end)
end

--- The officer's report line for an active order, or nil.
function WarOrders.reportLine(pPlayer, st)
	local oid = SceneObject(pPlayer):getObjectID()
	local o = WarOrders.active(oid)
	if o == nil then
		return nil
	end
	local now = getTimestampMilli()
	if now >= (o.expiresAt or 0) then
		WarOrders.clear(oid)
		return nil
	end
	return WarOrders.statusLine(o, st, now)
end

-- The wrapper on WarContrib.record (see the header for why it re-installs).
function WarOrders._install()
	if WarContrib == nil or type(WarContrib) ~= "table" or WarContrib.record == nil then
		return
	end
	if WarOrders._installedWrapperRef == WarContrib.record then
		return
	end
	local rawRecord = WarContrib.record
	WarOrders._rawRecord = rawRecord
	local wrapped = function(faction, regionId, source, points, characterId)
		local recorded, reason = rawRecord(faction, regionId, source, points, characterId)
		if recorded then
			pcall(function() WarOrders.observe(faction, regionId, source, points, characterId) end)
		end
		return recorded, reason
	end
	WarContrib.record = wrapped
	WarOrders._installedWrapperRef = wrapped
end
WarOrders._install()

-- Console probe: test warOrdersCheck
if type(Tests) == "table" then
	function Tests:warOrdersCheck()
		printf("WARORDERS: begin\n")
		local ok, err = pcall(function()
			local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
			if st == nil then
				printf("WARORDERS: no war state\n")
				return
			end
			local posts = (WarOfficer ~= nil and WarOfficer.POSTS) or {}
			for _, faction in ipairs({ "imperial", "rebel" }) do
				for i = 1, math.min(#posts, 3) do
					local home = posts[i].region
					local o = WarOrders.pick(st, faction, home, nil)
					printf("WARORDERS: pick " .. faction .. "@" .. tostring(home) .. " | "
						.. (o and (o.type .. " " .. o.region .. " | " .. WarOrders.text(o, st)) or "none") .. "\n")
				end
				local n = #WarOrders.candidates(st, faction, posts[1] and posts[1].region or nil)
				printf("WARORDERS: candidates " .. faction .. " = " .. tostring(n) .. "\n")
			end
			-- a synthetic order driven through observe with the record stubbed
			local oid = 4242
			local saved = WarOrders._rawRecord
			local stubbed = {}
			WarOrders._rawRecord = function(f, r, s, p, c) stubbed[#stubbed + 1] = f .. "/" .. r .. "/" .. s .. "/" .. tostring(p) .. "/" .. tostring(c); return true end
			local now = getTimestampMilli()
			local o = { type = "line", region = "tat_anchorhead", faction = "rebel", need = 2, done = 0, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.save(oid, o)
			local back = WarOrders.active(oid)
			printf("WARORDERS: round-trip " .. tostring(back ~= nil and back.type == "line" and back.need == 2 and back.expiresAt == now + 60000) .. "\n")
			WarOrders.observe("rebel", "nab_theed", "npc_kill_faction", 0.15, oid)
			printf("WARORDERS: wrong region leaves done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("imperial", "tat_anchorhead", "npc_kill_faction", 0.15, oid)
			printf("WARORDERS: wrong side leaves done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("rebel", "tat_anchorhead", "npc_kill_faction", 0.15, oid)
			printf("WARORDERS: one kill done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("rebel", "tat_anchorhead", "pvp_kill", 2.0, oid)
			printf("WARORDERS: second kill completes: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[1]) .. " last=" .. tostring(readStringData(lastKey(oid))) .. "\n")
			local medic = WarOrders.pick(st, "rebel", posts[1] and posts[1].region or nil, nil, true)
			printf("WARORDERS: medic pick | " .. (medic and (medic.type .. " " .. medic.region .. " | " .. WarOrders.text(medic, st)) or "none") .. "\n")
			local m = { type = "mend", region = "tat_anchorhead", faction = "rebel", need = 3, done = 0, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.save(oid, m)
			WarOrders.observe("rebel", "tat_anchorhead", "materiel_support", 1.5, oid)
			printf("WARORDERS: mend after 1.5 done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("rebel", "tat_anchorhead", "materiel_support", 1.6, oid)
			printf("WARORDERS: mend completes: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[2]) .. "\n")
			local sup = { type = "supply", region = "tat_anchorhead", faction = "rebel", need = 2, done = 0, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.save(oid, sup)
			WarOrders.observe("rebel", "nab_theed", "materiel_donation", 2.5, oid)
			printf("WARORDERS: supply completes from any town: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[3]) .. "\n")
			WarOrders._rawRecord = saved
			writeStringData(lastKey(oid), "")
			printf("WARORDERS: wrapper installed=" .. tostring(WarContrib ~= nil and WarContrib.record == WarOrders._installedWrapperRef) .. "\n")
		end)
		if not ok then
			printf("WARORDERS: failed: " .. tostring(err) .. "\n")
		end
		printf("WARORDERS: end\n")
	end
end
