--[[
  custom_scripts/screenplays/warreport/war_template_probe.lua

  Diagnostics for the war's own templates (custom_scripts/mobile/war/
  war_troops.lua):

    test warTemplateCheck   spawn one war trooper beside one stock trooper,
                            print what the AI reads from each, despawn.
    test warTemplateFight   spawn a war Imperial against a war Rebel ten
                            metres apart, set them on each other, and report
                            both bodies' health and weapon 20 s later; a
                            stock pair alongside as the control.
]]

WarTemplateProbe = WarTemplateProbe or { screenplayName = "WarTemplateProbe" }

local function describe(p)
	local so, c, a = SceneObject(p), CreatureObject(p), AiAgent(p)
	local weapon = "none"
	pcall(function()
		local w = so:getSlottedObject("hold_r")
		if w ~= nil then weapon = SceneObject(w):getTemplateObjectPath() end
	end)
	local ham = "?"
	pcall(function() ham = tostring(c:getHAM(0)) .. "/" .. tostring(c:getMaxHAM(0)) end)
	local dead = "?"
	pcall(function() dead = tostring(c:isDead()) end)
	local combat = "?"
	pcall(function() combat = tostring(c:isInCombat()) end)
	return string.format("tpl=%s level=%s health=%s dead=%s inCombat=%s weapon=%s",
		tostring(a:getCreatureTemplateName()), tostring(c:getLevel()), ham, dead, combat, weapon)
end

function Tests:warTemplateCheck()
	printf("WARTEMPLATE: begin\n")
	local zone = "tatooine"
	local x, y = -1300, -3700
	local pairs_ = {
		{ "war_imperial_rifleman", "stormtrooper" },
		{ "war_rebel_rifleman", "rebel_trooper" },
		{ "war_imperial_sergeant", "stormtrooper_squad_leader" },
	}
	for i, pr in ipairs(pairs_) do
		for j, tpl in ipairs(pr) do
			local ok, err = pcall(function()
				local p = spawnMobile(zone, tpl, 0, x + i * 6, 0, y + j * 6, 0, 0)
				if p == nil then
					printf("WARTEMPLATE: " .. tpl .. " -> spawnMobile returned nil\n")
					return
				end
				local a = AiAgent(p)
				printf(string.format("WARTEMPLATE: %-26s dmg=%s-%s hit=%s faction=%s %s\n",
					tpl, tostring(a:getDamageMin()), tostring(a:getDamageMax()), tostring(a:getChanceHit()),
					tostring(a:getFactionString()), describe(p)))
				pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
			end)
			if not ok then
				printf("WARTEMPLATE: " .. tpl .. " probe failed: " .. tostring(err) .. "\n")
			end
		end
	end
	printf("WARTEMPLATE: end\n")
end

