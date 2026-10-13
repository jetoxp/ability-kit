--[[
	init.luau — the ability catalog.

	Thin on purpose. Everything that can be tested lives in AbilityDefinition.buildCatalog; what
	is left here is only the part that cannot be, because it needs Roblox: the requires.

	The Config line is not decoration. validate() reports "init was never called" for every
	definition when no config has been injected, and this file validates while it loads — that is,
	before any other module has had the chance to call init. Without it every definition fails,
	buildCatalog returns nil, and the game refuses to start over a config that was simply never
	handed over. That was the bug: the framework made the config injectable, and then the one
	place that validates at load time never injected it.
]]
local AbilityDefinition = require(script.Parent.AbilityDefinition)
local Config = require(script.Parent.Config)
local EffectSystem = require(script.Parent.EffectSystem)

local definitions = {
	require(script.Fireball),
	require(script.Poison),
	require(script.Dash),
	require(script.Heal),
}

-- Must run before validation. The second argument is nil on purpose: the catalog is what we are
-- about to build, and passing a previous one would hide a stale table behind a fresh one.
AbilityDefinition.init(Config, nil, EffectSystem)

local catalog, errors, warnings = AbilityDefinition.buildCatalog(definitions)
for _, message in ipairs(warnings) do
	warn(string.format("[ability-kit] %s", message))
end
if catalog == nil then
	-- Refusing to start is the point: every later phase reads this table, so one wrong entry
	-- here surfaces much later as a mysterious bug three modules away from its cause.
	error(
		string.format(
			"[ability-kit] the ability catalog is invalid, refusing to start:\n  %s",
			table.concat(errors, "\n  ")
		),
		0
	)
end

-- Register it, so get(id) answers from the moment this module is required.
AbilityDefinition.init(Config, catalog, EffectSystem)

return catalog
