--[[
  custom_scripts/screenplays/warreport/war_orders.lua

  Slice 8 (2026-09-06, autonomous run): orders from the officer -- the war
  hands a player a goal, watches them do it, and pays. Slice 10 (the same
  day, owner: "do all professions have a purpose? if not make sure"): an
  order for every profession.

  Everything before this told a player the state of the war and what would
  move it; nothing gave them a job. The briefing officer's radial gains
  "Orders": one standing order per character, chosen from the map as it is
  at that moment. What the player's skills say comes first, then the
  general orders --

    mend     (medic, combat medic, doctor) Keep the line standing at a
             front: heal MEND_POINTS crates' worth of the side's troopers
             there -- the heal hook's materiel_support records.
    rally    (entertainer, musician, dancer) Rally the garrison at a
             friendly town with a front (or the officer's own): play or
             dance there for HOLD_MINUTES. Pays a real RALLY_SUPPORT
             crates' worth of morale (materiel_support) at the town.
    scout    (scout, ranger) Scout an enemy town: get inside it and stay
             SCOUT_MINUTES. The report is SCOUT_POINTS of combat
             contribution at that town -- the sim's forced-front threshold
             -- so the next front opens where the scout went.
    blockade (smuggler) Run the blockade into a friendly town whose road
             is cut: a courier crate delivered there, at BLOCKADE pay.
    hunt     (bounty hunter) Bring down HUNT_KILLS enemy players, anywhere.
    line     Break the enemy's line at a front the side is fighting (own
             planet first, then the hottest): kill KILLS_NEEDED of their
             war troopers there -- the kill hook's records.
    carry    Carry crates to a friendly town that is losing, dry, cut or
             strained (not a capital): a courier crate delivered there.
    supply   Supply the war: the line needs <category> (weapons, armour,
             medicine, food, clothing -- rotating every six hours) --
             donate SUPPLY_POINTS crates' worth of it at any recruiter of
             the side. The crafter's order; war_donate.lua writes what was
             donated by category (warcontrib:lastdonation:<oid>).
    hold     Hold the officer's own town for HOLD_MINUTES.

  A completed order records `mission_completed` points at its town for the
  player's side under the player's character id -- standings and rank --
  and the next order skips the one just done. Orders lapse after
  EXPIRY_MS; during an intermission no line, mend, rally or scout orders
  are given (the field is cleared and nothing can be broken).

  HOW PROGRESS IS SEEN: this module wraps WarContrib.record exactly the way
  war_contrib_counter.lua does (identity guard, re-installed on every
  include pass because war_contrib.lua resets the function), and observes
  every record that carries a character id. It is included AFTER the
  counter, so the counter sits beneath this wrapper and the completion
  record (written through the function beneath, never through this
  wrapper) still reaches it. Presence orders (hold, rally, scout) run a
  per-minute check (createEvent) instead.

  STATE is shared string data, never a Lua table (every thread has its own
  VM): warorders:<oid> = "type|region|faction|need|done|issuedAt|expiresAt|extra"
  (done in hundredths; extra is the supply category), warorders:last:<oid>
  = "type:region". Lost on a restart, like a lapse.

  The pure parts (categoryOf, candidates, pick, text, rewardText,
  doneText, statusLine, encode, decode, supplyCategory) are pinned by
  bridge/tests/t_readouts.lua from the fixture; the engine parts by `test
  warOrdersCheck` and a client at an officer.
]]

WarOrders = WarOrders or {}

WarOrders.RADIAL_ID = 21
WarOrders.KILLS_NEEDED = 6
WarOrders.HOLD_MINUTES = 10
WarOrders.SCOUT_MINUTES = 3
WarOrders.HUNT_KILLS = 2
WarOrders.SKY_KILLS = 3   -- B61 S2: a pilot's order -- war ships down over the home planet
WarOrders.ESCORT_MINUTES = 2   -- B61 S4: minutes within WarSpace.ESCORT_RANGE_M of the freighter for the escort to count
WarOrders.HOLD_CHECK_MS = 60 * 1000
WarOrders.EXPIRY_MS = 2 * 60 * 60 * 1000
WarOrders.POINTS = { line = 3.0, carry = 2.0, hold = 2.0, mend = 2.0, supply = 2.0, rally = 2.0, scout = 3.0, blockade = 4.0, hunt = 4.0, sky = 4.0,
	escort = 4.0, picket = 6.0 }  -- B61 S4: the convoy seen in; the enemy picket wiped
WarOrders.ORBIT_OF = { cor = "cor_orbit", nab = "nab_orbit", tat = "tat_orbit" }  -- B61 S2: the sky over a region's planet
WarOrders.MEND_POINTS = 3.0             -- crates' worth of healing a mend order asks for
WarOrders.SUPPLY_POINTS = 6.0           -- crates' worth of donations a supply order asks for: crafted goods price
                                        -- at up to 15 a stack (war_donate.lua), so two would be one hand-in
WarOrders.RALLY_SUPPORT = 2.0           -- crates' worth of morale a rally puts into the town (materiel_support)
WarOrders.SCOUT_POINTS = 3.0            -- combat points at the scouted town: the sim's forced-front threshold
WarOrders.SOURCE = "mission_completed"
WarOrders.KEY_PREFIX = "warorders:"
WarOrders.LAST_PREFIX = "warorders:last:"
WarOrders.DONATION_PREFIX = "warcontrib:lastdonation:"
WarOrders.MEDIC_SKILLS = { "science_medic_novice", "science_combatmedic_novice", "science_doctor_novice" }
WarOrders.ENTERTAINER_SKILLS = { "social_entertainer_novice", "social_musician_novice", "social_dancer_novice" }
WarOrders.SCOUT_SKILLS = { "outdoors_scout_novice", "outdoors_ranger_novice" }
WarOrders.SMUGGLER_SKILLS = { "combat_smuggler_novice" }
WarOrders.HUNTER_SKILLS = { "combat_bountyhunter_novice" }
WarOrders.SUPPLY_CATEGORIES = { "weapons", "armour", "medicine", "food", "clothing" }
WarOrders.SUPPLY_ROTATION_TICKS = 24

WarOrders.RAID_AT_MINUTE = 2               -- B44 garrison duty: the raid comes this many held minutes in
WarOrders.RAID_SIZE = 4                    -- raiders: a sergeant, a medic, two riflemen
WarOrders.RAID_DISTANCE_M = 60             -- they start this far from the player, on a meshed point
WarOrders.WP_PREFIX = "warorders:wp:"      -- the datapad waypoint an order placed (its object id)
WarOrders.INDEX_KEY = "warorders:index"     -- B47: the oids with an active order, comma-separated
WarOrders.STATE_FILE = "log/warorders.state" -- B47: the disk mirror (shared string data dies with the process)
WarOrders.RESTORED_KEY = "warorders:restored_ms" -- B47: set once per process by restoreFromDisk
WarOrders.CHAIN_PREFIX = "warorders:chain:"  -- B47: the last holdCheck tick per oid (a chain that stopped is restarted at login)
WarOrders.WAYPOINT_COLOR = 3              -- not the recruiter's front-line colour (2), so the two read apart
WarOrders.WAYPOINT_TYPE = 1101            -- our own specialTypeID: the engine keeps one pin of a type, and the
                                          -- login sweep (sweepWaypoints) can find a pin a restart orphaned

local function key(oid)
	return WarOrders.KEY_PREFIX .. tostring(oid)
end

