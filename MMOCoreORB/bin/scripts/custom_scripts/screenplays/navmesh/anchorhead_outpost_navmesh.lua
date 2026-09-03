--[[
  custom_scripts/screenplays/navmesh/anchorhead_outpost_navmesh.lua

  WHY THIS EXISTS
  ---------------
  A navmesh-backed walkability audit (Tests.isPointWalkable /
  spawn_safety_probe.lua) found that Anchorhead on Tatooine has a western
  outpost -- the npc_6 / r3_1 patrolPoints and stationaryMobiles clusters in
  screenplays/cities/tatooine_anchorhead.lua, roughly 210-330m west of
  Anchorhead's town centre (102, -5360) at a different elevation -- with NO
  navmesh tile covering it at all (dist=-1.000, i.e. no navmesh anywhere near
  those points). AiAgentImplementation::findNextPosition returns false
  silently and permanently when pathing fails, so the ten patrol-route NPCs
  there (npc_6[1..5], r3_1[1..5]) are frozen in place forever. The six
  stationaryMobiles in the same cluster never path, so they're unaffected,
  but are comfortably inside the same mesh anyway.

  Owner's decision: extend the navmesh to cover the outpost (do not touch
  tatooine_anchorhead.lua's coordinate tables -- they're fine, the missing
  mesh is the bug).

  THE GUARD: WHY THIS ISN'T A NAIVE ScreenPlay:start() CALL
  ------------------------------------------------------------
  createNavMesh() (DirectorManager::createNavMesh) always creates a brand
  NEW persistent NavArea row (object/region_navmesh.iff, objectdb
  "navareas") -- there is no dedup-by-name in the C++, and the in-memory
  PlanetManager navMeshAreas map it registers into (addNavArea) is rebuilt
  from scratch every boot, so it can't detect "already created" across a
  restart either. Every actual Lua call site (safety_measures.lua's three
  spawnBrigandCamp*() calls, coa3Screenplay.lua's two mission meshes) is
  UNGUARDED against this: safety_measures.lua's three createNavMesh calls
  run from ScreenPlay:start(), which DirectorManager::startGlobalScreenPlays
  calls unconditionally on every single server boot with no persisted
  "already started" check (confirmed by reading that function -- it just
  iterates every registered screenplay with start=true and calls start()).
  For safety_measures.lua that isn't safe from creating a new persistent
  NavArea row on every restart -- it just happens not to matter for stock
  content that isn't going to run through hundreds of restarts.
  coa3Screenplay.lua's calls are per-player mission instances (one mesh per
  player mission run, not boot-time), a different situation entirely.

  For content meant to persist across every restart of an actual running
  server (this one), copying that unguarded pattern verbatim would stack a
  duplicate NavArea row in navareas.db on every restart forever. So this
  file adds its own guard using the SAME persistent primitive
  safety_measures.lua already uses elsewhere in itself (writeData/readData,
  screenplay.lua's wrapper over DirectorManager's persistent shared-memory
  store -- NOT registerScreenPlay's in-memory screenPlays map, which does
  NOT survive a restart): check a shared-memory flag before calling
  createNavMesh, and set it right after. That makes the call idempotent
  across restarts even though the underlying primitive is not.

  CENTRE / RADIUS
  ---------------
  All 16 points (x, y) from tatooine_anchorhead.lua's npc_6, r3_1 and
  stationaryMobiles[4..9] tables:
    npc_6:   (-144,-5301) (-136,-5313) (-113,-5309) (-124,-5323) (-132,-5302)
    r3_1:    (-180,-5314) (-184,-5306) (-179,-5298) (-231,-5295) (-201,-5305)
    station: (-108.40,-5298.05) (-162.75,-5312.84) (-143.91,-5335.05)
             (and near-duplicates of these three, per the task brief)

  min x = -231, max x = -108.40  -> midpoint x = -169.70
  min y = -5335.05, max y = -5295 -> midpoint y = -5315.03

  Rounded centre: x = -170, y = -5315.

  Farthest listed point from that centre is r3_1[4] (-231, -5295):
    dx = -231 - (-170) = -61, dy = -5295 - (-5315) = 20
    dist = sqrt(61^2 + 20^2) = sqrt(3721 + 400) = sqrt(4121) ~= 64.2

  Next-farthest is the stationary point (-108.40, -5298.05): dist ~= 63.9.
  Every other point is well inside 60. Radius 80 clears the farthest point
  by ~16m (~25% margin) without ballooning the mesh -- safety_measures.lua's
  camp meshes use 64 for a similarly-sized single-camp footprint; this
  cluster spans a wider area (~330m x extent from patrol point to patrol
  point end-to-end) but the actual centre-to-point distances top out at
  ~64, so 80 is comfortably sufficient rather than needlessly huge.

  NAME
  ----
  "swgwar_anchorhead_outpost" -- createNavMesh prefixes this with
  "screenplay_<zoneName>_", so the persisted NavArea/PlanetManager key ends
  up "screenplay_tatooine_swgwar_anchorhead_outpost", clearly identifying it
  as this project's addition and not stock content.

  `dynamic` ARGUMENT
  ------------------
  Read from the source (NavArea.idl / DirectorManager::createNavMesh):
  dynamic=true means disableMeshUpdates(false) -- the navmesh keeps
  reacting to notifyEnter/notifyExit (e.g. a player later placing a
  structure in the area), so the mesh can be recomputed if the terrain's
  walkable set changes at runtime. dynamic=false (disableMeshUpdates(true))
  is what CityRegion uses for player-city meshes, which are static and
  rebuilt through a completely different, explicit path (city hall
  placement / PlanetManagerImplementation) rather than via notify events.
  This outpost is open desert outside Anchorhead's city limits where a
  player could plant a house after this mesh is built, and every existing
  screenplay call site (safety_measures.lua x3, coa3Screenplay.lua x2) uses
  dynamic=true with no counterexample in the codebase -- so this follows
  that same convention: dynamic = true.

  WHEN THE ACTUAL BUILD RUNS (boot-stall check)
  ----------------------------------------------
  DirectorManager::createNavMesh() only creates the NavArea object and
  lua_pushlightuserdata's it back synchronously; the actual heavy work
  (navArea->initializeNavArea(), which does the recast tile build) is
  wrapped in Core::getTaskManager()->scheduleTask(..., 1000) -- i.e. it
  runs ~1s later on a TaskManager thread, not inline on the thread that
  called createNavMesh(), and not inline in ScreenPlay:start(). So this
  does not block zone boot; it costs a short burst of CPU on a background
  task thread shortly after the screenplay starts.

  WHAT I COULD NOT VERIFY WITHOUT A RUNNING SERVER
  -------------------------------------------------
  - That the built mesh actually now reports isPointWalkable()/dist>=0 for
    all sixteen points (task explicitly says not to claim this).
  - Actual recast build time/cost for this radius on this terrain.
  - Whether any part of this footprint overlaps Anchorhead's own city
    navmesh/city-limit area such that this mesh is partially redundant with
    one already covering part of it (the audit's dist=-1 result across the
    whole cluster suggests no overlap exists at all today).
]]--

AnchorheadOutpostNavmesh = ScreenPlay:new {
	numberOfActs = 1,
	screenplayName = "AnchorheadOutpostNavmesh",

	planet = "tatooine",
	centerX = -170,
	centerY = -5315,
	radius = 80,
	meshName = "swgwar_anchorhead_outpost",

	createdFlagKey = "AnchorheadOutpostNavmesh:created",
}

registerScreenPlay("AnchorheadOutpostNavmesh", true)

function AnchorheadOutpostNavmesh:start()
	if (not isZoneEnabled(self.planet)) then
		return
	end

	-- Idempotency guard: createNavMesh() always creates a brand new
	-- persistent NavArea row with no dedup of its own, and start() runs on
	-- every server boot (see file header). Without this check, every
	-- restart would stack another duplicate mesh in navareas.db.
	if (readData(self.createdFlagKey) ~= 0) then
		return
	end

	createNavMesh(self.planet, self.centerX, self.centerY, self.radius, true, self.meshName)

	writeData(self.createdFlagKey, 1)
end
