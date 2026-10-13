--[[
	Catalog.luau — the registry the rest of the kit reads from.

	This is one of the very few files allowed to require others, because it exists precisely to
	be the single place where "which abilities exist" is answered. Anywhere else, abilities
	arrive injected. That keeps every other module loadable outside Studio, which is what the
	test suite depends on.
]]
return {
	require(script.Fireball),
	require(script.Poison),
	require(script.Dash),
	require(script.Heal),
}
