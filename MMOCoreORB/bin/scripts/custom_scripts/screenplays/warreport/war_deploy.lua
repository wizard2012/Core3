--[[
war_deploy.lua -- Deploy to the front (B42; owner ruling 2026-09-07, through
the question tool: "Deploy to the front").

The officer's "Deploy" radial (id 22) moves an enlisted player to the front
their side is fighting: an attacker lands at the front's staging town (the
sim's `staging` field -- where the assault forms up), a defender in the
besieged town itself. The hottest front comes first (WarBattle.fronts() is
sorted by intensity); an open order at a front takes precedence, so a player
with orders is sent where the orders are. The ride is instant (switchZone to
the officer post when the town has one, else the town centre, on the world
floor), with a per-player wait between rides (COOLDOWN_MS), and it is refused
dead, incapacitated, in combat, mounted, unenlisted, or when there is no
front (the intermission: fronts() is empty then).

Pure, tested in bridge/tests/t_readouts.lua:
  WarDeploy.destination(fronts, faction, orderRegion) -> { front, region, role, intensity } | nil
  WarDeploy.text(dest)     -> the line the player reads before the ride
  WarDeploy.waitText(ms)   -> the refusal while the transport is out
State: readData/writeData "<oid>:war:lastDeploy" (the recruiter's brief
pattern), so it survives a reload and not a restart.
Console probe: test warDeployCheck (also in test warAllCheck).
]]

WarDeploy = WarDeploy or {}

WarDeploy.RADIAL_ID = 22
WarDeploy.COOLDOWN_MS = 10 * 60 * 1000       -- one ride per ten minutes per player
WarDeploy.LAST_KEY_SUFFIX = ":war:lastDeploy"
WarDeploy.POST_OFFSET_M = 3                  -- land beside the officer, not on him

local function name(id)
	if WarLines ~= nil and WarLines.name ~= nil then
		return WarLines.name(id)
	end
	return tostring(id)
end

local function lastKey(oid)
	return tostring(oid) .. WarDeploy.LAST_KEY_SUFFIX
end

--- Where a player of `faction` deploys, from a WarBattle.fronts() list
-- (hottest first: { id, faction = holder, attacker, staging, intensity }).
-- An attacker goes to the front's staging town, a holder to the town; a
-- front the player holds orders for wins over the hottest one; an attack
-- with no staging town recorded is skipped. nil when the side fights
-- nowhere. Pure.
function WarDeploy.destination(fronts, faction, orderRegion)
	if type(fronts) ~= "table" or faction == nil then
		return nil
	end
	local best = nil
	for i = 1, #fronts do
		local f = fronts[i]
		if type(f) == "table" and f.id ~= nil then
			local role = nil
			if f.attacker == faction then
				role = "assault"
			elseif f.faction == faction then
				role = "defence"
			end
			local region = (role == "assault") and f.staging or ((role == "defence") and f.id or nil)
			if region ~= nil then
				local d = { front = f.id, region = region, role = role, intensity = tonumber(f.intensity) or 0 }
				if orderRegion ~= nil and f.id == orderRegion then
					return d
				end
				if best == nil then
					best = d
				end
			end
		end
	end
	return best
end

--- The line the player reads as the transport leaves. Pure.
function WarDeploy.text(d)
	if d == nil then
		return nil
	end
	if d.role == "assault" then
		return "Transport to " .. name(d.region) .. ": the assault on " .. name(d.front) .. " stages there."
	end
	return "Transport to " .. name(d.region) .. ": it is under assault and the garrison needs you."
end

--- What to do where you already are. Pure.
function WarDeploy.hereText(d)
	if d == nil then
		return nil
	end
	if d.role == "assault" then
		return "the assault on " .. name(d.front) .. " forms up here."
	end
	return "hold it."
end

--- The refusal while the transport is out. Pure.
function WarDeploy.waitText(msLeft)
	local m = math.max(1, math.ceil((tonumber(msLeft) or 0) / 60000))
	return "The transport is not back yet: " .. tostring(m) .. " minute" .. ((m == 1) and "" or "s") .. "."
end

--- The landing point in a destination town: beside the officer post when
-- the town has one, else the town centre. Returns zone, x, y or nil.
function WarDeploy.landing(regionId)
	if WarReport == nil or WarReport.COORDS == nil or WarReport.PLANET_OF == nil then
		return nil
	end
	local coords = WarReport.COORDS[regionId]
	local zone = WarReport.PLANET_OF[regionId]
	if coords == nil or zone == nil then
		return nil
	end
	local x, y = coords[1], coords[2]
	if WarOfficer ~= nil and type(WarOfficer.POSTS) == "table" then
		for i = 1, #WarOfficer.POSTS do
			local post = WarOfficer.POSTS[i]
			if post.region == regionId and post.zone == zone then
				x, y = post.x + WarDeploy.POST_OFFSET_M, post.y + WarDeploy.POST_OFFSET_M
			end
		end
	end
	return zone, x, y
end

