--This setting determines if apprenticeship points are awarded for a player teaching another player a skill.
apprenticeshipEnabled = 1

--Multiplier applied to every skill box's XP cost at boot (SkillManager::loadClientData).
--This server runs for a small private group (about six players), not the thousands a
--stock skill tree is priced for grinding together, so costs are halved to keep solo
--and small-group play viable. 1.0 restores stock (unmodified upstream) XP costs. A
--missing or non-positive value here is treated as 1.0 -- it must never silently zero
--out or halve costs by accident.
xpCostMultiplier = 0.5

--Every player gets outdoors_squadleader_novice for free at character creation (see
--forceAwardSkill onboarding). The owner's rule: these 18 boxes must not count against
--the 250-point skill cap, but must still cost real XP and still require the tree's own
--internal prerequisites (movement_02 needs movement_01, etc -- those are untouched by
--this list, it is only about the point cost).
--
--Applied at load time in SkillManager::loadClientData() via Skill::setSkillPointsRequired,
--not as a special case in the award/surrender point-check -- so the 250-point
--reconciliation that runs on every skill event never disagrees with what was charged.
--
--This is an EXACT name list, not a prefix match, so the exemption's scope stays reviewable
--in one place and can't silently widen if a future skill is named similarly. A missing or
--malformed table here exempts nothing (fails toward stock behaviour), matching the
--xpCostMultiplier safe-default discipline above.
squadLeaderZeroPointSkills = {
	"outdoors_squadleader_novice",
	"outdoors_squadleader_master",
	"outdoors_squadleader_movement_01",
	"outdoors_squadleader_movement_02",
	"outdoors_squadleader_movement_03",
	"outdoors_squadleader_movement_04",
	"outdoors_squadleader_offense_01",
	"outdoors_squadleader_offense_02",
	"outdoors_squadleader_offense_03",
	"outdoors_squadleader_offense_04",
	"outdoors_squadleader_defense_01",
	"outdoors_squadleader_defense_02",
	"outdoors_squadleader_defense_03",
	"outdoors_squadleader_defense_04",
	"outdoors_squadleader_support_01",
	"outdoors_squadleader_support_02",
	"outdoors_squadleader_support_03",
	"outdoors_squadleader_support_04",
}