local function lastKey(oid)
	return WarOrders.LAST_PREFIX .. tostring(oid)
end

local function donationKey(oid)
	return WarOrders.DONATION_PREFIX .. tostring(oid)
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

local function hasFront(st, regionId)
	for _, fr in ipairs(st.fronts or {}) do
		if fr.region == regionId then
			return true
		end
	end
	return false
end

-- ------------------------------------------------------------- pure ----

--- "type|region|faction|need|done|issuedAt|expiresAt|extra"
function WarOrders.encode(o)
	return table.concat({
		tostring(o.type), tostring(o.region), tostring(o.faction),
		tostring(math.floor(tonumber(o.need) or 0)), tostring(math.floor((tonumber(o.done) or 0) * 100 + 0.5)),
		tostring(math.floor(tonumber(o.issuedAt) or 0)), tostring(math.floor(tonumber(o.expiresAt) or 0)),
		tostring(o.extra or ""),
	}, "|")
end

function WarOrders.decode(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local t, r, f, need, done, issued, expires, extra = string.match(raw, "^(%a+)|([%w_]+)|(%a+)|(%d+)|(%d+)|(%d+)|(%d+)|?([%w_]*)$")
	if t == nil then
		return nil
	end
	local d = tonumber(done) / 100
	return {
		type = t, region = r, faction = f,
		need = tonumber(need), done = math.tointeger(d) or d,
		issuedAt = tonumber(issued), expiresAt = tonumber(expires),
		extra = (extra ~= nil and extra ~= "") and extra or nil,
	}
end

--- A donated item's category from its template path.
function WarOrders.categoryOf(path)
	path = tostring(path or "")
	if path:find("^object/weapon/") then
		return "weapons"
	elseif path:find("^object/tangible/wearables/armor/") then
		return "armour"
	elseif path:find("^object/tangible/medicine/") then
		return "medicine"
	elseif path:find("^object/tangible/food/") or path:find("^object/tangible/drink/") then
		return "food"
	elseif path:find("^object/tangible/wearables/") then
		return "clothing"
	end
	return "goods"
end

--- What the line needs this six hours.
function WarOrders.supplyCategory(st)
	local tick = tonumber(st and st.generated_at_tick) or 0
	local cats = WarOrders.SUPPLY_CATEGORIES
	return cats[(math.floor(tick / WarOrders.SUPPLY_ROTATION_TICKS) % #cats) + 1]
end

--- The candidates for a player from an officer's town, in order: what the
-- player's skills say (prof = { medic, entertainer, scout, smuggler,
-- hunter }; a plain true means medic), then the enemy lines at the fronts
-- the side is fighting (own planet first, then the hottest), the friendly
-- towns that need a crate, supplying, holding. No fighting orders once a
-- season is won (the field is cleared for the intermission).
function WarOrders.candidates(st, faction, homeRegion, prof)
	local out = {}
	if st == nil or type(st.regions) ~= "table" or faction == nil then
		return out
	end
	if prof == true then
		prof = { medic = true }
	elseif type(prof) ~= "table" then
		prof = {}
	end
	local home = planetOf(homeRegion)
	local homeKnown = homeRegion ~= nil and st.regions[homeRegion] ~= nil
	local frozen = type(st.season) == "table" and st.season.winner ~= nil and st.season.winner ~= ""
	local function bySamePlanetThen(list, cmp)
		table.sort(list, function(a, b)
			if a.same ~= b.same then return a.same end
			return cmp(a, b)
		end)
	end

	-- the fronts the side is fighting
	local lines = {}
	if not frozen then
		for _, fr in ipairs(st.fronts or {}) do
			local r = st.regions[fr.region]
			if r ~= nil and (fr.attacker == faction or r.faction == faction) then
				lines[#lines + 1] = {
					type = "line", region = fr.region, need = WarOrders.KILLS_NEEDED,
					intensity = tonumber(fr.intensity) or 0, same = (planetOf(fr.region) == home),
					defending = (r.faction == faction),
				}
			end
		end
	end
	bySamePlanetThen(lines, function(a, b)
		if a.intensity ~= b.intensity then return a.intensity > b.intensity end
		return a.region < b.region
	end)

	local ids = {}
	for id, _ in pairs(st.regions) do
		ids[#ids + 1] = id
	end
	table.sort(ids)

	if prof.medic then
		for _, c in ipairs(lines) do
			out[#out + 1] = { type = "mend", region = c.region, need = WarOrders.MEND_POINTS }
		end
	end
	if prof.entertainer and not frozen then
		for _, c in ipairs(lines) do
			if c.defending then
				out[#out + 1] = { type = "rally", region = c.region, need = WarOrders.HOLD_MINUTES }
			end
		end
		if homeKnown and st.regions[homeRegion].faction == faction then
			out[#out + 1] = { type = "rally", region = homeRegion, need = WarOrders.HOLD_MINUTES }
		end
	end
	if prof.scout and not frozen then
		local targets = {}
		for _, id in ipairs(ids) do
			local r = st.regions[id]
			if r.faction ~= nil and r.faction ~= faction and not r.is_capital and planetOf(id) ~= nil then
				targets[#targets + 1] = { type = "scout", region = id, need = WarOrders.SCOUT_MINUTES,
					same = (planetOf(id) == home), quiet = not hasFront(st, id) }
			end
		end
		bySamePlanetThen(targets, function(a, b)
			if a.quiet ~= b.quiet then return a.quiet end
			return a.region < b.region
		end)
		for _, c in ipairs(targets) do
			out[#out + 1] = c
		end
	end
	if prof.smuggler then
		local cut = {}
		for _, id in ipairs(ids) do
			local r = st.regions[id]
			if r.faction == faction and not r.is_capital and r.road == "cut" and planetOf(id) ~= nil then
				cut[#cut + 1] = { type = "blockade", region = id, need = 1, same = (planetOf(id) == home),
					falls = tonumber(r.falls_in_ticks) or 1e9 }
			end
		end
		bySamePlanetThen(cut, function(a, b)
			if a.falls ~= b.falls then return a.falls < b.falls end
			return a.region < b.region
		end)
		for _, c in ipairs(cut) do
			out[#out + 1] = c
		end
	end
	if prof.hunter and homeKnown then
		out[#out + 1] = { type = "hunt", region = homeRegion, need = WarOrders.HUNT_KILLS }
	end
	-- B61 S2: a pilot clears the sky over the planet the officer stands on
	if prof.pilot and homeKnown then
		local orbit = WarOrders.ORBIT_OF[string.sub(tostring(homeRegion), 1, 3)]
		if orbit ~= nil and type(st.orbits) == "table" and st.orbits[orbit] ~= nil then
			-- B61 S4: the enemy's picket to break; a convoy to see in (unless the
			-- other side's is up: one convoy per orbit at a time)
			if st.orbits[orbit].faction == other(faction) then
				out[#out + 1] = { type = "picket", region = orbit, need = 1 }
			end
			local conv = (WarSpace ~= nil and WarSpace.convoyRecord ~= nil) and WarSpace.convoyRecord(orbit) or nil
			if conv == nil or conv.side == faction then
				out[#out + 1] = { type = "escort", region = orbit, need = WarOrders.ESCORT_MINUTES }
			end
			out[#out + 1] = { type = "sky", region = orbit, need = WarOrders.SKY_KILLS }
		end
	end

	for _, c in ipairs(lines) do
		out[#out + 1] = { type = "line", region = c.region, need = c.need }
	end
	local carries = {}
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
	bySamePlanetThen(carries, function(a, b)
		if a.falls ~= b.falls then return a.falls < b.falls end
		return a.region < b.region
	end)
	for _, c in ipairs(carries) do
		out[#out + 1] = c
	end
	if homeKnown then
		out[#out + 1] = { type = "supply", region = homeRegion, need = WarOrders.SUPPLY_POINTS, extra = WarOrders.supplyCategory(st) }
		out[#out + 1] = { type = "hold", region = homeRegion, need = WarOrders.HOLD_MINUTES }
	end
	return out
end

--- The next order: the first candidate that is not `last` ("type:region").
function WarOrders.pick(st, faction, homeRegion, last, prof)
	local cands = WarOrders.candidates(st, faction, homeRegion, prof)
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
	return { type = chosen.type, region = chosen.region, need = chosen.need, faction = faction, done = 0, extra = chosen.extra }
end

--- The order as the officer says it.
function WarOrders.text(o, st)
	local enemy = other(o.faction)
	if o.type == "sky" then
		return "Clear the sky over " .. WarOrders.planetOfOrbit(o.region) .. ": bring down " .. tostring(o.need)
			.. " " .. adj(enemy) .. " war ships in orbit. Launch from your datapad."
	elseif o.type == "escort" then
		local km = (WarSpace ~= nil and WarSpace.ESCORT_RANGE_M or 1500) / 1000
		return "Escort the " .. side(o.faction) .. "'s convoy over " .. WarOrders.planetOfOrbit(o.region)
			.. " to the dock: it launches at the entry point when you take this. Stay within " .. string.format("%.1f", km)
			.. " km of the freighter for " .. tostring(o.need) .. " minutes of its run and see it in. Launch from your datapad."
	elseif o.type == "picket" then
		local n = (WarSpace ~= nil and WarSpace.PICKET_SIZE) or 4
		return "Break the " .. side(enemy) .. "'s picket over " .. WarOrders.planetOfOrbit(o.region) .. ": bring down all "
			.. tostring(n) .. " of its ships, at least one of them yours. Launch from your datapad."
	end
	if o.type == "line" then
		return "Break the " .. side(enemy) .. "'s line at " .. name(o.region) .. ": kill " .. tostring(o.need)
			.. " " .. adj(enemy) .. " war troopers there."
	elseif o.type == "carry" or o.type == "blockade" then
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
		if o.type == "blockade" then
			return "Run the blockade into " .. name(o.region) .. ": requisition a supply crate from a quartermaster and get it through." .. why
		end
		return "Carry crates to " .. name(o.region) .. ": requisition a supply crate from a quartermaster and deliver it there." .. why
	elseif o.type == "mend" then
		local health = ""
		if WarHeal ~= nil and tonumber(WarHeal.MATERIEL_PER_HEALED_POINT) ~= nil and WarHeal.MATERIEL_PER_HEALED_POINT > 0 then
			health = " (about " .. tostring(math.floor((tonumber(o.need) or 0) / WarHeal.MATERIEL_PER_HEALED_POINT + 0.5)) .. " points of health)"
		end
		return "Keep the line standing at " .. name(o.region) .. ": heal " .. pointsText(o.need) .. " of " .. adj(o.faction)
			.. " troopers there" .. health .. "."
	elseif o.type == "rally" then
		return "Rally the garrison at " .. name(o.region) .. ": play or dance there for " .. tostring(o.need) .. " minutes."
	elseif o.type == "scout" then
		return "Scout " .. name(o.region) .. ": get inside it and stay " .. tostring(o.need)
			.. " minutes. Your report will pull the next front there."
	elseif o.type == "hunt" then
		return "Hunt: bring down " .. tostring(o.need) .. " enemy players, anywhere."
	elseif o.type == "supply" then
		if o.extra ~= nil and o.extra ~= "" then
			return "Supply the war: the line needs " .. tostring(o.extra) .. " -- donate " .. pointsText(o.need)
				.. " of it at a recruiter of your side."
		end
		return "Supply the war: donate " .. pointsText(o.need) .. " of crafted goods or resources at a recruiter of your side."
	end
	return "Hold " .. name(o.region) .. ": stand your ground there for " .. tostring(o.need) .. " minutes; the enemy will test the garrison."
end

function WarOrders.rewardText(o)
	local pts = WarOrders.POINTS[o.type] or 0
	local hours = math.floor(WarOrders.EXPIRY_MS / 3600000)
	local extra = ""
	if o.type == "rally" then
		extra = " " .. pointsText(WarOrders.RALLY_SUPPORT) .. " of morale to the town."
	elseif o.type == "scout" then
		extra = " The next front opens where you went."
	elseif o.type == "escort" then
		extra = " The convoy's crates land for your side: in the orbit's store if the sky is yours, else at your side's port below."
	elseif o.type == "picket" then
		extra = " Their line over the planet is a lost fight; a dry sky changes hands on it."
	end
	return "Reward: " .. pointsText(pts) .. " on completion." .. extra .. " Expires in " .. tostring(hours) .. " h."
end

--- What a completed order reads as.
--- B61 S2: "Tatooine" for tat_orbit (WarSpace names the planet; fall back to the id).
function WarOrders.planetOfOrbit(orbitId)
	if WarSpace ~= nil and WarSpace.planetName ~= nil then
		return WarSpace.planetName(orbitId)
	end
	return name(orbitId)
end

function WarOrders.doneText(o)
	if o.type == "sky" then
		return tostring(o.need) .. " " .. adj(other(o.faction)) .. " hulls down over " .. WarOrders.planetOfOrbit(o.region) .. "."
	elseif o.type == "escort" then
		return "The convoy over " .. WarOrders.planetOfOrbit(o.region) .. " is in: "
			.. pointsText((WarSpace ~= nil and WarSpace.CONVOY_CRATES) or 5.0) .. " landed for your side."
	elseif o.type == "picket" then
		return "The " .. adj(other(o.faction)) .. " picket over " .. WarOrders.planetOfOrbit(o.region) .. " is broken."
	end
	if o.type == "line" then
		return tostring(o.need) .. " " .. adj(other(o.faction)) .. " troopers down at " .. name(o.region) .. "."
	elseif o.type == "carry" then
		return "Crates delivered to " .. name(o.region) .. "."
	elseif o.type == "blockade" then
		return "The blockade at " .. name(o.region) .. " was run: crates delivered."
	elseif o.type == "mend" then
		return "The line at " .. name(o.region) .. " stood: " .. pointsText(o.need) .. " of healing."
	elseif o.type == "rally" then
		return name(o.region) .. "'s garrison rallied: " .. pointsText(WarOrders.RALLY_SUPPORT) .. " of morale."
	elseif o.type == "scout" then
		return name(o.region) .. " scouted: the next front is yours."
	elseif o.type == "hunt" then
		return tostring(o.need) .. " enemy players hunted down."
	elseif o.type == "supply" then
		if o.extra ~= nil and o.extra ~= "" then
			return pointsText(o.need) .. " of " .. tostring(o.extra) .. " donated."
		end
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
	if o.type == "line" or o.type == "hunt" then
		progress = tostring(math.floor(done)) .. " of " .. tostring(o.need) .. " kills"
	elseif o.type == "hold" or o.type == "rally" or o.type == "scout" then
		progress = tostring(math.floor(done)) .. " of " .. tostring(o.need) .. " minutes"
	elseif o.type == "escort" then
		progress = tostring(math.floor(done)) .. " of " .. tostring(o.need) .. " minutes with the convoy"
	elseif o.type == "picket" then
		progress = tostring(math.floor(done)) .. " of the picket yours"
	elseif o.type == "mend" then
		progress = string.format("%.1f of %.1f crates' worth healed", done, tonumber(o.need) or 0)
	elseif o.type == "supply" then
		progress = string.format("%.1f of %.1f crates' worth%s donated", done, tonumber(o.need) or 0,
			(o.extra ~= nil and o.extra ~= "") and (" of " .. tostring(o.extra)) or "")
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

local function hasAny(creature, skills)
	for _, skill in ipairs(skills) do
		if creature:hasSkill(skill) then
			return true
		end
	end
	return false
end

--- What the player's skills say: { medic, entertainer, scout, smuggler, hunter }.
function WarOrders.professionsOf(pPlayer)
	local prof = {}
	pcall(function()
		local creature = CreatureObject(pPlayer)
		prof.medic = hasAny(creature, WarOrders.MEDIC_SKILLS)
		prof.entertainer = hasAny(creature, WarOrders.ENTERTAINER_SKILLS)
		prof.scout = hasAny(creature, WarOrders.SCOUT_SKILLS)
		prof.smuggler = hasAny(creature, WarOrders.SMUGGLER_SKILLS)
		prof.hunter = hasAny(creature, WarOrders.HUNTER_SKILLS)
		-- B61 S2: a pilot (any of the three pilot trees)
		prof.pilot = (SpaceHelpers ~= nil and SpaceHelpers.isPilot ~= nil) and SpaceHelpers:isPilot(pPlayer) or false
	end)
	return prof
end

--- A novice box in medic, combat medic or doctor.
function WarOrders.isMedic(pPlayer)
	return WarOrders.professionsOf(pPlayer).medic == true
end

function WarOrders.active(oid)
	return WarOrders.decode(readStringData(key(oid)))
end

function WarOrders.save(oid, o)
	writeStringData(key(oid), WarOrders.encode(o))
	WarOrders.indexAdd(oid)
	pcall(WarOrders.persist)
end

--- Forget the order; the datapad waypoint it placed goes with it.
function WarOrders.clear(oid, pPlayer)
	writeStringData(key(oid), "")
	pcall(function() WarOrders.removeWaypoint(pPlayer, oid) end)
	WarOrders.indexRemove(oid)
	pcall(WarOrders.persist)
end

local function wpKey(oid)
	return WarOrders.WP_PREFIX .. tostring(oid)
end

-- B47: the index of active orders, so the disk mirror can be rewritten in
-- full on every change (a handful of players: cheap).
local function indexList()
	local raw = readStringData(WarOrders.INDEX_KEY)
	local out = {}
	if raw ~= nil and raw ~= "" then
		for id in string.gmatch(raw, "[^,]+") do
			out[#out + 1] = id
		end
	end
	return out
end

local function indexWrite(list)
	writeStringData(WarOrders.INDEX_KEY, table.concat(list, ","))
end

-- Table functions, not locals: save() and clear() sit above this point in
-- the file and a local defined below them is nil there (the trap in
-- CLAUDE.md part 4; it bit this very slice on its first probe).
function WarOrders.indexAdd(oid)
	local list = indexList()
	for _, id in ipairs(list) do
		if id == tostring(oid) then
			return
		end
	end
	list[#list + 1] = tostring(oid)
	indexWrite(list)
end

function WarOrders.indexRemove(oid)
	local keep = {}
	for _, id in ipairs(indexList()) do
		if id ~= tostring(oid) then
			keep[#keep + 1] = id
		end
	end
	indexWrite(keep)
end

--- B47: mirror every active order to disk, one tab-separated line each:
-- oid, the record, the waypoint id, the last-order note. Called on every
-- save and clear. A restart loses shared string data; the mirror does not.
function WarOrders.persist()
	local fh = io.open(WarOrders.STATE_FILE, "w")
	if fh == nil then
		return false
	end
	for _, id in ipairs(indexList()) do
		local rec = readStringData(key(id))
		if rec ~= nil and rec ~= "" then
			fh:write(id .. "\t" .. rec .. "\t" .. tostring(readStringData(wpKey(id)) or "") .. "\t"
				.. tostring(readStringData(lastKey(id)) or "") .. "\n")
		end
	end
	fh:close()
	return true
end

--- B47: read the mirror back once per process (RESTORED_KEY is shared
-- memory: empty after a restart, set after the first pass, so a reload's
-- re-include does nothing). Lapsed orders are dropped; a live shared record
-- is never overwritten. Returns the count restored.
function WarOrders.restoreFromDisk()
	if (readData(WarOrders.RESTORED_KEY) or 0) > 0 then
		return 0
	end
	local fh = io.open(WarOrders.STATE_FILE, "r")
	if fh == nil then
		-- No mirror (a fresh install) or a transient open failure: leave the
		-- gate open so the next include tries again (verifier, 2026-09-07).
		return 0
	end
	writeData(WarOrders.RESTORED_KEY, getTimestampMilli())
	local restored, now = 0, getTimestampMilli()
	for line in fh:lines() do
		local id, rec, wp, last = string.match(line, "^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
		if id ~= nil and rec ~= "" then
			local o = WarOrders.decode(rec)
			if o ~= nil and now < (o.expiresAt or 0) and (readStringData(key(id)) or "") == "" then
				writeStringData(key(id), rec)
				if wp ~= "" then
					writeStringData(wpKey(id), wp)
				end
				if last ~= "" then
					writeStringData(lastKey(id), last)
				end
				WarOrders.indexAdd(id)
				restored = restored + 1
			end
		end
	end
	fh:close()
	printf("WarOrders: restored " .. tostring(restored) .. " order(s) from " .. WarOrders.STATE_FILE .. "\n")
	return restored
end

--- B47: at login, a presence order (hold, rally, scout) whose minute chain
-- stopped -- the process restarted, or the player was away -- gets its
-- chain back. The chain stamps CHAIN_PREFIX every tick; older than two
-- ticks means nobody is counting.
function WarOrders.onLogin(pPlayer)
	if pPlayer == nil then
		return false
	end
	local oid = SceneObject(pPlayer):getObjectID()
	local o = WarOrders.active(oid)
	if o == nil or not (o.type == "hold" or o.type == "rally" or o.type == "scout") then
		return false
	end
	local now = getTimestampMilli()
	if now >= (o.expiresAt or 0) then
		return false
	end
	local stamp = readData(WarOrders.CHAIN_PREFIX .. tostring(oid)) or 0
	if stamp > 0 and (now - stamp) < 2 * WarOrders.HOLD_CHECK_MS then
		return false
	end
	writeData(WarOrders.CHAIN_PREFIX .. tostring(oid), now)
	createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
	printf("WarOrders: " .. tostring(oid) .. " " .. o.type .. " chain restarted at login\n")
	return true
end

--- The datapad waypoint's name for an order; nil for a hunt (its target is a
-- player, anywhere). Pure.
function WarOrders.waypointName(o)
	if o == nil then
		return nil
	end
	local n = name(o.region)
	if o.type == "line" then
		return "Orders: the line at " .. n
	elseif o.type == "mend" then
		return "Orders: mend the line at " .. n
	elseif o.type == "carry" then
		return "Orders: courier to " .. n
	elseif o.type == "blockade" then
		return "Orders: run the blockade to " .. n
	elseif o.type == "hold" then
		return "Orders: hold " .. n
	elseif o.type == "rally" then
		return "Orders: rally " .. n
	elseif o.type == "scout" then
		return "Orders: scout " .. n
	elseif o.type == "supply" then
		return "Orders: supply " .. n
	end
	return nil
end

--- Where the waypoint points, from the region's town-centre coords: the fight
-- orders (line, mend) at the recruiter-anchor battle site -- through
-- WarBattle.anchorPoint, the ONE place that arithmetic lives, so the pin and
-- the fight cannot drift apart -- and every other order at the town centre.
-- nil for a hunt or without coords. Pure.
function WarOrders.waypointPoint(o, coords)
	if o == nil or coords == nil or o.type == "hunt" then
		return nil
	end
	local x, y = coords[1], coords[2]
	if (o.type == "line" or o.type == "mend") and WarBattle ~= nil and WarBattle.anchorPoint ~= nil then
		x, y = WarBattle.anchorPoint(coords, o.region)
	end
	return x, y
end

--- Put the order's waypoint on the player's datapad (persistent: it survives
-- a relog) and remember its object id so the order's end can remove it.
function WarOrders.placeWaypoint(pPlayer, oid, o)
	if pPlayer == nil or o == nil then
		return false
	end
	local wpName = WarOrders.waypointName(o)
	local coords = (WarReport ~= nil and WarReport.COORDS ~= nil) and WarReport.COORDS[o.region] or nil
	local zone = (WarReport ~= nil and WarReport.PLANET_OF ~= nil) and WarReport.PLANET_OF[o.region] or nil
	local x, y = WarOrders.waypointPoint(o, coords)
	if wpName == nil or x == nil or zone == nil then
		return false
	end
	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return false
	end
	WarOrders.removeWaypoint(pPlayer, oid)
	local ok, wp = pcall(function()
		return PlayerObject(pGhost):addWaypoint(zone, wpName, "", x, 0, y, WarOrders.WAYPOINT_COLOR, true, true, WarOrders.WAYPOINT_TYPE, 1)
	end)
	if ok and wp ~= nil and wp ~= 0 then
		writeStringData(wpKey(oid), tostring(wp))
		return true
	end
	printf("WarOrders: waypoint for " .. tostring(oid) .. " not placed: " .. tostring(wp) .. "\n")
	return false
end

--- Take the order's waypoint off the datapad, if one was placed. The player
-- pointer when the caller holds one, else the object id resolves it. False
-- when nothing was placed.
function WarOrders.removeWaypoint(pPlayer, oid)
	local raw = readStringData(wpKey(oid))
	if raw == nil or raw == "" then
		return false
	end
	writeStringData(wpKey(oid), "")
	local n = tonumber(raw)
	local wp = (n ~= nil and math.tointeger ~= nil) and math.tointeger(n) or n
	if wp == nil then
		return false
	end
	if pPlayer == nil then
		pPlayer = getSceneObject(oid)
	end
	if pPlayer == nil then
		return false
	end
	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return false
	end
	pcall(function() PlayerObject(pGhost):removeWaypoint(wp, true) end)
	return true
end

--- At login: a pin of our type with no live order behind it (a restart
-- loses the shared string data the order and the pin id live in, and the
-- persistent pin would stay on the datapad for good) is swept by type.
-- A live order keeps its pin. Returns true when something was removed.
function WarOrders.sweepWaypoints(pPlayer)
	if pPlayer == nil then
		return false
	end
	local oid = SceneObject(pPlayer):getObjectID()
	local o = WarOrders.active(oid)
	if o ~= nil and getTimestampMilli() < (o.expiresAt or 0) then
		return false
	end
	local pGhost = CreatureObject(pPlayer):getPlayerObject()
	if pGhost == nil then
		return false
	end
	writeStringData(wpKey(oid), "")
	local ok = pcall(function() PlayerObject(pGhost):removeWaypointBySpecialType(WarOrders.WAYPOINT_TYPE) end)
	return ok
end

local function isPresenceOrder(o)
	return o.type == "hold" or o.type == "rally" or o.type == "scout" or o.type == "escort" or o.type == "picket"
end

local function isSkyOrder(o)
	return o.type == "escort" or o.type == "picket"
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
		WarOrders.clear(oid, pPlayer)
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
	o = WarOrders.pick(st, faction, home, last, WarOrders.professionsOf(pPlayer))
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
	-- B61 S4: the escort's convoy goes up now (or the one up becomes yours);
	-- if the other side's is up the order is not given.
	if o.type == "escort" then
		local status = "unavailable"
		if WarSpace ~= nil and WarSpace.requestConvoy ~= nil then
			local okR, got = pcall(WarSpace.requestConvoy, o.region, faction, oid)
			if okR and got ~= nil then status = got end
		end
		local planet = WarOrders.planetOfOrbit(o.region)
		if status == "launched" then
			creature:sendSystemMessage("The convoy is up over " .. planet .. ": a freighter and two escorts at the entry point, bound for the dock beside the picket.")
		elseif status == "joined" then
			creature:sendSystemMessage("A convoy of ours is already up over " .. planet .. "; find it and see it in.")
		else
			WarOrders.clear(oid, pPlayer)
			creature:sendSystemMessage((status == "busy")
				and ("No orders after all: the lane over " .. planet .. " is busy with an enemy convoy. Come back in a few minutes.")
				or ("No orders after all: no convoy can launch over " .. planet .. " right now."))
			printf("WarOrders: " .. tostring(oid) .. " escort at " .. o.region .. " refused: " .. tostring(status) .. "\n")
			return
		end
	end
	if WarOrders.placeWaypoint(pPlayer, oid, o) then
		creature:sendSystemMessage("The place is marked on your datapad.")
	end
	if isPresenceOrder(o) then
		createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
	end
	printf("WarOrders: " .. tostring(oid) .. " took " .. o.type .. " at " .. o.region .. " (" .. faction .. ")\n")
end

--- The order is done: the record(s), the message, the next order skips it.
function WarOrders.complete(oid, o, pPlayer)
	local pts = WarOrders.POINTS[o.type] or 0
	local recorded, reason = false, "no_record"
	if WarOrders._rawRecord ~= nil then
		recorded, reason = WarOrders._rawRecord(o.faction, o.region, WarOrders.SOURCE, pts, oid)
		if o.type == "rally" then
			-- the morale is real: support crates at the town
			pcall(function() WarOrders._rawRecord(o.faction, o.region, "materiel_support", WarOrders.RALLY_SUPPORT, oid) end)
		elseif o.type == "scout" and WarOrders.SCOUT_POINTS > pts then
			-- the report must reach the sim's forced-front threshold
			pcall(function() WarOrders._rawRecord(o.faction, o.region, WarOrders.SOURCE, WarOrders.SCOUT_POINTS - pts, oid) end)
		end
	end
	writeStringData(lastKey(oid), o.type .. ":" .. o.region)
	WarOrders.clear(oid, pPlayer)
	if pPlayer ~= nil then
		local creature = CreatureObject(pPlayer)
		creature:sendSystemMessage("Orders complete: " .. WarOrders.doneText(o) .. " " .. pointsText(pts) .. " to your name"
			.. (recorded and "." or (" (not recorded: " .. tostring(reason) .. ").")))
		creature:sendSystemMessage("See an officer for new orders.")
	end
	printf("WarOrders: " .. tostring(oid) .. " completed " .. o.type .. " at " .. o.region
		.. " recorded=" .. tostring(recorded) .. "\n")
end

--- The categories of the last donation this character made, from the key
-- war_donate.lua writes: "armour=6.00;goods=1.00" -> { armour = 6, goods = 1 }.
local function lastDonation(oid)
	local out = {}
	local raw = readStringData(donationKey(oid))
	if raw == nil or raw == "" then
		return out
	end
	for cat, pts in string.gmatch(raw, "(%a+)=([%d%.]+)") do
		out[cat] = (out[cat] or 0) + (tonumber(pts) or 0)
	end
	return out
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
	-- or hunt order (any town), the order's town.
	if o.faction ~= string.lower(tostring(faction)) then
		return
	end
	if o.type ~= "supply" and o.type ~= "hunt" and o.region ~= regionId then
		return
	end
	local pPlayer = getSceneObject(oid)
	if o.type == "picket" then
		-- B61 S4: one of the picket yours; the wipe itself is seen by skyCheck
		if source == "npc_kill_faction" then
			o.done = (o.done or 0) + 1
			WarOrders.save(oid, o)
			if pPlayer ~= nil then
				CreatureObject(pPlayer):sendSystemMessage("Orders: " .. tostring(math.floor(o.done)) .. " of the picket yours; break the rest.")
			end
		end
		return
	end
	if (o.type == "line" and (source == "npc_kill_faction" or source == "pvp_kill"))
		or (o.type == "hunt" and source == "pvp_kill")
		or (o.type == "sky" and source == "npc_kill_faction") then
		o.done = (o.done or 0) + 1
		if o.done >= o.need then
			WarOrders.complete(oid, o, pPlayer)
		else
			WarOrders.save(oid, o)
			if pPlayer ~= nil then
				CreatureObject(pPlayer):sendSystemMessage("Orders: " .. tostring(math.floor(o.done)) .. " of " .. tostring(o.need) .. ".")
			end
		end
	elseif (o.type == "carry" or o.type == "blockade") and source == "materiel_delivery" then
		o.done = 1
		WarOrders.complete(oid, o, pPlayer)
	elseif (o.type == "mend" and source == "materiel_support") or (o.type == "supply" and source == "materiel_donation") then
		local prev = tonumber(o.done) or 0
		local gained = tonumber(points) or 0
		if o.type == "supply" and o.extra ~= nil and o.extra ~= "" then
			gained = lastDonation(oid)[o.extra] or 0
		end
		if gained <= 0 then
			return
		end
		o.done = prev + gained
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

--- The per-minute check behind a hold, rally or scout order.
--- B44 garrison duty: the raid a hold order draws, RAID_AT_MINUTE minutes
-- into the hold (holdCheck), once per order (o.extra = "raided"): RAID_SIZE
-- enemy troopers on a meshed point RAID_DISTANCE_M from the player, set on
-- the player, tracked in the town's garrison slot (war_battle.lua). Skipped,
-- with a line, when the NPC budget is spent. Returns the bodies spawned.
function WarOrders.raid(pPlayer, o)
	if pPlayer == nil or o == nil or WarBattle == nil or WarBattle.spawnRaid == nil then
		return 0, "module"
	end
	-- No front on the ground (the intermission: WarBattle.fronts() is empty
	-- while the map is frozen) means no raid either; tried again a minute
	-- later, silently, like a module not visible on this thread.
	if WarBattle.fronts ~= nil and #WarBattle.fronts() == 0 then
		return 0, "quiet"
	end
	local creature = CreatureObject(pPlayer)
	local enemy = other(o.faction)
	local zone = SceneObject(pPlayer):getZoneName()
	local px, py = SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY()
	if WarBattle.aliveCombatants ~= nil and WarBattle.TOTAL_NPC_BUDGET ~= nil
		and WarBattle.aliveCombatants() + WarOrders.RAID_SIZE > WarBattle.TOTAL_NPC_BUDGET then
		if o.extra ~= "raid_wait" then
			creature:sendSystemMessage("The garrison reports movement outside, but nothing comes yet: the front has every enemy body busy.")
		end
		printf("WarOrders: raid on " .. tostring(o.region) .. " skipped: budget spent\n")
		return 0, "budget"
	end
	local function walkable(x, y)
		if type(isPointWalkable) ~= "function" or type(getWorldFloor) ~= "function" then
			return true
		end
		local okz, z = pcall(getWorldFloor, x, y, zone)
		if not okz or type(z) ~= "number" then
			return false
		end
		local ok, w = pcall(isPointWalkable, zone, x, z, y)
		return ok and w == true
	end
	local x, y = nil, nil
	local first = math.random() * 2 * math.pi
	for _, r in ipairs({ WarOrders.RAID_DISTANCE_M, WarOrders.RAID_DISTANCE_M * 0.6 }) do
		for k = 0, 3 do
			local ang = first + k * (math.pi / 2)
			local cx, cy = px + r * math.cos(ang), py + r * math.sin(ang)
			if x == nil and walkable(cx, cy) then
				x, y = cx, cy
			end
		end
	end
	if x == nil then
		x, y = px + 10, py
	end
	local n = WarBattle.spawnRaid(zone, o.region, enemy, x, y, WarOrders.RAID_SIZE, pPlayer)
	if n > 0 then
		creature:sendSystemMessage("Raiders! " .. tostring(n) .. " " .. adj(enemy) .. " troopers are coming for the garrison -- hold "
			.. name(o.region) .. ".")
	end
	printf("WarOrders: raid on " .. tostring(o.region) .. " for " .. tostring(SceneObject(pPlayer):getObjectID())
		.. ": " .. tostring(n) .. " " .. tostring(enemy) .. " bodies\n")
	return n
end

function WarOrders:holdCheck(pPlayer)
	if pPlayer == nil then
		return
	end
	pcall(function()
		local oid = SceneObject(pPlayer):getObjectID()
		local o = WarOrders.active(oid)
		if o == nil or not isPresenceOrder(o) then
			return
		end
		local now = getTimestampMilli()
		writeData(WarOrders.CHAIN_PREFIX .. tostring(oid), now)  -- B47: this chain is alive
		if isSkyOrder(o) then
			WarOrders.skyCheck(oid, o, pPlayer, now)
			return
		end
		if now >= (o.expiresAt or 0) then
			WarOrders.clear(oid, pPlayer)
			CreatureObject(pPlayer):sendSystemMessage("Your orders have lapsed: " .. name(o.region) .. " was not "
				.. ((o.type == "scout") and "scouted." or ((o.type == "rally") and "rallied." or "held.")))
			return
		end
		local here = nil
		if WarReport ~= nil and WarReport.regionAt ~= nil then
			here = WarReport.regionAt(SceneObject(pPlayer):getZoneName(),
				SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY())
		end
		local counts = (here == o.region)
		if counts and o.type == "rally" then
			local creature = CreatureObject(pPlayer)
			counts = creature:isDancing() or creature:isPlayingMusic()
		end
		if counts then
			o.done = (o.done or 0) + 1
			-- B44 garrison duty: the raid, once, RAID_AT_MINUTE minutes in.
			-- The flag is burnt only by a raid that came; a refusal (the
			-- budget, the module not visible on this thread) is retried a
			-- minute later, and the "nothing comes" line is said once
			-- (verifier, 2026-09-07).
			if o.type == "hold" and o.done >= WarOrders.RAID_AT_MINUTE and o.extra ~= "raided" then
				local okR, n, why = pcall(WarOrders.raid, pPlayer, o)
				if okR and (tonumber(n) or 0) > 0 then
					o.extra = "raided"
				elseif okR and why == "budget" and o.extra ~= "raid_wait" then
					-- Only a budget refusal (which spoke) sets the flag that
					-- silences the next one; a module not visible on this
					-- thread says nothing and keeps trying (re-verifier).
					o.extra = "raid_wait"
				end
			end
			if o.done >= o.need then
				WarOrders.complete(oid, o, pPlayer)
				return
			end
			WarOrders.save(oid, o)
			if o.done % 5 == 0 or o.type == "scout" then
				CreatureObject(pPlayer):sendSystemMessage("Orders: " .. tostring(math.floor(o.done)) .. " of " .. tostring(o.need)
					.. " minutes at " .. name(o.region) .. ".")
			end
		end
		createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
	end)
end

--- B61 S4: the per-minute check behind an escort or picket order. An
-- escort samples the distance to the freighter (WarSpace.distanceToFreighter)
-- and completes only from onConvoyDocked; a picket order completes when the
-- enemy picket reads wiped (WarSpace.picketState) with a hull of the pilot's
-- own on it (observe), or when the sky has changed hands with one.
function WarOrders.skyCheck(oid, o, pPlayer, now)
	local creature = CreatureObject(pPlayer)
	local planet = WarOrders.planetOfOrbit(o.region)
	if now >= (o.expiresAt or 0) then
		WarOrders.clear(oid, pPlayer)
		creature:sendSystemMessage("Your orders have lapsed: " .. ((o.type == "escort") and ("the convoy over " .. planet .. " was not seen in.")
			or ("the picket over " .. planet .. " still stands.")))
		return
	end
	if WarSpace == nil then
		createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
		return
	end
	if o.type == "escort" then
		local rec = WarSpace.convoyRecord(o.region)
		if rec == nil or rec.side ~= o.faction then
			-- retired without docking under you (timed out, or lost before the sweep spoke)
			WarOrders.clear(oid, pPlayer)
			creature:sendSystemMessage("The convoy over " .. planet .. " is no longer up. See an officer for new orders.")
			return
		end
		local d = WarSpace.distanceToFreighter(pPlayer, o.region)
		if d ~= nil and d <= (WarSpace.ESCORT_RANGE_M or 1500) then
			o.done = (o.done or 0) + 1
			WarOrders.save(oid, o)
			if o.done == 1 then
				creature:sendSystemMessage("You are with the convoy. Stay with it to the dock.")
			elseif o.done == o.need then
				creature:sendSystemMessage("Orders: with the convoy " .. tostring(math.floor(o.done)) .. " of " .. tostring(o.need) .. " minutes. See it in.")
			end
		end
	elseif o.type == "picket" then
		local enemy = other(o.faction)
		local pside, alive = WarSpace.picketState(o.region)
		local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
		local holder = (st ~= nil and type(st.orbits) == "table" and st.orbits[o.region] ~= nil) and st.orbits[o.region].faction or nil
		local wiped = (pside == enemy and alive == 0) or (holder == o.faction)
		if wiped then
			if (o.done or 0) >= 1 then
				WarOrders.complete(oid, o, pPlayer)
			else
				WarOrders.clear(oid, pPlayer)
				creature:sendSystemMessage("The " .. adj(enemy) .. " picket over " .. planet .. " is gone, and none of it was yours. See an officer for new orders.")
			end
			return
		end
	end
	createEvent(WarOrders.HOLD_CHECK_MS, "WarOrders", "holdCheck", pPlayer, "")
end

--- B61 S4: an owned convoy docked (war_space.lua onConvoyArrived). The
-- owner's escort order completes if the escort counted, else clears.
function WarOrders.onConvoyDocked(orbitId, sideStr, ownerOid)
	local oid = math.tointeger(tonumber(ownerOid))
	if oid == nil or oid <= 0 then return end
	local o = WarOrders.active(oid)
	if o == nil or o.type ~= "escort" or o.region ~= orbitId then return end
	local pPlayer = getSceneObject(oid)
	if (o.done or 0) >= (o.need or 1) then
		WarOrders.complete(oid, o, pPlayer)
		return
	end
	WarOrders.clear(oid, pPlayer)
	if pPlayer ~= nil then
		CreatureObject(pPlayer):sendSystemMessage("The convoy over " .. WarOrders.planetOfOrbit(orbitId) .. " is in, but you were with it "
			.. tostring(math.floor(o.done or 0)) .. " of " .. tostring(o.need) .. " minutes: no credit. See an officer for new orders.")
	end
	printf("WarOrders: " .. tostring(oid) .. " escort at " .. orbitId .. " docked without the escort\n")
end

--- B61 S4: an owned convoy lost (war_space.lua sweepConvoy).
function WarOrders.onConvoyLost(orbitId, sideStr, ownerOid)
	local oid = math.tointeger(tonumber(ownerOid))
	if oid == nil or oid <= 0 then return end
	local o = WarOrders.active(oid)
	if o == nil or o.type ~= "escort" or o.region ~= orbitId then return end
	local pPlayer = getSceneObject(oid)
	WarOrders.clear(oid, pPlayer)
	if pPlayer ~= nil then
		CreatureObject(pPlayer):sendSystemMessage("The convoy over " .. WarOrders.planetOfOrbit(orbitId) .. " was lost. See an officer for new orders.")
	end
	printf("WarOrders: " .. tostring(oid) .. " escort at " .. orbitId .. " lost\n")
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
		WarOrders.clear(oid, pPlayer)
		-- B49 polish: say so once, instead of the order vanishing silently.
		return WarOrders.lapsedLine(o)
	end
	return WarOrders.statusLine(o, st, now)
end

--- The line for an order that lapsed unseen (two hours passed while the
-- player was away). Pure.
function WarOrders.lapsedLine(o)
	if o == nil then
		return nil
	end
	local what = (o.type == "hunt") and "hunt" or (tostring(o.type) .. " orders at " .. name(o.region))
	return "Your " .. what .. " lapsed while you were away. See an officer for new orders."
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
-- B47: the disk mirror, once per process (shared-memory gated; no spawn, no
-- event -- allowed at include time).
pcall(WarOrders.restoreFromDisk)

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
			local home = posts[1] and posts[1].region or nil
			for _, faction in ipairs({ "imperial", "rebel" }) do
				for i = 1, math.min(#posts, 3) do
					local o = WarOrders.pick(st, faction, posts[i].region, nil, nil)
					printf("WARORDERS: pick " .. faction .. "@" .. tostring(posts[i].region) .. " | "
						.. (o and (o.type .. " " .. o.region .. " | " .. WarOrders.text(o, st)) or "none") .. "\n")
				end
				printf("WARORDERS: candidates " .. faction .. " = " .. tostring(#WarOrders.candidates(st, faction, home, nil)) .. "\n")
				for _, prof in ipairs({ "medic", "entertainer", "scout", "smuggler", "hunter" }) do
					local o = WarOrders.pick(st, faction, home, nil, { [prof] = true })
					printf("WARORDERS: " .. prof .. " pick " .. faction .. " | "
						.. (o and (o.type .. " " .. o.region .. " | " .. WarOrders.text(o, st)) or "none") .. "\n")
				end
			end
			printf("WARORDERS: supply category now | " .. tostring(WarOrders.supplyCategory(st)) .. "\n")
			-- synthetic orders driven through observe with the record stubbed
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
			local m = { type = "mend", region = "tat_anchorhead", faction = "rebel", need = 3, done = 0, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.save(oid, m)
			WarOrders.observe("rebel", "tat_anchorhead", "materiel_support", 1.5, oid)
			printf("WARORDERS: mend after 1.5 done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("rebel", "tat_anchorhead", "materiel_support", 1.6, oid)
			printf("WARORDERS: mend completes: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[2]) .. "\n")
			local sup = { type = "supply", region = "tat_anchorhead", faction = "rebel", need = 2, done = 0, issuedAt = now, expiresAt = now + 60000, extra = "armour" }
			WarOrders.save(oid, sup)
			writeStringData(donationKey(oid), "weapons=5.00;goods=1.00")
			WarOrders.observe("rebel", "nab_theed", "materiel_donation", 6.0, oid)
			printf("WARORDERS: supply ignores the wrong category: done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			writeStringData(donationKey(oid), "armour=2.50")
			WarOrders.observe("rebel", "nab_theed", "materiel_donation", 2.5, oid)
			printf("WARORDERS: supply completes on its category from any town: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[3]) .. "\n")
			local hunt = { type = "hunt", region = "tat_anchorhead", faction = "rebel", need = 1, done = 0, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.save(oid, hunt)
			WarOrders.observe("rebel", "cor_coronet", "npc_kill_faction", 0.15, oid)
			printf("WARORDERS: hunt ignores an NPC kill: done=" .. tostring(WarOrders.active(oid).done) .. "\n")
			WarOrders.observe("rebel", "cor_coronet", "pvp_kill", 2.0, oid)
			printf("WARORDERS: hunt completes on a player kill anywhere: active=" .. tostring(WarOrders.active(oid)) .. " recorded=" .. tostring(stubbed[4]) .. "\n")
			local rally = { type = "rally", region = "tat_anchorhead", faction = "rebel", need = 1, done = 1, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.complete(oid, rally, nil)
			printf("WARORDERS: rally completion records morale: " .. tostring(stubbed[6]) .. "\n")
			local scout = { type = "scout", region = "nab_theed", faction = "rebel", need = 1, done = 1, issuedAt = now, expiresAt = now + 60000 }
			WarOrders.complete(oid, scout, nil)
			printf("WARORDERS: scout completion records the report: " .. tostring(stubbed[7]) .. " (points " .. tostring(WarOrders.POINTS.scout) .. ", threshold " .. tostring(WarOrders.SCOUT_POINTS) .. ")\n")
			WarOrders._rawRecord = saved
			writeStringData(lastKey(oid), "")
			writeStringData(donationKey(oid), "")
			printf("WARORDERS: wrapper installed=" .. tostring(WarContrib ~= nil and WarContrib.record == WarOrders._installedWrapperRef) .. "\n")
		end)
		if not ok then
			printf("WARORDERS: failed: " .. tostring(err) .. "\n")
		end
		-- B47: the disk mirror round-trips a synthetic order and forgets it on clear
		pcall(function()
			local pid = 4243
			local nowMs = getTimestampMilli()
			local rec = { type = "hold", region = "nab_theed", faction = "imperial", need = 10, done = 1, issuedAt = nowMs, expiresAt = nowMs + 60000, extra = "raided" }
			WarOrders.save(pid, rec)
			local fh = io.open(WarOrders.STATE_FILE, "r")
			local found = false
			if fh ~= nil then
				for line in fh:lines() do
					if string.match(line, "^4243\t") ~= nil and string.find(line, "raided", 1, true) ~= nil then found = true end
				end
				fh:close()
			end
			printf("WARORDERS: " .. (found and "PASS" or "FAIL") .. " the disk mirror carries a saved order (" .. WarOrders.STATE_FILE .. ")\n")
			WarOrders.clear(pid, nil)
			local gone = true
			fh = io.open(WarOrders.STATE_FILE, "r")
			if fh ~= nil then
				for line in fh:lines() do
					if string.match(line, "^4243\t") ~= nil then gone = false end
				end
				fh:close()
			end
			printf("WARORDERS: " .. (gone and "PASS" or "FAIL") .. " a cleared order leaves the mirror\n")
			printf("WARORDERS: " .. ((WarOrders.restoreFromDisk() == 0) and "PASS" or "FAIL") .. " a second restore in the same process is a no-op\n")
		end)
		-- garrison duty (B44): the raid mechanism is reachable and sized
		printf("WARORDERS: " .. ((WarBattle ~= nil and WarBattle.spawnRaid ~= nil) and "PASS" or "FAIL") .. " WarBattle.spawnRaid is visible\n")
		printf("WARORDERS: " .. ((WarOrders.RAID_SIZE >= 2 and WarOrders.RAID_AT_MINUTE < WarOrders.HOLD_MINUTES) and "PASS" or "FAIL")
			.. " raid of " .. tostring(WarOrders.RAID_SIZE) .. " at minute " .. tostring(WarOrders.RAID_AT_MINUTE) .. " of " .. tostring(WarOrders.HOLD_MINUTES) .. "\n")
		printf("WARORDERS: " .. ((WarVoice ~= nil and WarVoice.battle ~= nil and WarVoice.battle("raid", "rebel", nil) ~= nil) and "PASS" or "FAIL") .. " the raid has a voice line\n")
		-- waypoints (B41): every region an order can name has a planet and coords
		pcall(function()
			local st = (WarReport ~= nil and WarReport.state ~= nil) and WarReport.state() or nil
			local missing, total = 0, 0
			if st ~= nil and type(st.regions) == "table" then
				for id, _ in pairs(st.regions) do
					total = total + 1
					if WarReport.COORDS[id] == nil or WarReport.PLANET_OF[id] == nil then
						missing = missing + 1
						printf("WARORDERS: FAIL region without a waypoint target: " .. tostring(id) .. "\n")
					end
				end
			end
			printf("WARORDERS: " .. ((missing == 0 and total > 0) and "PASS" or "FAIL") .. " waypoint targets for "
				.. tostring(total) .. " regions (" .. tostring(missing) .. " missing)\n")
			local sample = { type = "line", region = "nab_moenia", faction = "rebel" }
			local wx, wy = WarOrders.waypointPoint(sample, WarReport.COORDS[sample.region])
			printf("WARORDERS: waypoint " .. tostring(WarOrders.waypointName(sample)) .. " -> "
				.. tostring(WarReport.PLANET_OF[sample.region]) .. " " .. tostring(wx) .. ", " .. tostring(wy) .. "\n")
			local hold = { type = "hold", region = "nab_moenia", faction = "rebel" }
			local hx, hy = WarOrders.waypointPoint(hold, WarReport.COORDS[hold.region])
			printf("WARORDERS: " .. ((hx ~= wx or hy ~= wy) and "PASS" or "FAIL") .. " the line's pin is not the town centre ("
				.. tostring(hx) .. ", " .. tostring(hy) .. ")\n")
			printf("WARORDERS: " .. ((WarOrders.waypointName({ type = "hunt", region = "nab_moenia" }) == nil) and "PASS" or "FAIL")
				.. " hunt has no waypoint\n")
			printf("WARORDERS: " .. ((WarOrders.removeWaypoint(nil, 4242) == false) and "PASS" or "FAIL")
				.. " removing a waypoint nobody placed is a no-op\n")
		end)
		printf("WARORDERS: end\n")
	end
end
