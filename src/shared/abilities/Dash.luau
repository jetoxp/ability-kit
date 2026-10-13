--[[
	Dash — server-resolved movement.
	The movement is applied on the server. A client that asks for a dash gets one of a fixed
	length; it cannot ask for a bigger one. That is the whole point of the ability being data:
	there is no code path where a number from the client reaches a CFrame.
]]
return {
	id = "DASH",
	displayName = "Dash",
	description = "Surges forward, closing distance quickly.",
	cost = { stamina = 30 },
	cooldown = 5,
	castTime = 0,
	targeting = "self",
	range = 0,
	effects = {
		{ kind = "dash", distance = 32, duration = 0.25 },
	},
}
