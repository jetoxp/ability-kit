--[[
	DefaultLoadout.luau — which ability sits on which slot, by default.

	Kept separate from the definitions on purpose: a definition should not know what key you
	bound it to. Phase 8 replaces this table with whatever the inventory says is equipped, and
	because the manager reads a loadout rather than a keyboard, that phase is a swap.
]]
return {
	[1] = "FIREBALL",
	[2] = "POISON",
	[3] = "DASH",
	[4] = "HEAL",
}
