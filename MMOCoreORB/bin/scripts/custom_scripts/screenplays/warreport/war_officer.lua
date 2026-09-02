--[[
  custom_scripts/screenplays/warreport/war_officer.lua

  Surface 2 of 4: a briefing officer standing in each faction capital who
  reports the state of the war when a player walks up to them.

  WHY NOT A CONVERSATION (the important design constraint)
  -------------------------------------------------------
  The obvious build is a ConvoTemplate with menu options, exactly like
  custom_scripts/mobile/population_conversations.lua. It was rejected, and
  the reason is worth recording because it will come up again:

  ConvoScreen's leftDialog and its option labels are resolved through the
  client's .stf string tables -- they are "@file:key" lookups, not text.
  This project cannot ship .stf files (they are TRE/client assets, outside
  the Lua+SQL scope; see population_conversations.lua's own header and
  docs/BACKLOG.md B4). A conversation officer would therefore greet the
  player with the literal string "@war:officer_greet" and offer buttons
  labelled "@war:opt_status". Unreadable.

  spatialChat and sendSystemMessage take PLAIN strings. spatialChat with a
  literal is already shipped in this codebase (bartenders.lua's chatListen),
  and sendSystemMessage with a non-"@" literal has 188 call sites in stock
  scripts, backed by CreatureObjectImplementation.cpp:543 taking a plain
  String. So the officer SPEAKS the headline aloud (everyone nearby sees it,
  which is the atmospheric half) and SENDS the detail privately to the
  player who approached (which is the informational half). No client assets,
  fully readable, and it degrades to silence rather than to garbage.

  WHY PROXIMITY AND NOT A RADIAL: a radial menu entry is also an .stf label.
  Same wall. An active area needs no client-side text at all.

  ANTI-SPAM: a player who walks in and out of the area repeatedly would
  otherwise be briefed every time. Each player is rate-limited by a
  timestamp in screenplay data (REBRIEF_COOLDOWN_MS).

  NOTE ON RELOAD: this file is screenplay-side, so reload-lua.sh covers it.
  It does NOT add any mobile/ template -- the officers reuse stock faction
  NPC templates that already exist, so no restart.sh is required.
]]

WarOfficer = ScreenPlay:new {
	screenplayName = "WarOfficer",

	-- Where a briefing officer stands. Only capitals that are real cities
	-- with coordinates -- nab_lianorm is a REBEL capital in the sim but is
	-- a swamp with no city screenplay, so it gets no officer.
	POSTS = {
		{ region = "cor_coronet",    zone = "corellia", x = -178,  y = -4504, heading = 0 },
		{ region = "nab_theed",      zone = "naboo",    x = -6160, y = 3920,  heading = 0 },
		{ region = "tat_anchorhead", zone = "tatooine", x = 102,   y = -5360, heading = 0 },
	},

	-- Faction-appropriate stock templates. Verified present in the running
	-- server by the warBridgeCheck probe, which listed both of these among
	-- the templates their cities already spawn.
	TEMPLATE = {
		imperial = "imperial_first_lieutenant",
		rebel    = "rebel_army_captain",
	},

	BRIEF_RADIUS_M = 12,
	REBRIEF_COOLDOWN_MS = 5 * 60 * 1000,
}

registerScreenPlay("WarOfficer", true)

function WarOfficer:start()
	if not isZoneEnabled("tatooine") then
		return
	end
	self:spawnAll()
end

function WarOfficer:spawnAll()
	for i = 1, #self.POSTS do
		local ok, err = pcall(function() self:spawnPost(self.POSTS[i]) end)
		if not ok then
			printf("WarOfficer: failed to spawn post " .. tostring(self.POSTS[i].region) .. ": " .. tostring(err) .. "\n")
		end
	end
end

--- Which faction's officer belongs here right now. Reads the SAME war state
-- every other surface reads, so a captured capital gets the captor's officer.
function WarOfficer:factionFor(regionId)
	if WarReport == nil then
		return nil
	end
	local st = WarReport.state()
	if st == nil then
		return nil
	end
	local r = st.regions[regionId]
	if r == nil then
		return nil
	end
	return r.faction
end

function WarOfficer:spawnPost(post)
	if post == nil or not isZoneEnabled(post.zone) then
		return
	end

	local faction = self:factionFor(post.region)
	if faction == nil then
		return -- no war state yet; spawn nothing rather than guess a side
	end

	local template = self.TEMPLATE[faction]
	if template == nil then
		return
	end

	local pNpc = spawnMobile(post.zone, template, -1, post.x, 0, post.y, post.heading, 0)
	if pNpc == nil then
		printf("WarOfficer: spawnMobile returned nil for " .. template .. " at " .. post.region .. "\n")
		return
	end

	AiAgent(pNpc):addObjectFlag(AI_STATIONARY)
	AiAgent(pNpc):setFollowState(0)

	local pArea = spawnActiveArea(post.zone, "object/active_area.iff",
		post.x, 0, post.y, self.BRIEF_RADIUS_M, 0)

	if pArea == nil then
		return
	end

	-- Remember which region this area briefs on, so the handler does not
	-- have to reverse-lookup by coordinates.
	writeStringData(SceneObject(pArea):getObjectID() .. ":war:region", post.region)
	writeData(SceneObject(pArea):getObjectID() .. ":war:npc", SceneObject(pNpc):getObjectID())

	createObserver(ENTEREDAREA, "WarOfficer", "briefEntered", pArea)
end

function WarOfficer:briefEntered(pArea, pPlayer)
	if pPlayer == nil or pArea == nil then
		return 0
	end
	if not SceneObject(pPlayer):isPlayerCreature() then
		return 0
	end

	pcall(function()
		local playerOid = SceneObject(pPlayer):getObjectID()
		local key = playerOid .. ":war:lastBrief"

		local last = readData(key)
		local now = getTimestampMilli()
		if last ~= nil and last > 0 and (now - last) < WarOfficer.REBRIEF_COOLDOWN_MS then
			return -- briefed recently; stay quiet
		end
		writeData(key, now)

		if WarReport == nil or WarReport.state() == nil then
			return
		end

		local areaOid = SceneObject(pArea):getObjectID()
		local regionId = readStringData(areaOid .. ":war:region")

		-- Spoken aloud: the headline. Everyone nearby hears it.
		local npcOid = readData(areaOid .. ":war:npc")
		local pNpc = (npcOid ~= nil and npcOid > 0) and getSceneObject(npcOid) or nil
		local headline = WarReport.headline()

		if pNpc ~= nil and headline ~= nil then
			spatialChat(pNpc, headline)
		end

		-- Sent privately: the detail.
		local creature = CreatureObject(pPlayer)
		local front = WarReport.frontLine()
		if front ~= nil then
			creature:sendSystemMessage(front)
		end

		if regionId ~= nil and regionId ~= "" then
			local planet = WarReport.PLANET_OF[regionId]
			local lines = WarReport.planetLines(planet)
			for i = 1, #lines do
				creature:sendSystemMessage("  " .. lines[i])
			end
		end
	end)

	return 0
end
