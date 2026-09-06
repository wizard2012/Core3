--[[
  custom_scripts/mobile/war/war_troops.lua

  The war's own troops and walkers -- docs/DESIGN-BATTLES.md sections 2 and
  3.1, owner rulings 2026-09-05. War-tuned clones of stock faction templates
  so both sides field the SAME line: the stock Rebel trooper is level 15
  against a level-25 stormtrooper, which biased every fight and, since D27
  prices bodies, the war. Every troop here is level 30 (sergeants 32); the
  five roles differ in weapon, reach and toughness, not in level. The two sides
  are MIRRORS: same resists, no secondary weapon (measured 2026-09-05: with a
  pistol secondary and marksmanmid the Rebels lost every site, both attacking
  and defending; the Imperials had carbine-only lines).

  Walkers are the "heavy a squad can kill" ruling: an AT-ST at level 45
  with thick armour and a lot of health, not the stock level-125 boss. The
  Rebel one is the same machine, liberated.

  Every troop and walker carries FACTIONAGGRO (measured 2026-09-05): the stock
  Rebel trooper has it and the stock stormtrooper does not, so in every fight
  before these templates the Rebels opened fire and the Imperials retaliated;
  clones without it stood in combat state with nobody shooting.

  Boot-loaded (mobile/ is the restart bucket, CLAUDE.md), included at the end of
  mobile/creatures.lua, after creatureskills.lua (the attack tables must exist).
]]

-- ------------------------------------------------------------ imperial --

war_imperial_rifleman = Creature:new {
	objectName = "@mob/creature_names:stormtrooper",
	randomNameType = NAME_STORMTROOPER,
	socialGroup = "imperial",
	mobType = MOB_NPC,
	faction = "imperial",
	level = 30,
	chanceHit = 0.40,
	damageMin = 260,
	damageMax = 285,
	baseXp = 3000,
	baseHAM = 8200,
	baseHAMmax = 9800,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	scale = 1.05,
	templates = {"object/mobile/dressed_stormtrooper_m.iff"},
	lootGroups = { { groups = { {group = "imperial_stormtrooper_tier_1", chance = 10000000} } } },
	primaryWeapon = "stormtrooper_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/stormtrooper",
	personalityStf = "@hireling/hireling_stormtrooper",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_imperial_rifleman, "war_imperial_rifleman")

