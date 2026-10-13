--[[
	Fireball — instant damage at range.
	The simplest shape in the framework, and deliberately first: it proves the pipeline
	(intent -> validation -> effect) without any of the timing machinery a DoT needs.
]]
return {
	id = "FIREBALL",
	displayName = "Fireball",
	description = "Hurls a bolt of fire that burns a single target.",
	cost = { mana = 25 },
	cooldown = 3,
	castTime = 0.4,
	targeting = "raycast",
	range = 60,
	effects = {
		{ kind = "damage", amount = 45, radius = 0 },
	},
}
