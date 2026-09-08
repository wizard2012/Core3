-- E1 (SWGWar B61): a hover fighter -- the swoop's flight model in a TIE fighter hull.
-- Client template in swgwar_e1.tre. See docs/DESIGN-SPACE.md section 6.
object_mobile_vehicle_war_tie = object_mobile_vehicle_shared_war_tie:new {
	templateType = VEHICLE,
	decayRate = 35, -- Damage tick per decay cycle
	decayCycle = 600 -- Time in seconds per cycle
}

ObjectTemplates:addTemplate(object_mobile_vehicle_war_tie, "object/mobile/vehicle/war_tie.iff")
