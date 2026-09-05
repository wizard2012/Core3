--[[
  custom_scripts/screenplays/simplayers/sim_probe.lua

  Console probes for SimPlayers. Inject with
    screen -S swgemu-server -X stuff 'test simPlayersDump\n'
  and grep SIMPLAYERS in screenlog.0.

    simPlayersDump        every character: state, where, time left, body
                          alive, xp/rank, world position. Read-only.
    simPlayersTickNow     one pass of the loop, no reschedule.
    simPlayersDepartAll   every resting character decides and leaves NOW
                          (proves travel + decide without waiting minutes).
    simPlayersArriveAll   every travelling/cloning character arrives on the
                          next tick (their timers are zeroed), then one tick.
    simPlayersRespawnAll  despawn everyone and forget their state; the next
                          tick puts them home at rest. Rank is kept.
]]

local function eachSim(fn)
	if type(SIM_CONFIG) ~= "table" or type(SIM_CONFIG.ROSTER) ~= "table" then
		printf("SIMPLAYERS: SIM_CONFIG missing\n")
		return
	end
	for i, sim in ipairs(SIM_CONFIG.ROSTER) do
		fn(i, sim, SimPlayers.load(sim.id))
	end
end

function Tests:simPlayersDump()
	printf("SIMPLAYERS: dump begin\n")
	local chain = readSharedMemory(SimPlayers.CHAIN_KEY) or 0
	printf(string.format("SIMPLAYERS: chain heartbeat %ds ago, enabled=%s\n",
		(chain > 0) and math.floor((getTimestampMilli() - chain) / 1000) or -1,
		tostring(type(SIM_CONFIG) == "table" and SIM_CONFIG.ENABLED)))
	eachSim(function(i, sim, st)
		local p = (st.oid ~= nil and st.oid ~= 0) and getSceneObject(st.oid) or nil
		local where = "n/a"
		if p ~= nil then
			-- A corpse resolves; report it as not alive, like step() does.
			local okd, dead = pcall(function() return CreatureObject(p):isDead() end)
			if okd and dead then
				where = "DEAD (corpse still in world)"
				p = nil
			end
		end
		if p ~= nil then
			local ok, s = pcall(function()
				local so = SceneObject(p)
				return string.format("%s cell=%s x=%.0f y=%.0f name=%s combat=%s",
					so:getZoneName(), tostring(so:getParentID()), so:getWorldPositionX(), so:getWorldPositionY(),
					tostring(so:getDisplayedName()), tostring(CreatureObject(p):isInCombat()))
			end)
			where = ok and s or ("err " .. tostring(s))
		end
		local left = math.floor(((st.until_ms or 0) - getTimestampMilli()) / 1000)
		printf(string.format("SIMPLAYERS: %-6s %-14s %-8s %-9s region=%-15s dest=%-15s left=%5ds xp=%d rank=%d(%s) alive=%s at %s\n",
			sim.id, sim.name, sim.faction, st.state, tostring(st.region), tostring(st.dest), left,
			math.floor(st.xp or 0), st.rank or 1, SimPlayers.rankTitle(sim, st.rank or 1),
			tostring(p ~= nil), where))
	end)
	printf("SIMPLAYERS: dump end\n")
end

function Tests:simPlayersTickNow()
	printf("SIMPLAYERS: tick begin\n")
	local n = SimPlayers:tickOnce()
	printf("SIMPLAYERS: tick end -- stepped " .. tostring(n) .. "\n")
end

function Tests:simPlayersDepartAll()
	printf("SIMPLAYERS: departAll begin\n")
	local n = 0
	eachSim(function(i, sim, st)
		if st.state == "rest" then
			st.until_ms = 0
			SimPlayers.save(sim.id, st)
			n = n + 1
		end
	end)
	SimPlayers:tickOnce()
	printf("SIMPLAYERS: departAll end -- " .. tostring(n) .. " sent on their way\n")
end

function Tests:simPlayersArriveAll()
	printf("SIMPLAYERS: arriveAll begin\n")
	local n = 0
	eachSim(function(i, sim, st)
		if st.state == "travel" or st.state == "clone" then
			st.until_ms = 0
			SimPlayers.save(sim.id, st)
			n = n + 1
		end
	end)
	SimPlayers:tickOnce()
	printf("SIMPLAYERS: arriveAll end -- " .. tostring(n) .. " arrived\n")
end

function Tests:simPlayersRespawnAll()
	printf("SIMPLAYERS: respawnAll begin\n")
	eachSim(function(i, sim, st)
		local p = (st.oid ~= nil and st.oid ~= 0) and getSceneObject(st.oid) or nil
		if p ~= nil then
			pcall(function() SceneObject(p):destroyObjectFromWorld(false) end)
		end
		local keep = { xp = st.xp or 0, rank = st.rank or 1 }
		pcall(function() deleteStringData("simplayers:" .. sim.id) end)
		local fresh = SimPlayers.load(sim.id)
		fresh.xp, fresh.rank = keep.xp, keep.rank
		SimPlayers.save(sim.id, fresh)
	end)
	SimPlayers:tickOnce()
	printf("SIMPLAYERS: respawnAll end\n")
end

function Tests:simPlayersEnsureChain()
	local ok, err = pcall(function() return SimPlayers:ensureChain() end)
	printf("SIMPLAYERS: ensureChain ok=" .. tostring(ok) .. " result=" .. tostring(err) .. "\n")
end

--- Are the war NPCs actually fighting? Per site (region:site) from
-- war_battles
