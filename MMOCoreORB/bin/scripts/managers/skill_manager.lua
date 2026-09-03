--This setting determines if apprenticeship points are awarded for a player teaching another player a skill.
apprenticeshipEnabled = 1

--Multiplier applied to every skill box's XP cost at boot (SkillManager::loadClientData).
--REVERTED to 1.0 (stock). This server runs for a small private group, not the
--thousands a stock skill tree is priced for, but the fix for that now lives in
--bin/scripts/managers/player_manager.lua's globalExpMultiplier (set to 2.0) instead of
--here. Reasoning: this project cannot ship modified client data, and the profession
--screen's progress bar is rendered by the CLIENT from its own bundled skills.iff, which
--still shows the STOCK cost. Halving cost here made the server accept a purchase at
--half of what the client's own bar displayed as required -- a permanent, visible,
--uncorrectable mismatch. Doubling the RATE a player earns XP instead leaves this number
--alone (client and server agree, both stock) and simply fills the bar's numerator (the
--player's live XP total, which the server DOES send to the client) twice as fast.
--Mathematically equivalent in time-to-train (skill training spends XP in full, so
--cost/rate is the same either way) but without the display bug. A missing or
--non-positive value here is treated as 1.0 -- it must never silently zero out or halve
--costs by accident.
xpCostMultiplier = 1.0

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