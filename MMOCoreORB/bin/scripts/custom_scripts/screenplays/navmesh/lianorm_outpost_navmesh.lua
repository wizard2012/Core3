--[[
  custom_scripts/screenplays/navmesh/lianorm_outpost_navmesh.lua

  THE REBEL OUTPOST IN THE LIANORM SWAMP (B33, decided 2026-09-06 in the
  autonomous run). The sim's Rebel capital on Naboo is `nab_lianorm`, a
  region with no Core3 city: no coordinates, no officer, no battles, and the
  exporter left it out of `regions`, so the sim fought a war over ground the
  game could not show. Rather than move the capital to a real city (a map
  change with a migration and a season restart), the swamp got ground:
  WarReport.COORDS/PLANET_OF/KILL_BOUNDS at the named region's centre
  (-416, 0 -- solid at z 18.8; the swamp's water lies lower), an officer post
  in war_officer.lua, a mapped bridge/region_map.lua entry (screenplay name =
  this file's global, so WarBridge.reskinRegion finds a table and does
  nothing), and this navmesh. Battles, the garrison spread, pins, the
  presence area and the courier board all key on the coordinates and follow.

  WHY A NAVMESH. isPointWalkable() was false at every probed point in the
  swamp (measured 2026-09-06: -416,0 z 18.8; -600,-200 z 33; -200,-300 z 22),
  because no navmesh tile exists there; without one AiAgent::findNextPosition
  fails silently and forever, which is exactly the Anchorhead west-outpost
  bug navmesh/anchorhead_outpost_navmesh.lua fixed. Same pattern, same
  reasoning: an UNGUARDED createNavMesh in start() -- the NavArea is created
  with persistenceLevel 0, is transient, and must be recreated every boot
  (read that file's header before adding any guard here).

  Restart bucket: start() runs from DirectorManager::startGlobalScreenPlays
  at boot. A reload does not re-run it.
]]

WarLianormOutpost = ScreenPlay:new {
	screenplayName = "WarLianormOutpost",
	planet = "naboo",
	centerX = -416,
	centerY = 0,
	radius = 420,          -- covers the 2-3 battle sites at ~80-100 m and the 300 m kill radius
	meshName = "swgwar_lianorm_outpost",
}

registerScreenPlay("WarLianormOutpost", true)

function WarLianormOutpost:start()
	if (not isZoneEnabled(self.planet)) then
		return
	end

	createNavMesh(self.planet, self.centerX, self.centerY, self.radius, true, self.meshName)
end
