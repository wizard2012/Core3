--This setting determines if apprenticeship points are awarded for a player teaching another player a skill.
apprenticeshipEnabled = 1

--Multiplier applied to every skill box's XP cost at boot (SkillManager::loadClientData).
--This server runs for a small private group (about six players), not the thousands a
--stock skill tree is priced for grinding together, so costs are halved to keep solo
--and small-group play viable. 1.0 restores stock (unmodified upstream) XP costs. A
--missing or non-positive value here is treated as 1.0 -- it must never silently zero
--out or halve costs by accident.
xpCostMultiplier = 0.5