--- The officer's "Deploy" radial.
function WarDeploy.onRadial(pPlayer, pOfficer)
	if pPlayer == nil then
		return
	end
	local creature = CreatureObject(pPlayer)
	local faction = (WarStandings ~= nil and WarStandings.factionOf ~= nil) and WarStandings.factionOf(pPlayer) or nil
	if faction == nil then
		creature:sendSystemMessage("The transport is for the enlisted. Declare for a side first.")
		return
	end
	if creature:isDead() or creature:isIncapacitated() then
		creature:sendSystemMessage("Not in that state.")
		return
	end
	if creature:isInCombat() then
		creature:sendSystemMessage("Not while you are in combat.")
		return
	end
	if creature:isRidingMount() then
		creature:sendSystemMessage("Dismount first.")
		return
	end
	local fronts = (WarBattle ~= nil and WarBattle.fronts ~= nil) and WarBattle.fronts() or {}
	if #fronts == 0 then
		creature:sendSystemMessage("No transport: there is no front to deploy to.")
		return
	end
	local oid = SceneObject(pPlayer):getObjectID()
	local now = getTimestampMilli()
	local last = readData(lastKey(oid))
	if last ~= nil and last > 0 and (now - last) < WarDeploy.COOLDOWN_MS then
		creature:sendSystemMessage(WarDeploy.waitText(WarDeploy.COOLDOWN_MS - (now - last)))
		return
	end
	local orderRegion = nil
	if WarOrders ~= nil and WarOrders.active ~= nil then
		local o = WarOrders.active(oid)
		if o ~= nil and now < (o.expiresAt or 0) then
			orderRegion = o.region
		end
	end
	local d = WarDeploy.destination(fronts, faction, orderRegion)
	if d == nil then
		creature:sendSystemMessage("No transport: your side has no front right now.")
		return
	end
	local zone, x, y = WarDeploy.landing(d.region)
	if zone == nil then
		creature:sendSystemMessage("No transport: nobody here knows the way to " .. name(d.region) .. ".")
		return
	end
	-- Already there (the verifier, 2026-09-07: a defender standing in the
	-- besieged town would burn the wait for a three-metre hop).
	if WarReport ~= nil and WarReport.regionAt ~= nil then
		local here = WarReport.regionAt(SceneObject(pPlayer):getZoneName(),
			SceneObject(pPlayer):getWorldPositionX(), SceneObject(pPlayer):getWorldPositionY())
		if here == d.region then
			creature:sendSystemMessage("You are already at " .. name(d.region) .. ": " .. WarDeploy.hereText(d))
			return
		end
	end
	local z = getWorldFloor(x, y, zone)
	creature:sendSystemMessage(WarDeploy.text(d))
	printf("WarDeploy: " .. tostring(oid) .. " (" .. faction .. ") to " .. d.region .. " -- " .. d.role .. " of " .. d.front
		.. " at " .. zone .. " " .. tostring(x) .. ", " .. tostring(y) .. "\n")
	local moved = pcall(function() SceneObject(pPlayer):switchZone(zone, x, z, y, 0) end)
	-- The wait is charged for a ride that happened, not for a refusal
	-- (the verifier, 2026-09-07).
	if moved then
		writeData(lastKey(oid), now)
	end
end

-- Console probe: test warDeployCheck
if type(Tests) == "table" then
	function Tests:warDeployCheck()
		printf("WARDEPLOY: begin\n")
		local ok, err = pcall(function()
			-- pure: a synthetic fronts list
			local fronts = {
				{ id = "nab_theed", faction = "imperial", attacker = "rebel", staging = "nab_moenia", intensity = 1.3 },
				{ id = "tat_bestine", faction = "rebel", attacker = "imperial", staging = "tat_mos_eisley", intensity = 0.2 },
			}
			local d1 = WarDeploy.destination(fronts, "rebel", nil)
			printf("WARDEPLOY: " .. ((d1 ~= nil and d1.region == "nab_moenia" and d1.role == "assault") and "PASS" or "FAIL")
				.. " attacker goes to the staging town\n")
			local d2 = WarDeploy.destination(fronts, "imperial", nil)
			printf("WARDEPLOY: " .. ((d2 ~= nil and d2.region == "nab_theed" and d2.role == "defence") and "PASS" or "FAIL")
				.. " holder goes to the town\n")
			local d3 = WarDeploy.destination(fronts, "imperial", "tat_bestine")
			printf("WARDEPLOY: " .. ((d3 ~= nil and d3.region == "tat_mos_eisley") and "PASS" or "FAIL")
				.. " an order at a front wins over the hottest\n")
			printf("WARDEPLOY: " .. ((WarDeploy.destination({}, "rebel", nil) == nil) and "PASS" or "FAIL") .. " no fronts, no ride\n")
			printf("WARDEPLOY: text | " .. tostring(WarDeploy.text(d1)) .. "\n")
			printf("WARDEPLOY: wait | " .. WarDeploy.waitText(61000) .. "\n")
			-- live: where each side deploys right now
			local live = (WarBattle ~= nil and WarBattle.fronts ~= nil) and WarBattle.fronts() or {}
			printf("WARDEPLOY: live fronts = " .. tostring(#live) .. "\n")
			for _, faction in ipairs({ "imperial", "rebel" }) do
				local d = WarDeploy.destination(live, faction, nil)
				if d == nil then
					printf("WARDEPLOY: " .. faction .. " | no front\n")
				else
					local zone, x, y = WarDeploy.landing(d.region)
					local z = (zone ~= nil) and getWorldFloor(x, y, zone) or nil
					printf("WARDEPLOY: " .. faction .. " | " .. d.role .. " of " .. d.front .. " -> " .. d.region .. " | "
						.. tostring(zone) .. " " .. tostring(x) .. ", " .. tostring(y) .. " z=" .. tostring(z) .. " | " .. tostring(WarDeploy.text(d)) .. "\n")
					printf("WARDEPLOY: " .. ((zone ~= nil and z ~= nil) and "PASS" or "FAIL") .. " " .. faction .. " landing resolves\n")
				end
			end
			printf("WARDEPLOY: " .. ((WarOfficerReportMenuComponent ~= nil) and "PASS" or "FAIL") .. " officer menu component present\n")
		end)
		if not ok then
			printf("WARDEPLOY: failed: " .. tostring(err) .. "\n")
		end
		printf("WARDEPLOY: end\n")
	end
end