function Tests:warTemplateFight()
	printf("WARFIGHT: begin\n")
	local zone = "tatooine"
	local x, y = -1300, -3740
	local pairs_ = {
		{ tag = "war",   a = "war_imperial_rifleman", b = "war_rebel_rifleman" },
		{ tag = "stock", a = "stormtrooper",          b = "rebel_trooper" },
	}
	local oids = {}
	for i, pr in ipairs(pairs_) do
		local ok, err = pcall(function()
			local pA = spawnMobile(zone, pr.a, 0, x + i * 30, 0, y, 0, 0)
			local pB = spawnMobile(zone, pr.b, 0, x + i * 30, 0, y + 10, 180, 0)
			if pA == nil or pB == nil then
				printf("WARFIGHT: " .. pr.tag .. " -> spawnMobile returned nil\n")
				return
			end
			pcall(function() AiAgent(pA):setDefender(pB) end)
			pcall(function() AiAgent(pB):setDefender(pA) end)
			pcall(function() AiAgent(pA):setFollowObject(pB) end)
			pcall(function() AiAgent(pB):setFollowObject(pA) end)
			oids[#oids + 1] = pr.tag .. "=" .. tostring(SceneObject(pA):getObjectID()) .. ":" .. tostring(SceneObject(pB):getObjectID())
			printf("WARFIGHT: " .. pr.tag .. " pair spawned and set on each other\n")
		end)
		if not ok then
			printf("WARFIGHT: " .. pr.tag .. " failed: " .. tostring(err) .. "\n")
		end
	end
	createEvent(20000, "WarTemplateProbe", "report", nil, table.concat(oids, ";"))
	printf("WARFIGHT: report in 20 s\n")
end

function WarTemplateProbe:report(pObj, args)
	printf("WARFIGHT: report\n")
	for entry in string.gmatch(tostring(args) .. ";", "([^;]*);") do
		local tag, a, b = string.match(entry, "^(%w+)=(%d+):(%d+)$")
		if tag ~= nil then
			for _, oid in ipairs({ a, b }) do
				local p = getSceneObject(tonumber(oid))
				if p == nil then
					printf("WARFIGHT: " .. tag .. " " .. oid .. " -> gone (despawned or reaped)\n")
				else
					printf("WARFIGHT: " .. tag .. " " .. describe(p) .. "\n")
					pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
				end
			end
		end
	end
	printf("WARFIGHT: end\n")
end

--- test warSitePositions: every tracked body at every staged site (slot
-- index other than 0 / c*), with its position, movement state, follow
-- target and distance to the nearest enemy body -- for a site that stands
-- in combat with nobody hurt.
function Tests:warSitePositions()
	printf("WARSITEPOS: begin\n")
	local raw = readStringData(WarBattle.ROSTER_KEY)
	if raw == nil or raw == "" then
		printf("WARSITEPOS: roster empty\n")
		return
	end
	local sites = {}
	for rec in string.gmatch(raw, "([^;]+)") do
		local oid, region, site, fac = string.match(rec, "^(%d+)|([%w_]+)|([%w_]+)|([%w_]+)")
		if oid ~= nil and site ~= "0" and string.sub(site, 1, 1) ~= "c" then
			local key = region .. ":" .. site
			sites[key] = sites[key] or {}
			local p = getSceneObject(tonumber(oid))
			if p ~= nil then
				local so = SceneObject(p)
				local rec2 = { p = p, fac = fac, x = so:getWorldPositionX(), y = so:getWorldPositionY(), z = so:getWorldPositionZ() }
				sites[key][#sites[key] + 1] = rec2
			end
		end
	end
	for key, bodies in pairs(sites) do
		printf("WARSITEPOS: " .. key .. " bodies=" .. #bodies .. "\n")
		for _, b in ipairs(bodies) do
			local nearest, nd = nil, 1e9
			for _, o in ipairs(bodies) do
				if o.fac ~= b.fac then
					local d = math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y) ^ 2)
					if d < nd then nd, nearest = d, o end
				end
			end
			local c, a = CreatureObject(b.p), AiAgent(b.p)
			local ms, fo, dead, hp, inr, parent = "?", "?", "?", "?", "?", "?"
			pcall(function() ms = tostring(a:getMovementState()) end)
			pcall(function() fo = tostring(a:getFollowObject() ~= nil) end)
			pcall(function() dead = tostring(c:isDead()) end)
			pcall(function() hp = tostring(c:getHAM(0)) .. "/" .. tostring(c:getMaxHAM(0)) end)
			pcall(function() parent = tostring(SceneObject(b.p):getParentID()) end)
			if nearest ~= nil then
				pcall(function() inr = tostring(SceneObject(b.p):isInRange(nearest.p, 32)) end)
			end
			printf(string.format("WARSITEPOS:   %-8s %s at %.0f,%.0f,%.1f parent=%s move=%s follow=%s dead=%s hp=%s nearestEnemy=%.0fm inRange32=%s\n",
				b.fac, tostring(a:getCreatureTemplateName()), b.x, b.y, b.z, parent, ms, fo, dead, hp, nd, inr))
		end
	end
	printf("WARSITEPOS: end\n")
end

--- test warSiteGround: for every staged site, the ground along the
-- outward radial -- terrain height, world floor and walkability at the
-- origin and at 24/48/80/120/160 m -- to tell a site standing in water,
-- inside a building or under the terrain from one on open ground.
function Tests:warSiteGround()
	printf("WARGROUND: begin\n")
	local slots = WarBattle.liveSlots()
	local keys = {}
	for k, _ in pairs(slots) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local sl = slots[key]
		local isGarrison = (sl.site == "0") or (string.sub(tostring(sl.site), 1, 1) == "c")
		local zone = (WarReport ~= nil) and WarReport.PLANET_OF[sl.region] or nil
		if (not isGarrison) and zone ~= nil and sl.ox ~= nil then
			local coords = (WarReport ~= nil) and WarReport.COORDS[sl.region] or nil
			local tx, ty = coords and coords[1] or sl.ox, coords and coords[2] or sl.oy
			local ux, uy = sl.ox - tx, sl.oy - ty
			local len = math.sqrt(ux * ux + uy * uy)
			if len < 1 then ux, uy, len = 1, 0, 1 end
			ux, uy = ux / len, uy / len
			printf(string.format("WARGROUND: %s origin=%.0f,%.0f town=%.0f,%.0f ring=%.0fm\n", key, sl.ox, sl.oy, tx, ty, len))
			for _, d in ipairs({ 0, 24, 48, 80, 120, 160 }) do
				local x, y = sl.ox + ux * d, sl.oy + uy * d
				local th, wf, walk = "?", "?", "?"
				pcall(function() th = string.format("%.1f", getTerrainHeight(zone, x, y)) end)
				pcall(function() wf = string.format("%.1f", getWorldFloor(x, y, zone)) end)
				pcall(function()
					local z = tonumber(wf) or tonumber(th) or 0
					walk = tostring(isPointWalkable(zone, x, z, y))
				end)
				printf(string.format("WARGROUND:   +%3dm at %.0f,%.0f terrain=%s floor=%s walkable=%s\n", d, x, y, th, wf, walk))
			end
		end
	end
	printf("WARGROUND: end\n")
end

--- test warStuckCheck: per live slot, liveSlots' hurt/dead counts and the
-- quiet / stuck / siteturn counters the stuck rule keeps.
function Tests:warStuckCheck()
	printf("WARSTUCK: begin STUCK_PASSES=" .. tostring(WarBattle.STUCK_PASSES) .. " tendStuck=" .. tostring(WarBattle.tendStuck ~= nil) .. "\n")
	local slots = WarBattle.liveSlots()
	local keys = {}
	for k, _ in pairs(slots) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local sl = slots[key]
		local alive = {}
		for f, n in pairs(sl.alive) do alive[#alive + 1] = f .. "=" .. n end
		printf(string.format("WARSTUCK: %-20s alive=%s hurt=%s dead=%s quiet=%s stuck=%s siteturn=%s\n",
			key, table.concat(alive, ","), tostring(sl.hurt), tostring(sl.dead),
			tostring(readData("warbattle:quiet:" .. key)), tostring(readData("warbattle:stuck:" .. key)),
			tostring(readData("warbattle:siteturn:" .. sl.region))))
	end
	printf("WARSTUCK: end\n")
end

--- test warWalkerFight: a war AT-ST against three war Rebel riflemen, and
-- the liberated AT-ST against three war stormtroopers; health of every
-- body 30 s later.
function Tests:warWalkerFight()
	printf("WARWALKER: begin\n")
	local zone = "tatooine"
	local x, y = -1300, -3800
	local pairs_ = {
		{ tag = "atst",  w = "war_at_st",             t = "war_rebel_rifleman" },
		{ tag = "libst", w = "war_at_st_liberated",   t = "war_imperial_rifleman" },
		{ tag = "stock", w = "at_st",                 t = "war_rebel_rifleman" },
		{ tag = "ctl",   w = "war_imperial_rifleman", t = "war_rebel_rifleman" },
	}
	local oids = {}
	for i, pr in ipairs(pairs_) do
		local ok, err = pcall(function()
			local wx, wy = x + i * 40, y
			local pW = spawnMobile(zone, pr.w, 0, wx, WarBattle.floorAt(zone, wx, wy), wy, 0, 0)
			if pW == nil then
				printf("WARWALKER: " .. pr.w .. " -> spawnMobile returned nil\n")
				return
			end
			local ids = { tostring(SceneObject(pW):getObjectID()) }
			for k = 1, 3 do
				local tx, ty = wx + (k - 2) * 4, wy + 12
				local pT = spawnMobile(zone, pr.t, 0, tx, WarBattle.floorAt(zone, tx, ty), ty, 180, 0)
				if pT ~= nil then
					ids[#ids + 1] = tostring(SceneObject(pT):getObjectID())
					pcall(function() AiAgent(pT):setDefender(pW) end)
					pcall(function() AiAgent(pT):setFollowObject(pW) end)
					pcall(function() AiAgent(pW):setDefender(pT) end)
					if k == 1 then
						local a2b, b2a = "?", "?"
						pcall(function() a2b = tostring(CreatureObject(pW):isAttackableBy(pT)) end)
						pcall(function() b2a = tostring(CreatureObject(pT):isAttackableBy(pW)) end)
						printf(string.format("WARWALKER: %s walker attackable by trooper=%s, trooper attackable by walker=%s, walker z=%.1f vehicle=%s\n",
							pr.tag, a2b, b2a, SceneObject(pW):getWorldPositionZ(), tostring(SceneObject(pW):isVehicleObject())))
					end
				end
			end
			oids[#oids + 1] = pr.tag .. "=" .. table.concat(ids, ":")
			printf("WARWALKER: " .. pr.tag .. " spawned " .. #ids .. " bodies\n")
		end)
		if not ok then
			printf("WARWALKER: " .. pr.tag .. " failed: " .. tostring(err) .. "\n")
		end
	end
	createEvent(30000, "WarTemplateProbe", "walkerReport", nil, table.concat(oids, ";"))
	printf("WARWALKER: report in 30 s\n")
end

function WarTemplateProbe:walkerReport(pObj, args)
	printf("WARWALKER: report\n")
	for entry in string.gmatch(tostring(args) .. ";", "([^;]*);") do
		local tag, rest = string.match(entry, "^(%w+)=(.+)$")
		if tag ~= nil then
			for oid in string.gmatch(rest, "(%d+)") do
				local p = getSceneObject(tonumber(oid))
				if p == nil then
					printf("WARWALKER: " .. tag .. " " .. oid .. " -> gone\n")
				else
					printf("WARWALKER: " .. tag .. " " .. describe(p) .. "\n")
					pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
				end
			end
		end
	end
	printf("WARWALKER: end\n")
end

--- test warCombatCheck: is NPC combat and NPC movement working at all right
-- now? A stock pair 8 m apart set on each other, and a follower 40 m from
-- its target with only setFollowObject. Report after 10 s: health, weapon,
-- movement state, defender count, and how far the follower moved.
function Tests:warCombatCheck()
	printf("WARCOMBAT: begin\n")
	local zone = "tatooine"
	local x, y = -1420, -3760
	local ok, err = pcall(function()
		local function at(px, py, tpl, heading)
			return spawnMobile(zone, tpl, 0, px, WarBattle.floorAt(zone, px, py), py, heading, 0)
		end
		local pA = at(x, y, "stormtrooper", 0)
		local pB = at(x, y + 8, "rebel_trooper", 180)
		local pC = at(x + 40, y, "stormtrooper", 0)
		local pD = at(x + 40, y + 40, "rebel_trooper", 0)
		if pA == nil or pB == nil or pC == nil or pD == nil then
			printf("WARCOMBAT: a spawn failed\n")
			return
		end
		AiAgent(pA):setDefender(pB)
		AiAgent(pB):setDefender(pA)
		AiAgent(pC):setFollowObject(pD)
		-- The wake-up: setDefender/setFollowObject set the state but never
		-- schedule the behaviour event when no player is in range; this does.
		for _, p in ipairs({ pA, pB, pC }) do
			pcall(function() AiAgent(p):executeBehavior() end)
		end
		local ids = {}
		for _, p in ipairs({ pA, pB, pC, pD }) do ids[#ids + 1] = tostring(SceneObject(p):getObjectID()) end
		createEvent(10000, "WarTemplateProbe", "combatReport", nil, table.concat(ids, ":"))
		printf("WARCOMBAT: spawned; report in 10 s\n")
	end)
	if not ok then
		printf("WARCOMBAT: failed: " .. tostring(err) .. "\n")
	end
end

function WarTemplateProbe:combatReport(pObj, args)
	printf("WARCOMBAT: report\n")
	local ps = {}
	for oid in string.gmatch(tostring(args), "(%d+)") do
		ps[#ps + 1] = getSceneObject(tonumber(oid))
	end
	local names = { "A-storm", "B-rebel", "C-follower", "D-target" }
	for i, p in ipairs(ps) do
		if p == nil then
			printf("WARCOMBAT: " .. names[i] .. " gone\n")
		else
			local so, c, a = SceneObject(p), CreatureObject(p), AiAgent(p)
			local defenders, target, ms, fo = "?", "?", "?", "?"
			pcall(function() defenders = tostring(c:getDefenderCount()) end)
			pcall(function() target = tostring(c:getTargetID()) end)
			pcall(function() ms = tostring(a:getMovementState()) end)
			pcall(function() fo = tostring(a:getFollowObject() ~= nil) end)
			local dist = "?"
			if i == 3 and ps[4] ~= nil then
				local so4 = SceneObject(ps[4])
				dist = string.format("%.1f", math.sqrt((so:getWorldPositionX() - so4:getWorldPositionX()) ^ 2 + (so:getWorldPositionY() - so4:getWorldPositionY()) ^ 2))
			end
			printf(string.format("WARCOMBAT: %-10s %s defenders=%s target=%s move=%s follow=%s pos=%.0f,%.0f,%.1f distToTarget=%s\n",
				names[i], describe(p), defenders, target, ms, fo, so:getWorldPositionX(), so:getWorldPositionY(), so:getWorldPositionZ(), dist))
		end
	end
	for _, p in ipairs(ps) do
		if p ~= nil then pcall(function() SceneObject(p):destroyObjectFromWorld(false) end) end
	end
	printf("WARCOMBAT: end\n")
end
