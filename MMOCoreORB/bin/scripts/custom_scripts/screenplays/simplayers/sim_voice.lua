--[[
  custom_scripts/screenplays/simplayers/sim_voice.lua

  Everything a SimPlayer says, in one place, in-universe (the owner's rule:
  no "ticks", no "contest", no "points"). Every function returns a plain
  string; sim_players.lua decides when to say it. Lines are picked by a
  stable hash of (who, what, when-bucket) so the same character does not
  repeat itself twice in a row and two characters do not chorus.
]]

SimVoice = SimVoice or {}

local FACTION_WORD = { rebel = "the Alliance", imperial = "the Empire" }
local SIDE_WORD    = { rebel = "Rebel", imperial = "Imperial" }
local ENEMY_WORD   = { rebel = "the Imperials", imperial = "the rebels" }

local function pick(list, salt)
	if list == nil or #list == 0 then
		return ""
	end
	local h = 7
	local s = tostring(salt or "")
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 1000003
	end
	return list[(h % #list) + 1]
end

local function fill(line, ctx)
	return (string.gsub(line, "{(%w+)}", function(k)
		local v = ctx[k]
		if v == nil then
			return "{" .. k .. "}"
		end
		return tostring(v)
	end))
end

function SimVoice.context(sim, extra)
	local ctx = {
		name    = sim.name,
		faction = FACTION_WORD[sim.faction] or sim.faction,
		side    = SIDE_WORD[sim.faction] or sim.faction,
		enemy   = ENEMY_WORD[sim.faction] or "the enemy",
	}
	if extra ~= nil then
		for k, v in pairs(extra) do
			ctx[k] = v
		end
	end
	return ctx
end

-- --------------------------------------------------------------- greet ----
-- Resting in a cantina or on the pad, a player walks up.
SimVoice.GREET = {
	brawler  = {
		"You look like you can hold a rifle. {front} is where the real fighting is.",
		"Sat down for one drink. One. Then it's back to {front}.",
		"If you're here for the war, you're in the wrong town. It's at {front}.",
	},
	grinder  = {
		"Another shift at the front tomorrow. Same as today. Same as yesterday.",
		"They keep sending {enemy} and we keep sending them back. Job's a job.",
		"Rest while you can. {front} doesn't get quieter.",
	},
	defender = {
		"{hold} is ours and it stays ours. That's the whole plan.",
		"Everyone wants to attack. Somebody has to keep the lights on at {hold}.",
		"I don't chase fights. I wait for them at {hold}.",
	},
	runner   = {
		"Crates don't move themselves. {thin} is running low again.",
		"Ask the quartermaster for a crate. Walk it to {thin}. That's a good day's work.",
		"Supply wins wars. Nobody sings about it, but it does.",
	},
	scout    = {
		"Just in from {last}. Quiet there, for now.",
		"I've been everywhere on this map this week. {front} is the one to watch.",
		"You hear things on the shuttle. Most of it about {front}.",
	},
	homebody = {
		"Born here, fighting here. I don't need a shuttle to find a war.",
		"This is my town. {side} colours on it, and they're staying.",
		"You want the front, take the shuttle. You want a drink, sit.",
	},
}

function SimVoice.greet(sim, ctx, salt)
	local pool = SimVoice.GREET[sim.style] or SimVoice.GREET.grinder
	return fill(pick(pool, sim.id .. ":greet:" .. tostring(salt)), SimVoice.context(sim, ctx))
end

-- ------------------------------------------------------------- leaving ----
-- About to ship out to a front. Doubles as the invitation.
SimVoice.LEAVING = {
	"Shipping out to {dest}. Come with me if you're up for it.",
	"That's my shuttle. {dest} needs bodies -- yours would do.",
	"{dest}. Now. Walk with me or don't, but I'm going.",
	"I'm for {dest}. If you're {side}, you know where to find me.",
}

function SimVoice.leaving(sim, ctx, salt)
	return fill(pick(SimVoice.LEAVING, sim.id .. ":leave:" .. tostring(salt)), SimVoice.context(sim, ctx))
end

-- -------------------------------------------------------------- arrive ----
SimVoice.ARRIVE_FIGHT = {
	"{name} reporting at {dest}. Where do you want me?",
	"Made it to {dest}. Let's see what {enemy} brought.",
	"{dest}. Good. I was getting bored.",
}

function SimVoice.arriveFight(sim, ctx, salt)
	return fill(pick(SimVoice.ARRIVE_FIGHT, sim.id .. ":arrive:" .. tostring(salt)), SimVoice.context(sim, ctx))
end

-- -------------------------------------------------------------- cloned ----
SimVoice.DELIVERED = {
	"Crates for {dest}. Signed, sealed, and nobody shot me on the way. Today.",
	"{dest} eats tonight. One run, one crate -- it adds up.",
	"Supply run done. If {enemy} wants {dest} they can come and take it.",
	"That's the crate for {dest} handed in. The road was quiet. Too quiet.",
}

function SimVoice.delivered(sim, ctx, salt)
	return fill(pick(SimVoice.DELIVERED, sim.id .. ":deliver:" .. tostring(salt)), SimVoice.context(sim, ctx))
end

SimVoice.CLONED = {
	"Woke up in a clone tank at {dest}. Again. It never gets better.",
	"Back from the dead, courtesy of the clinic at {dest}. Who got me?",
	"{dest} clone bay. My gear's fine. My pride isn't.",
}

function SimVoice.cloned(sim, ctx, salt)
	return fill(pick(SimVoice.CLONED, sim.id .. ":clone:" .. tostring(salt)), SimVoice.context(sim, ctx))
end

-- ------------------------------------------------------------ promoted ----
-- Galaxy-wide, once per rank, so it is worth reading.
function SimVoice.promoted(sim, ctx)
	return fill("{side} Command has promoted {name} to {rank} for service at {where}.", SimVoice.context(sim, ctx))
end

-- ------------------------------------------------------------- escort -----
function SimVoice.escortAccept(sim, ctx)
	return fill(pick({
		"Right behind you. Try not to get me killed.",
		"Lead on. I've followed worse.",
		"Fine. But I'm not carrying you.",
	}, sim.id .. ":accept"), SimVoice.context(sim, ctx))
end

function SimVoice.escortRefuse(sim, ctx)
	return fill("You're not {side}. I don't take orders from the other side.", SimVoice.context(sim, ctx))
end

function SimVoice.escortDismiss(sim, ctx)
	return fill(pick({
		"Suit yourself. I'll find my own war.",
		"See you at the front, then.",
		"Understood. Don't die.",
	}, sim.id .. ":dismiss"), SimVoice.context(sim, ctx))
end

function SimVoice.escortLost(sim, ctx)
	return fill("Lost you. I'm heading back to it on my own.", SimVoice.context(sim, ctx))
end

-- ---------------------------------------------------------------- ask ------
-- "Ask about the war": one line of status, one of opinion.
function SimVoice.askWar(sim, ctx)
	local c = SimVoice.context(sim, ctx)
	local status
	if c.front ~= nil and c.front ~= "" then
		status = fill("The fight is at {front}. ", c)
	else
		status = "Quiet everywhere, and I don't trust it. "
	end
	local supply = ""
	if c.here_supply == "cut" then
		supply = fill("And nothing is getting through to {here} -- the supply line is cut. ", c)
	elseif c.here_supply == "degraded" then
		supply = fill("Supply to {here} is thin; somebody should run crates. ", c)
	end
	return status .. supply .. fill(pick({
		"I'm {rank}, for what that's worth.",
		"I've been at this since before you got here.",
		"Ask me again tomorrow; it'll be different.",
	}, sim.id .. ":ask:" .. tostring(c.salt)), c)
end

-- "Where are you headed?"
function SimVoice.where(sim, ctx)
	local c = SimVoice.context(sim, ctx)
	if c.state == "fight" then
		return fill("I'm not headed anywhere. I'm at {here}, and so is the war.", c)
	elseif c.state == "escort" then
		return "Wherever you are. That was the deal."
	elseif c.dest ~= nil and c.dest ~= "" then
		return fill("{dest}, next shuttle. Come along.", c)
	end
	return fill("Nowhere yet. Resting at {here} until something happens.", c)
end