war_imperial_sergeant = Creature:new {
	objectName = "@mob/creature_names:stormtrooper_squad_leader",
	randomNameType = NAME_STORMTROOPER,
	socialGroup = "imperial",
	mobType = MOB_NPC,
	faction = "imperial",
	level = 32,
	chanceHit = 0.44,
	damageMin = 270,
	damageMax = 300,
	baseXp = 3400,
	baseHAM = 9600,
	baseHAMmax = 11200,
	armor = 0,
	resists = {20,20,45,20,20,20,20,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	scale = 1.05,
	templates = {
		"object/mobile/dressed_stormtrooper_squad_leader_white_white.iff",
	},
	lootGroups = { { groups = { {group = "imperial_stormtrooper_tier_1", chance = 10000000} } } },
	primaryWeapon = "stormtrooper_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/stormtrooper",
	personalityStf = "@hireling/hireling_stormtrooper",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_imperial_sergeant, "war_imperial_sergeant")

war_imperial_medic = Creature:new {
	objectName = "@mob/creature_names:stormtrooper_medic",
	randomNameType = NAME_STORMTROOPER,
	socialGroup = "imperial",
	mobType = MOB_NPC,
	faction = "imperial",
	level = 30,
	chanceHit = 0.36,
	damageMin = 230,
	damageMax = 250,
	baseXp = 3000,
	baseHAM = 8200,
	baseHAMmax = 9800,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	scale = 1.05,
	templates = {
		"object/mobile/dressed_stormtrooper_medic_m.iff",
	},
	lootGroups = { { groups = { {group = "imperial_stormtrooper_tier_1", chance = 10000000} } } },
	primaryWeapon = "stormtrooper_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/stormtrooper",
	personalityStf = "@hireling/hireling_stormtrooper",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_imperial_medic, "war_imperial_medic")

war_imperial_marksman = Creature:new {
	objectName = "@mob/creature_names:stormtrooper_sniper",
	randomNameType = NAME_STORMTROOPER,
	socialGroup = "imperial",
	mobType = MOB_NPC,
	faction = "imperial",
	level = 30,
	chanceHit = 0.48,
	damageMin = 300,
	damageMax = 340,
	baseXp = 3000,
	baseHAM = 7000,
	baseHAMmax = 8400,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	scale = 1.05,
	templates = {
		"object/mobile/dressed_stormtrooper_sniper_m.iff",
	},
	lootGroups = { { groups = { {group = "imperial_stormtrooper_tier_1", chance = 10000000} } } },
	primaryWeapon = "stormtrooper_rifle",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/stormtrooper",
	personalityStf = "@hireling/hireling_stormtrooper",
	primaryAttacks = riflemanmaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_imperial_marksman, "war_imperial_marksman")

war_imperial_heavy = Creature:new {
	objectName = "@mob/creature_names:stormtrooper_bombardier",
	randomNameType = NAME_STORMTROOPER,
	socialGroup = "imperial",
	mobType = MOB_NPC,
	faction = "imperial",
	level = 30,
	chanceHit = 0.40,
	damageMin = 320,
	damageMax = 360,
	baseXp = 3000,
	baseHAM = 9400,
	baseHAMmax = 11000,
	armor = 0,
	resists = {25,25,45,25,25,25,25,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	scale = 1.05,
	templates = {
		"object/mobile/dressed_stormtrooper_bombardier_m.iff",
	},
	lootGroups = { { groups = { {group = "imperial_stormtrooper_tier_1", chance = 10000000} } } },
	primaryWeapon = "stormtrooper_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/stormtrooper",
	personalityStf = "@hireling/hireling_stormtrooper",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_imperial_heavy, "war_imperial_heavy")

-- --------------------------------------------------------------- rebel --

war_rebel_rifleman = Creature:new {
	objectName = "@mob/creature_names:rebel_trooper",
	randomNameType = NAME_GENERIC,
	randomNameTag = true,
	mobType = MOB_NPC,
	socialGroup = "rebel",
	faction = "rebel",
	level = 30,
	chanceHit = 0.40,
	damageMin = 260,
	damageMax = 285,
	baseXp = 3000,
	baseHAM = 8200,
	baseHAMmax = 9800,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	templates = {
		"object/mobile/dressed_rebel_trooper_bith_m_01.iff",
		"object/mobile/dressed_rebel_trooper_human_female_01.iff",
		"object/mobile/dressed_rebel_trooper_human_male_01.iff",
		"object/mobile/dressed_rebel_trooper_sullustan_male_01.iff",
		"object/mobile/dressed_rebel_trooper_twk_female_01.iff",
		"object/mobile/dressed_rebel_trooper_twk_male_01.iff"
	},
	lootGroups = { { groups = { {group = "rebel_tier_1", chance = 10000000} } } },
	primaryWeapon = "rebel_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/military",
	personalityStf = "@hireling/hireling_military",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_rebel_rifleman, "war_rebel_rifleman")

war_rebel_sergeant = Creature:new {
	objectName = "@mob/creature_names:rebel_sergeant",
	randomNameType = NAME_GENERIC,
	randomNameTag = true,
	mobType = MOB_NPC,
	socialGroup = "rebel",
	faction = "rebel",
	level = 32,
	chanceHit = 0.44,
	damageMin = 270,
	damageMax = 300,
	baseXp = 3400,
	baseHAM = 9600,
	baseHAMmax = 11200,
	armor = 0,
	resists = {20,20,45,20,20,20,20,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	templates = {
		"object/mobile/dressed_rebel_sergeant_fat_zabrak_male_01.iff",
		"object/mobile/dressed_rebel_sergeant_human_male_01.iff",
		"object/mobile/dressed_rebel_sergeant_moncal_male_01.iff",
		"object/mobile/dressed_rebel_sergeant_rodian_female_01.iff",
		"object/mobile/dressed_rebel_sergeant_rodian_male_01.iff",
		"object/mobile/dressed_rebel_sergeant_twilek_female_old_01.iff",
	},
	lootGroups = { { groups = { {group = "rebel_tier_1", chance = 10000000} } } },
	primaryWeapon = "rebel_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/military",
	personalityStf = "@hireling/hireling_military",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_rebel_sergeant, "war_rebel_sergeant")

war_rebel_medic = Creature:new {
	objectName = "@mob/creature_names:rebel_medic",
	randomNameType = NAME_GENERIC,
	randomNameTag = true,
	mobType = MOB_NPC,
	socialGroup = "rebel",
	faction = "rebel",
	level = 30,
	chanceHit = 0.36,
	damageMin = 230,
	damageMax = 250,
	baseXp = 3000,
	baseHAM = 8200,
	baseHAMmax = 9800,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	templates = {
		"object/mobile/dressed_rebel_medic3_moncal_female_01.iff",
		"object/mobile/dressed_rebel_medic1_bothan_male_01.iff",
	},
	lootGroups = { { groups = { {group = "rebel_tier_1", chance = 10000000} } } },
	primaryWeapon = "rebel_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/military",
	personalityStf = "@hireling/hireling_military",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_rebel_medic, "war_rebel_medic")

war_rebel_marksman = Creature:new {
	objectName = "@mob/creature_names:fbase_rebel_sharpshooter",
	randomNameType = NAME_GENERIC,
	randomNameTag = true,
	mobType = MOB_NPC,
	socialGroup = "rebel",
	faction = "rebel",
	level = 30,
	chanceHit = 0.48,
	damageMin = 300,
	damageMax = 340,
	baseXp = 3000,
	baseHAM = 7000,
	baseHAMmax = 8400,
	armor = 0,
	resists = {15,15,40,15,15,15,15,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	templates = {
		"object/mobile/dressed_rebel_trooper_bith_m_01.iff",
		"object/mobile/dressed_rebel_trooper_human_female_01.iff",
		"object/mobile/dressed_rebel_trooper_human_male_01.iff",
		"object/mobile/dressed_rebel_trooper_sullustan_male_01.iff",
		"object/mobile/dressed_rebel_trooper_twk_female_01.iff",
		"object/mobile/dressed_rebel_trooper_twk_male_01.iff",
	},
	lootGroups = { { groups = { {group = "rebel_tier_1", chance = 10000000} } } },
	primaryWeapon = "rebel_rifle",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/military",
	personalityStf = "@hireling/hireling_military",
	primaryAttacks = riflemanmaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_rebel_marksman, "war_rebel_marksman")

war_rebel_heavy = Creature:new {
	objectName = "@mob/creature_names:fbase_rebel_heavy_trooper",
	randomNameType = NAME_GENERIC,
	randomNameTag = true,
	mobType = MOB_NPC,
	socialGroup = "rebel",
	faction = "rebel",
	level = 30,
	chanceHit = 0.40,
	damageMin = 320,
	damageMax = 360,
	baseXp = 3000,
	baseHAM = 9400,
	baseHAMmax = 11000,
	armor = 0,
	resists = {25,25,45,25,25,25,25,-1,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = HERBIVORE,
	templates = {
		"object/mobile/dressed_rebel_ris_01.iff",
		"object/mobile/dressed_rebel_ris_02.iff",
		"object/mobile/dressed_rebel_ris_03.iff",
		"object/mobile/dressed_rebel_ris_04.iff",
		"object/mobile/dressed_rebel_crewman_human_male_01.iff",
	},
	lootGroups = { { groups = { {group = "rebel_tier_1", chance = 10000000} } } },
	primaryWeapon = "rebel_carbine",
	secondaryWeapon = "none",
	thrownWeapon = "thrown_weapons",
	conversationTemplate = "",
	reactionStf = "@npc_reaction/military",
	personalityStf = "@hireling/hireling_military",
	primaryAttacks = carbineermaster,
	secondaryAttacks = {}
}
CreatureTemplates:addCreatureTemplate(war_rebel_heavy, "war_rebel_heavy")

-- ------------------------------------------------------------- walkers --
-- "A heavy a squad can kill": a full line brings one down in a minute or
-- two; a lone player cannot. Costs its side WALKER_CRATES bodies when it
-- falls (war_battle.lua reports it as such).

war_at_st = Creature:new {
	objectName = "@mob/creature_names:at_st",
	socialGroup = "imperial",
	faction = "imperial",
	mobType = MOB_VEHICLE,
	level = 45,
	chanceHit = 1.2,
	damageMin = 420,
	damageMax = 620,
	baseXp = 6000,
	baseHAM = 26000,
	baseHAMmax = 32000,
	armor = 1,
	resists = {35,35,-1,100,100,15,15,100,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = NONE,
	templates = {"object/mobile/atst.iff"},
	lootGroups = {},
	conversationTemplate = "",
	defaultAttack = "defaultdroidattack",
	defaultWeapon = "object/weapon/ranged/vehicle/vehicle_atst_ranged.iff",
}
CreatureTemplates:addCreatureTemplate(war_at_st, "war_at_st")

war_at_st_liberated = Creature:new {
	objectName = "@mob/creature_names:at_st",
	socialGroup = "rebel",
	faction = "rebel",
	mobType = MOB_VEHICLE,
	level = 45,
	chanceHit = 1.2,
	damageMin = 420,
	damageMax = 620,
	baseXp = 6000,
	baseHAM = 26000,
	baseHAMmax = 32000,
	armor = 1,
	resists = {35,35,-1,100,100,15,15,100,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = NONE,
	templates = {"object/mobile/atst.iff"},
	lootGroups = {},
	conversationTemplate = "",
	defaultAttack = "defaultdroidattack",
	defaultWeapon = "object/weapon/ranged/vehicle/vehicle_atst_ranged.iff",
}
CreatureTemplates:addCreatureTemplate(war_at_st_liberated, "war_at_st_liberated")

war_at_at = Creature:new {
	objectName = "@mob/creature_names:at_at",
	socialGroup = "imperial",
	faction = "imperial",
	mobType = MOB_VEHICLE,
	level = 60,
	chanceHit = 1.6,
	damageMin = 600,
	damageMax = 900,
	baseXp = 12000,
	baseHAM = 70000,
	baseHAMmax = 84000,
	armor = 2,
	resists = {50,50,-1,100,100,25,25,100,-1},
	meatType = "", meatAmount = 0, hideType = "", hideAmount = 0, boneType = "", boneAmount = 0,
	milk = 0, tamingChance = 0, ferocity = 0,
	pvpBitmask = ATTACKABLE,
	creatureBitmask = PACK + KILLER,
	optionsBitmask = AIENABLED + FACTIONAGGRO,
	diet = NONE,
	templates = {"object/mobile/atat.iff"},
	lootGroups = {},
	conversationTemplate = "",
	defaultAttack = "defaultdroidattack",
	-- The AT-ST's gun: no vehicle_atat_ranged template exists server-side
	-- (object/weapon/ranged/vehicle/ has only vehicle_atst_ranged), and the
	-- stock at_at.lua uses this one too. With the missing template spawnMobile
	-- returned nil everywhere -- measured 2026-09-06 at the first siege
	-- (Lianorm): "walker war_at_at did not spawn".
	defaultWeapon = "object/weapon/ranged/vehicle/vehicle_atst_ranged.iff",
}
CreatureTemplates:addCreatureTemplate(war_at_at, "war_at_at")
