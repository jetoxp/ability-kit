--[[
	Heal — support, with the longest cast in the catalog.
	A 1.2s cast is what makes interruption (Config.CAST.cancelOnDamage) a real mechanic rather
	than a line of code nobody ever hits. It is here as much to exercise that path as to heal.
]]
return {
	id = "HEAL",
	displayName = "Heal",
	description = "Mends the caster's wounds. Takes a moment to take hold.",
	cost = { mana = 40 },
	cooldown = 8,
	castTime = 1.2,
	targeting = "self",
	range = 0,
	effects = {
		{ kind = "heal", amount = 45 },
	},
}
