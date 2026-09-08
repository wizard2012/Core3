-- E1 (SWGWar B61): the trial deed for the hover fighter. The client sees the
-- swoop deed (shared template reused: no new client file for the deed), the
-- server generates the X-wing hull and parks it in a swoop control device.
object_tangible_deed_vehicle_deed_war_xwing_deed = object_tangible_deed_vehicle_deed_shared_speederbike_swoop_deed:new {

	templateType = VEHICLEDEED,

	controlDeviceObjectTemplate = "object/intangible/vehicle/speederbike_swoop_pcd.iff",
	generatedObjectTemplate = "object/mobile/vehicle/war_xwing.iff",

	numberExperimentalProperties = {1, 1, 1},
	experimentalProperties = {"XX", "XX", "SR"},
	experimentalWeights = {1, 1, 1},
	experimentalGroupTitles = {"null", "null", "exp_durability"},
	experimentalSubGroupTitles = {"null", "null", "hit_points"},
	experimentalMin = {0, 0, 1000},
	experimentalMax = {0, 0, 1000},
	experimentalPrecision = {0, 0, 0},
	experimentalCombineType = {0, 0, 1},
}

ObjectTemplates:addTemplate(object_tangible_deed_vehicle_deed_war_xwing_deed, "object/tangible/deed/vehicle_deed/war_xwing_deed.iff")
