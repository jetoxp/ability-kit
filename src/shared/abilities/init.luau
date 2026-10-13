--[[
	init.luau — the ability catalog.

	Two things this file must get right, and both were wrong in review:

	1. The game looks abilities up BY ID. An array is not a lookup table: `catalog["FIREBALL"]`
	   on an array is nil, so every lookup would have missed. This returns a dict keyed by
	   definition.id, which is the key AbilityDefinition.get() reads.

	2. It validates BEFORE indexing. Two entries can share an id inside the array, and building
	   the dict first would let one silently overwrite the other — after which the duplicate is
	   undetectable, because the array that carried the evidence is gone. The check has to run on
	   the array, while both copies still exist.

	Requiring the ability modules is why this file is one of very few allowed to require others.
]]

local AbilityDefinition = require(script.Parent.AbilityDefinition)

local definitions = {
	require(script.Fireball),
	require(script.Poison),
	require(script.Dash),
	require(script.Heal),
}

-- Validation runs on the array, not on the built dict.
local errors, warnings = AbilityDefinition.validateCatalog(definitions)
for _, message in ipairs(warnings) do
	warn(string.format("[ability-kit] %s", message))
end
if #errors > 0 then
	-- Refusing to start is the point. Every later phase reads this table, so one wrong entry
	-- here shows up much later as a mysterious bug three modules away from its cause.
	error(
		string.format(
			"[ability-kit] the ability catalog is invalid, refusing to start:\n  %s",
			table.concat(errors, "\n  ")
		),
		0
	)
end

local catalog = {}
for _, definition in ipairs(definitions) do
	catalog[definition.id] = definition
end

return catalog
