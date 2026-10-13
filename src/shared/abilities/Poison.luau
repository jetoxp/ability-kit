--[[
	Poison — damage over time, applied as a debuff.
	This is the ability that stops the framework being a damage-dealer with extra steps: it
	only works if the EffectSystem can hold state on a character across several seconds and
	replicate that state to the client.
]]
return {
	id = "POISON",
	displayName = "Poison",
	description = "Coats the target in toxin. Damage continues after the hit.",
	cost = { mana = 20 },
	cooldown = 6,
	castTime = 0,
	targeting = "raycast",
	range = 40,
	effects = {
		{ kind = "dot", amount = 6, duration = 4, interval = 1 },
	},
}
