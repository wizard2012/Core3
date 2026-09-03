--[[
  custom_scripts/loot/serverobjects.lua

  Bazaar stocking (stage S2, see docs/DECISIONS.md) -- override point for
  vanilla resource_container_* loot item templates. loot/serverobjects.lua
  includeFile()s this file LAST ("Custom content - Loads last to allow for
  overrides"), so every addLootItemTemplate() call below replaces the
  vanilla entry of the same name in LootGroupMap's itemTemplates table
  (LootGroupMap::putLootItemTemplate is a plain HashTable::put, last write
  wins -- confirmed by reading LootGroupMap.cpp/.h).

  WHY THE NAMES MUST STAY "resource_container_<type>" (verified, not the
  bazaar_resource_* naming this stage's brief originally suggested)
  -----------------------------------------------------------------------
  LootManagerImplementation::createLootResource (LootManagerImplementation.cpp:512)
  does:
      String resourceTypeName = resourceDataName.replaceAll("resource_container_", "");
  and then matches currently-spawned ResourceSpawns via resourceEntry->isType(resourceTypeName).
  A loot item template registered under any other name (e.g. "bazaar_resource_metal")
  would leave resourceTypeName unstripped, never match a real spawned resource type,
  and createLootResource would silently return nullptr for every roll. The ONLY way
  to get bigger crates of a real, currently-spawned resource type is to override the
  vanilla entry under its EXISTING name, which is exactly what this file's own header
  comment ("Loads last to allow for overrides") already anticipates.

  SIDE EFFECT TO FLAG: this override is global. Anything else in the game that rolls
  loot item "resource_container_metal" (or any of the other 12 below) -- e.g. mob loot
  tables -- gets the new, larger quantity band too, not just bazaar_stock.lua's own
  crates. Reviewed and accepted as in-scope for this stage; flagged here and in the S2
  report for visibility.

  EXPECTED BOOT-LOG NOISE: addLootItemTemplate() warns when the template name doesn't
  match the including file's own name ("Loot item template name: X does not match file
  name: serverobjects"). All 13 entries below trigger it. Harmless -- same class of
  warning the vanilla loader would already emit for any multi-template file -- but
  worth knowing so it isn't mistaken for a new problem after this change ships.

  QUANTITY BANDS
  --------------
  Vanilla is a flat {5,50} for all 13 siblings -- unusable for real crafting, which
  consumes hundreds of units per batch (see bazaar_stock.lua's file header for the
  full hazard writeup on WHY these are needed and how a ghost/offline seller's crate
  actually gets created despite the zone requirement below).
    - "bulk" structural/industrial materials (what a freight depot plausibly moves in
      quantity): metal, ore, water, wood, chemical, gemstone, hide -> {300,900}
    - "culinary/organic" materials (smaller batch professions -- chef, tailor trims):
      bone, bone_horn, cereal, meat, milk, seeds -> {150,450}
  Both bands are still a flat multiplier of vanilla's ratio (roughly 6-18x), not a
  new distribution shape, and both keep min < max with the same {name,min,max,precision,
  isInteger} shape the vanilla files use.

  NOTE: isRandomResource (LootItemTemplate.h:83) is computed purely from
  directObjectTemplate == "object/resource_container/simple.iff" -- every entry below
  keeps that exact string so LootManagerImplementation::createLoot's isRandomResourceContainer()
  branch (and therefore the container->getZone() requirement bazaar_stock.lua's staging
  container works around) still applies.
]]

local function bulkResource(name)
	local tbl = {
		minimumLevel = 0,
		maximumLevel = 0,
		customObjectName = "",
		directObjectTemplate = "object/resource_container/simple.iff",
		craftingValues = {
			{"quantity", 300, 900, 0, true},
		},
		customizationStringNames = {},
		customizationValues = {}
	}
	addLootItemTemplate(name, tbl)
end

local function organicResource(name)
	local tbl = {
		minimumLevel = 0,
		maximumLevel = 0,
		customObjectName = "",
		directObjectTemplate = "object/resource_container/simple.iff",
		craftingValues = {
			{"quantity", 150, 450, 0, true},
		},
		customizationStringNames = {},
		customizationValues = {}
	}
	addLootItemTemplate(name, tbl)
end

bulkResource("resource_container_metal")
bulkResource("resource_container_ore")
bulkResource("resource_container_chemical")
bulkResource("resource_container_water")
bulkResource("resource_container_wood")
bulkResource("resource_container_gemstone")
bulkResource("resource_container_hide")

organicResource("resource_container_bone")
organicResource("resource_container_bone_horn")
organicResource("resource_container_cereal")
organicResource("resource_container_meat")
organicResource("resource_container_milk")
organicResource("resource_container_seeds")
