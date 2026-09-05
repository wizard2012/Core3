--[[
  custom_scripts/screenplays/warreport/war_effects.lua

  GRAND BATTLES slice E (docs/DESIGN-BATTLES.md, owner ruling 2026-09-05:
  "barrages at offensives, flares at night -- visual only"). Nothing here
  deals damage or moves a body; it is client effects broadcast from a war
  object so that players near the fight see and feel it.

  BARRAGE. Every BARRAGE_EVERY_PASSES tend passes (the tend pass runs every
  TEND_INTERVAL_MS, 75 s), a two-sided site whose front is an offensive -- or,
  with BARRAGE_ALSO_HOT, whose intensity is at or above BARRAGE_INTENSITY --
  takes BARRAGE_SHELLS shells: an explosion and a camera shake at a random
  point within BARRAGE_SPREAD_M of a random body of the ATTACKING line,
  staggered BARRAGE_STAGGER_MS apart. The broadcaster is that body, so the
  effect reaches everyone in its client range and nobody else.

  FLARES. Every FLARE_EVERY_PASSES passes, a capital whose exported siege is
  active gets FLARE_COUNT airbursts FLARE_HEIGHT_M above random points within
  FLARE_SPREAD_M of the town centre, broadcast from the capital's officer
  (war_officer.lua's warofficer:npc:<region>) or, failing that, any garrison
  body at the region. "At night" is a client-side sky: the server sends
  Galactic_Time (seconds since the zone booted) and the client draws day and
  night from it on a cycle this codebase does not state. NIGHT_ONLY is
  therefore OFF until a human calibrates it: `test warEffectsPhase` prints
  the server's phase under the assumed NIGHT_CYCLE_S / NIGHT_OFFSET_S; set
  the offset so it agrees with the sky, then switch NIGHT_ONLY on
  (docs/IN-GAME-TESTS.md section 8).

  EFFECT NAMES are the ones this codebase already plays (grep clienteffect/
  in scripts and src): combat_explosion_lair_large, int_camshake_medium,
  lair_med_damage_smoke. A name the client lacks is silently nothing, so a
  new name needs a client check before it is trusted.

  Called from WarBattle.tendOnce (WarEffects.tickOnce(slots, fronts)); no
  event chain of its own. Reload bucket. Probe: test warEffectsNow (fires
  everything once, intervals ignored) and test warEffectsPhase.
]]

WarEffects = WarEffects or { screenplayName = "WarEffects" }

WarEffects.ENABLED = true

WarEffects.BARRAGE_EVERY_PASSES = 2      -- every ~150 s
WarEffects.BARRAGE_ALSO_HOT = true       -- a front at BARRAGE_INTENSITY counts as an offensive
WarEffects.BARRAGE_INTENSITY = 1.0
WarEffects.BARRAGE_SHELLS = 4
WarEffects.BARRAGE_SPREAD_M = 18
WarEffects.BARRAGE_STAGGER_MS = 1400
WarEffects.BARRAGE_EFFECT = "clienteffect/combat_explosion_lair_large.cef"
WarEffects.BARRAGE_SHAKE = "clienteffect/int_camshake_medium.cef"
WarEffects.BARRAGE_SMOKE = "clienteffect/lair_med_damage_smoke.cef"

WarEffects.FLARE_EVERY_PASSES = 2
WarEffects.FLARE_COUNT = 3
WarEffects.FLARE_HEIGHT_M = 30
WarEffects.FLARE_SPREAD_M = 60
WarEffects.FLARE_STAGGER_MS = 2200
WarEffects.FLARE_EFFECT = "clienteffect/combat_explosion_lair_large.cef"
WarEffects.NIGHT_ONLY = false            -- see the header; calibrate first
WarEffects.NIGHT_CYCLE_S = 7200          -- ASSUMED full day-night cycle; unverified
WarEffects.NIGHT_OFFSET_S = 0            -- calibration: seconds to add before taking the phase

WarEffects.PASS_KEY = "wareffects:pass"

local function say(fmt, ...)
	printf("WarEffects: " .. string.format(fmt, ...) .. "\n")
end

--- Seconds since this module first ran after boot -- the first tend pass,
-- about a minute after the zone's Galactic_Time zero. getTimestamp() is the
-- epoch; the anchor is shared data, so it survives reloads and is set
-- again on the first pass after a restart. NIGHT_OFFSET_S absorbs the
-- minute (calibration is against the sky anyway).
function WarEffects.uptime()
	local now = getTimestamp()
	local boot = readData("wareffects:boot") or 0
	if boot <= 0 or boot > now then
		boot = now
		writeData("wareffects:boot", boot)
	end
	return now - boot
end

--- Assumed phase in [0,1): below 0.5 day, at or above 0.5 night.
function WarEffects.phase()
	local t = (WarEffects.uptime() + WarEffects.NIGHT_OFFSET_S) % WarEffects.NIGHT_CYCLE_S
	return t / WarEffects.NIGHT_CYCLE_S
end

function WarEffects.isNight()
	return WarEffects.phase() >= 0.5
end

--- One effect at a point, broadcast from `pFrom`. Never throws.
local function fx(pFrom, effect, zone, x, y, dz)
	if pFrom == nil or effect == nil or zone == nil then
		return false
	end
	local z = WarBattle.floorAt(zone, x, y) + (dz or 0)
	local ok = pcall(playClientEffectLoc, pFrom, effect, zone, x, z, y, 0)
	return ok
end

--- Scheduled shell: "oid|effect|zone|x|y|dz|shake"
function WarEffects:shell(pObj, args)
	pcall(function()
		local f = {}
		for field in string.gmatch(tostring(args) .. "|", "([^|]*)|") do f[#f + 1] = field end
		local p = getSceneObject(tonumber(f[1]) or 0)
		if p == nil then return end
		local x, y, dz = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]) or 0
		fx(p, f[2], f[3], x, y, dz)
		if f[7] == "1" then
			fx(p, WarEffects.BARRAGE_SHAKE, f[3], x, y, 0)
			fx(p, WarEffects.BARRAGE_SMOKE, f[3], x, y, 0)
		end
	end)
