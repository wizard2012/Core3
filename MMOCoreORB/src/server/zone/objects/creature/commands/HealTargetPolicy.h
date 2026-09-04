/*
 * HealTargetPolicy.h
 *
 * ONE home for "does this heal apply to the target, or fall back to the healer".
 *
 * WHY THIS FILE EXISTS. Upstream repeats the same target-rejection expression
 * verbatim in five unrelated commands -- HealDamageCommand, HealWoundCommand,
 * FirstAidCommand, HealStateCommand and TendCommand (the base for TendDamage
 * and TendWound). This project has been bitten repeatedly by two copies of one
 * truth drifting apart (see the 2026-09-04 handoff in docs/BACKLOG.md), so the
 * predicate is defined once here and included, not edited in five places.
 *
 * WHAT CHANGED FROM UPSTREAM, AND WHAT DELIBERATELY DID NOT.
 *
 * Changed: upstream redirected for EVERY non-pet AiAgent, so a faction-aligned
 * player could not heal the NPCs fighting on their own side -- including the
 * GCW troopers war_battle.lua stages, which its own header calls "ordinary
 * faction NPCs". A same-faction NPC now receives the heal.
 *
 * NOT changed, on purpose: the fallback for everything else stays a silent
 * redirect to the healer rather than becoming an error. That redirect looks
 * like a bug and is not one -- "target the enemy you are fighting, press heal,
 * heal yourself" is the ordinary SWG combat idiom, and turning it into a
 * refusal would break the core loop for every player who has ever used it.
 * The only thing being narrowed here is WHICH targets fall into that redirect.
 *
 * FRIENDLY MEANS FACTION-ALIGNED, NOT MERELY NON-HOSTILE. Both sides must
 * carry the SAME NON-ZERO faction. Neutral NPCs are deliberately excluded: the
 * ambient street civilians shipped in PR #21 are faction 0 with pvp bitmask 0
 * on purpose, and making them healable would put a medic XP source on every
 * street corner in all 13 cities. isAttackableBy is consulted first and
 * independently -- it is the authority on hostility (covert/overt, duels,
 * TEFs, personal enemy flags) and a target the healer could attack is never
 * friendly, whatever the faction ids say.
 */

#ifndef HEALTARGETPOLICY_H_
#define HEALTARGETPOLICY_H_

#include "server/zone/objects/creature/CreatureObject.h"

namespace HealTargetPolicy {

/**
 * True when `target` is an NPC fighting on the healer's own side: a non-pet
 * AiAgent sharing the healer's non-zero faction and not attackable by them.
 *
 * Pets are excluded here only because upstream already lets them through by a
 * separate branch; this answers the faction-NPC question alone.
 */
inline bool isFriendlyFactionNpc(CreatureObject* healer, CreatureObject* target) {
	if (healer == nullptr || target == nullptr)
		return false;

	if (!target->isAiAgent() || target->isPet())
		return false;

	if (target->isAttackableBy(healer))
		return false;

	uint32 healerFaction = healer->getFaction();
	uint32 targetFaction = target->getFaction();

	return healerFaction != 0 && healerFaction == targetFaction;
}

/**
 * True when the heal should apply to the HEALER instead of the given target.
 *
 * This is upstream's original condition with exactly one carve-out: a friendly
 * faction NPC no longer redirects. Every other rejection upstream made for a
 * real reason is preserved -- droids, vehicles, ridden mounts, the dead, and
 * anything the healer could attack (which is what makes the heal-while-
 * targeting-an-enemy idiom keep working).
 *
 * Callers that additionally reject vehicles should keep doing so; FirstAid
 * upstream omits the vehicle test and that difference is left alone.
 */
inline bool shouldRedirectToSelf(CreatureObject* healer, CreatureObject* target) {
	if (healer == nullptr || target == nullptr)
		return true;

	if (isFriendlyFactionNpc(healer, target))
		return false;

	return (target->isAiAgent() && !target->isPet())
		|| target->isDroidObject()
		|| target->isVehicleObject()
		|| target->isDead()
		|| target->isRidingMount()
		|| target->isAttackableBy(healer);
}

} // namespace HealTargetPolicy

#endif /* HEALTARGETPOLICY_H_ */
