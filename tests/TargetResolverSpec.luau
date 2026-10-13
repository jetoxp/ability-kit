--[[
	TargetResolverSpec.luau — runs with `luau tests/TargetResolverSpec.luau`. No Studio.

	Every case in the selection rules, in plain tables. This is the payoff of the detection/selection
	split: nothing here knows what a Character is.
]]

local TestKit = require("./TestKit")
local TargetResolver = require("../src/shared/TargetResolver")

local T = TestKit.new("TargetResolver")

-- An origin at zero facing +x, so "in front" and "behind" are signed numbers a reader can check.
local ORIGIN = { x = 0, y = 0, z = 0 }
local FORWARD = { x = 1, y = 0, z = 0 }

local function unit(x, alive)
	return { id = "u" .. tostring(x), alive = alive ~= false, position = { x = x, y = 0, z = 0 } }
end

T("the vocabulary is exactly self and raycast", function()
	-- `nearest` is absent on purpose: no definition uses it, and a value the validator accepts and
	-- nothing can exercise is dead vocabulary. Pinned so it cannot be added by reflex.
	assert(#TargetResolver.TARGETING == 2, "two values")
	assert(TargetResolver.isTargeting("self"), "self is one")
	assert(TargetResolver.isTargeting("raycast"), "raycast is the other")
	assert(not TargetResolver.isTargeting("nearest"), "nearest is deferred, not present")
	assert(not TargetResolver.isTargeting("raycst"), "and a typo is not a value")
end)

T("a radius of zero picks the nearest candidate in front", function()
	local chosen = TargetResolver.resolve({ unit(30), unit(10), unit(20) }, ORIGIN, FORWARD, 60, 0)
	assert(#chosen == 1, "a single-target shot returns a list of one, got " .. #chosen)
	assert(chosen[1].position.x == 10, "and it is the nearest, not the first in the table")
end)

T("a candidate behind the caster is not a candidate", function()
	-- t < 0 is excluded. This is the difference between a shot and a magnet.
	local chosen = TargetResolver.resolve({ unit(-5), unit(25) }, ORIGIN, FORWARD, 60, 0)
	assert(#chosen == 1, "one hit")
	assert(chosen[1].position.x == 25, "the one in front, not the one behind")
end)

T("a candidate beyond the range is not a candidate", function()
	local chosen = TargetResolver.resolve({ unit(61) }, ORIGIN, FORWARD, 60, 0)
	assert(#chosen == 0, "range is a boundary, not a suggestion")
	assert(
		#TargetResolver.resolve({ unit(60) }, ORIGIN, FORWARD, 60, 0) == 1,
		"and the boundary itself is inside"
	)
end)

T("a dead candidate is not a candidate", function()
	-- The same rule the duration effects learned in phase 4b: the engine should not be asked to
	-- damage a corpse, and a corpse should not absorb a shot meant for someone behind it.
	local chosen = TargetResolver.resolve({ unit(10, false), unit(20) }, ORIGIN, FORWARD, 60, 0)
	assert(#chosen == 1, "one hit")
	assert(chosen[1].position.x == 20, "the living one behind the body")
end)

T("a shot that hits nothing returns an empty list, not nil and not the caster", function()
	-- D6: a miss is not a refusal. The caller gets an empty list and decides what a shot costs;
	-- this module's only job is to not invent a target.
	local chosen = TargetResolver.resolve({}, ORIGIN, FORWARD, 60, 0)
	assert(type(chosen) == "table", "a list, always")
	assert(#chosen == 0, "and empty")
	local behind = TargetResolver.resolve({ unit(-1) }, ORIGIN, FORWARD, 60, 0)
	assert(#behind == 0, "and nothing behind counts as a hit")
end)

T("a radius includes everybody inside the sphere around the impact point", function()
	local chosen = TargetResolver.resolve({ unit(10), unit(12), unit(14) }, ORIGIN, FORWARD, 60, 5)
	assert(
		#chosen == 3,
		"all three are inside a radius of 5 around the impact at x = 10, got " .. #chosen
	)
	local tight = TargetResolver.resolve({ unit(10), unit(12), unit(14) }, ORIGIN, FORWARD, 60, 1)
	assert(
		#tight == 1,
		"and a tighter radius takes only the one at the impact point, got " .. #tight
	)
end)

T("the sphere is centred on the impact point, not on the caster", function()
	-- The shot lands at x = 30 and the sphere is built there. A candidate at x = 41 is 11 from the
	-- impact and 41 from the caster: inside a sphere of 32 around the shot, outside the same sphere
	-- around the caster. If this case ever flips, the sphere moved to the wrong end of the ray.
	--
	-- Note what it takes to write this case: every candidate nearer than the impact BECOMES the
	-- impact, so the only way to separate the two spheres is with a radius that reaches past the
	-- point where the two disagree. The first version of this test placed a decoy at x = 8 and
	-- asserted the impact was at 30 — the decoy was nearer and was the impact. The test was wrong
	-- and the resolver was right.
	local chosen = TargetResolver.resolve({ unit(30), unit(41) }, ORIGIN, FORWARD, 60, 32)
	assert(#chosen == 2, "both are inside a sphere of 32 around the impact, got " .. #chosen)
	local tight = TargetResolver.resolve({ unit(30), unit(41) }, ORIGIN, FORWARD, 60, 5)
	assert(#tight == 1, "and only the impact one inside a sphere of 5, got " .. #tight)
end)

T("a radius with nothing to hit is still empty: no impact point, no sphere", function()
	local chosen = TargetResolver.resolve({ unit(-5) }, ORIGIN, FORWARD, 60, 10)
	assert(#chosen == 0, "an area shot into nothing hits nothing")
end)

T("y alignment does not change who is hit", function()
	-- A candidate directly above the ray at the same distance along it is still in front and in
	-- range; only the along-axis test decides, so the vertical case belongs to the caller's sphere
	-- and not to the ray.
	local above = { id = "above", alive = true, position = { x = 20, y = 9, z = 0 } }
	local chosen = TargetResolver.resolve({ above }, ORIGIN, FORWARD, 60, 0)
	assert(#chosen == 1, "the along-axis test is what selects")
end)

T("the effects vocabulary is the three aimed kinds", function()
	assert(TargetResolver.isOffensive("damage"), "damage is aimed")
	assert(TargetResolver.isOffensive("dot"), "dot is aimed")
	assert(TargetResolver.isOffensive("debuff"), "debuff is aimed")
	assert(not TargetResolver.isOffensive("heal"), "heal is not: it lands on the caster")
	assert(not TargetResolver.isOffensive("buff"), "buff is not")
	assert(not TargetResolver.isOffensive("dash"), "dash is not")
end)

T("junk in returns an empty list rather than a crash", function()
	-- The resolver is called from a heartbeat, and a heartbeat that errors takes the whole server's
	-- time loop with it. Nothing here may throw.
	assert(#TargetResolver.resolve(nil, ORIGIN, FORWARD, 60, 0) == 0, "no candidates")
	assert(#TargetResolver.resolve({ unit(10) }, nil, FORWARD, 60, 0) == 0, "no origin")
	assert(#TargetResolver.resolve({ unit(10) }, ORIGIN, nil, 60, 0) == 0, "no direction")
	assert(
		#TargetResolver.resolve({ unit(10) }, ORIGIN, FORWARD, nil, 0) == 0,
		"no range means no reach"
	)
	assert(
		#TargetResolver.resolve({ { position = { x = 5 } }, "junk", 7 }, ORIGIN, FORWARD, 60, 0)
			== 0,
		"malformed units"
	)
end)

return T.report()