end

local function schedule(delayMs, pFrom, effect, zone, x, y, dz, shake)
	local oid = SceneObject(pFrom):getObjectID()
	createEvent(delayMs, "WarEffects", "shell", nil, table.concat({
		tostring(oid), effect, zone, string.format("%.1f", x), string.format("%.1f", y),
		tostring(dz or 0), shake and "1" or "0" }, "|"))
end

--- A barrage on the attacking line of one slot. Returns shells scheduled.
function WarEffects.barrage(zone, sl, attacker)
	local bodies = {}
	for _, u in ipairs(sl.units) do
		if u.faction == attacker then bodies[#bodies + 1] = u.p end
	end
	if #bodies == 0 then
		return 0
	end
	local n = 0
	for i = 1, WarEffects.BARRAGE_SHELLS do
		local p = bodies[math.random(#bodies)]
		local so = SceneObject(p)
		local x = so:getWorldPositionX() + (math.random() * 2 - 1) * WarEffects.BARRAGE_SPREAD_M
		local y = so:getWorldPositionY() + (math.random() * 2 - 1) * WarEffects.BARRAGE_SPREAD_M
		schedule((i - 1) * WarEffects.BARRAGE_STAGGER_MS, p, WarEffects.BARRAGE_EFFECT, zone, x, y, 0, true)
		n = n + 1
	end
	say("barrage on the %s line at %s: %d shell(s)", tostring(attacker), sl.key, n)
	return n
end

--- Who broadcasts a capital's flares: its officer, else a garrison body.
local function capitalVoice(regionId, slots)
	local oid = nil
	pcall(function() oid = readSharedMemory("warofficer:npc:" .. regionId) end)
	if oid ~= nil and oid > 0 then
		local p = getSceneObject(oid)
		if p ~= nil then return p end
	end
	local sl = slots[regionId .. ":0"]
	if sl ~= nil and sl.units[1] ~= nil then
		return sl.units[1].p
	end
	return nil
end

--- Flares over one besieged capital. Returns bursts scheduled.
function WarEffects.flares(regionId, slots)
	local zone = (WarReport ~= nil) and WarReport.PLANET_OF[regionId] or nil
	local coords = (WarReport ~= nil) and WarReport.COORDS[regionId] or nil
	if zone == nil or coords == nil then
		return 0
	end
	local pFrom = capitalVoice(regionId, slots)
	if pFrom == nil then
		return 0
	end
	local n = 0
	for i = 1, WarEffects.FLARE_COUNT do
		local x = coords[1] + (math.random() * 2 - 1) * WarEffects.FLARE_SPREAD_M
		local y = coords[2] + (math.random() * 2 - 1) * WarEffects.FLARE_SPREAD_M
		schedule((i - 1) * WarEffects.FLARE_STAGGER_MS, pFrom, WarEffects.FLARE_EFFECT, zone, x, y,
			WarEffects.FLARE_HEIGHT_M, false)
		n = n + 1
	end
	say("flares over %s: %d", regionId, n)
	return n
end

--- One pass, from WarBattle.tendOnce. `slots` = WarBattle.liveSlots(),
-- `fronts` = { [regionId] = front }. `force` ignores the intervals.
function WarEffects.tickOnce(slots, fronts, force)
	if not WarEffects.ENABLED then
		return 0
	end
	WarEffects.uptime() -- anchor the day-night clock on the first pass after boot
	local pass = (readData(WarEffects.PASS_KEY) or 0) + 1
	writeData(WarEffects.PASS_KEY, pass)
	local st = (WarReport ~= nil) and WarReport.state() or nil
	if st == nil then
		return 0
	end
	local fired = 0

	if force or (pass % WarEffects.BARRAGE_EVERY_PASSES) == 0 then
		for key, sl in pairs(slots) do
			local isGarrison = (sl.site == "0") or (string.sub(tostring(sl.site), 1, 1) == "c")
			local f = fronts[sl.region]
			local r = st.regions[sl.region]
			local zone = (WarReport ~= nil) and WarReport.PLANET_OF[sl.region] or nil
			if (not isGarrison) and f ~= nil and r ~= nil and zone ~= nil then
				-- `force` (the probe) treats every site as hot and every
				-- capital as besieged, so the scheduling path is exercised
				-- even on a quiet map.
				local hot = force or f.offensive == true or (WarEffects.BARRAGE_ALSO_HOT
					and (tonumber(f.intensity) or 0) >= WarEffects.BARRAGE_INTENSITY)
				local holder = r.faction
				local attacker = (f.attacker ~= nil) and f.attacker or ((holder == "rebel") and "imperial" or "rebel")
				if hot and (sl.alive[holder] or 0) > 0 and (sl.alive[attacker] or 0) > 0 then
					local ok, n = pcall(WarEffects.barrage, zone, sl, attacker)
					if ok then fired = fired + (n or 0) else say("barrage failed: %s", tostring(n)) end
				end
			end
		end
	end

	if force or (pass % WarEffects.FLARE_EVERY_PASSES) == 0 then
		if force or (not WarEffects.NIGHT_ONLY) or WarEffects.isNight() then
			for rid, r in pairs(st.regions or {}) do
				if r.is_capital == true and (force or (type(r.siege) == "table" and r.siege.active == true)) then
					local ok, n = pcall(WarEffects.flares, rid, slots)
					if ok then fired = fired + (n or 0) else say("flares failed: %s", tostring(n)) end
				end
			end
		end
	end
	return fired
end

-- -------------------------------------------------------------- probes --

function Tests:warEffectsNow()
	printf("WAREFFECTS: begin\n")
	local ok, err = pcall(function()
		local fronts = {}
		for _, f in ipairs(WarBattle.fronts()) do fronts[f.id] = f end
		local slots = WarBattle.liveSlots()
		local n = WarEffects.tickOnce(slots, fronts, true)
		printf("WAREFFECTS: " .. tostring(n) .. " effect(s) scheduled (intervals ignored)\n")
		local st = WarReport.state()
		local sieges = {}
		for rid, r in pairs(st.regions or {}) do
			if r.is_capital == true and type(r.siege) == "table" then
				sieges[#sieges + 1] = rid .. "=" .. tostring(r.siege.active)
			end
		end
		printf("WAREFFECTS: capitals " .. table.concat(sieges, " ") .. "\n")
	end)
	if not ok then
		printf("WAREFFECTS: failed: " .. tostring(err) .. "\n")
	end
	printf("WAREFFECTS: end\n")
end

function Tests:warEffectsPhase()
	printf(string.format("WAREFFECTS: uptime=%ds cycle=%ds offset=%ds phase=%.2f night=%s NIGHT_ONLY=%s\n",
		WarEffects.uptime(), WarEffects.NIGHT_CYCLE_S, WarEffects.NIGHT_OFFSET_S, WarEffects.phase(),
		tostring(WarEffects.isNight()), tostring(WarEffects.NIGHT_ONLY)))
end
