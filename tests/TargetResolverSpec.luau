--[[
	TargetResolverSpec.luau — runs with `luau tests/TargetResolverSpec.luau`. No Studio.

	Every selection rule, in plain tables. This is the payoff of the detection/selection split:
	nothing here knows what a Character is, and the only thing the engine contributes is a hit point.
]]

local TestKit = require("./TestKit")
local TargetResolver = require("../src/shared/TargetResolver")

local T = TestKit.new("TargetResolver")

local ORIGIN = { x = 0, y = 0, z = 0 }
local FORWARD = { x = 1, y = 0, z = 0 }

local function unit(x, alive, y)
	return {
		id = "u" .. tostring(x),
		alive = alive ~= false,
		position = { x = x, y = y or 0, z = 0 },
	}
end

local function at(x, y, z)
	return { x = x, y = y or 0, z = z or 0 }
end

T("the vocabulary is exactly self and raycast", function()
	assert(#TargetResolver.TARGETING == 2, "two values")
	assert(TargetResolver.isTargeting("self"), "self is one")
	assert(TargetResolver.isTargeting("raycast"), "raycast is the other")
	assert(not TargetResolver.isTargeting("nearest"), "nearest is deferred, not present")
	assert(not TargetResolver.isTargeting("raycst"), "and a typo is not a value")
end)

T("the aimed kinds are declared here, once, and are the three", function()
	-- Read by the validator, by the Bootstrap's pre-split, and by this module. One list, three
	-- readers: the same treatment the targeting enum gets, for the same reason.
	assert(#TargetResolver.OFFENSIVE_KINDS == 3, "three aimed kinds")
	assert(TargetResolver.isOffensive("damage"), "damage")
	assert(TargetResolver.isOffensive("dot"), "dot")
	assert(TargetResolver.isOffensive("debuff"), "debuff")
	assert(not TargetResolver.isOffensive("heal"), "heal lands on the caster")
	assert(not TargetResolver.isOffensive("buff"), "buff lands on the caster")
	assert(not TargetResolver.isOffensive("dash"), "dash is the caster moving")
end)

T("a single-target shot returns a list of exactly one", function()
	-- Always a list, even for one. The caller is a loop that happens to run once.
	local chosen = TargetResolver.resolve({ unit(30) }, ORIGIN, FORWARD, 60, 0, at(30))
	assert(type(chosen) == "table", "a list")
	assert(#chosen == 1, "of one, got " .. #chosen)
end)

T("with several in line, the one nearest the impact point wins", function()
	local chosen =
		TargetResolver.resolve({ unit(30), unit(10), unit(20) }, ORIGIN, FORWARD, 60, 0, at(20))
	assert(#chosen == 1, "one")
	assert(
		chosen[1].position.x == 20,
		"the one where the shot landed, not the nearest to the caster"
	)
end)

T("the caster is never a direct target, even standing in its own shot", function()
	-- The ray starts at the caster's root, so the caster is at t = 0 and t = 0 is not a hit:
	-- nothing is ever struck at zero distance. This is the pure half of the rule; the adapter's
	-- half is filtering the caster out of the raycast so the first hit is not its own arm.
	local caster = unit(0)
	local chosen = TargetResolver.resolve({ caster, unit(25) }, ORIGIN, FORWARD, 60, 0, at(25))
	assert(#chosen == 1, "one hit")
	assert(chosen[1].position.x == 25, "and it is not the caster")
	assert(
		#TargetResolver.resolve({ caster }, ORIGIN, FORWARD, 60, 0, at(0)) == 0,
		"and alone, the caster is a miss"
	)
end)

T("the caster CAN be caught by the splash, which is a different sentence", function()
	-- radius == 0 never targets the caster; radius > 0 can, because a blast at the caster's feet
	-- reaching the caster is geometry rather than a targeting decision.
	local chosen = TargetResolver.resolve({ unit(0), unit(2) }, ORIGIN, FORWARD, 60, 5, at(1))
	assert(#chosen == 2, "both are inside the sphere, got " .. #chosen)
end)

T("a candidate behind the caster is not a candidate for the ray", function()
	local chosen = TargetResolver.resolve({ unit(-5), unit(25) }, ORIGIN, FORWARD, 60, 0, at(25))
	assert(#chosen == 1, "one")
	assert(chosen[1].position.x == 25, "the one in front")
end)

T("range is a boundary and the boundary itself is inside it", function()
	assert(
		#TargetResolver.resolve({ unit(61) }, ORIGIN, FORWARD, 60, 0, at(61)) == 0,
		"past the range is a miss"
	)
	assert(
		#TargetResolver.resolve({ unit(60) }, ORIGIN, FORWARD, 60, 0, at(60)) == 1,
		"at the range is a hit"
	)
end)

T("a dead candidate is discarded, and alone it is a miss", function()
	-- The phase 4b rule, in the pure layer: a corpse does not absorb a shot meant for somebody else.
	assert(
		#TargetResolver.resolve({ unit(10, false) }, ORIGIN, FORWARD, 60, 0, at(10)) == 0,
		"a corpse is a miss"
	)
end)

T("a living candidate beats a nearer corpse", function()
	local chosen =
		TargetResolver.resolve({ unit(10, false), unit(25) }, ORIGIN, FORWARD, 60, 0, at(10))
	assert(#chosen == 1, "one")
	assert(chosen[1].position.x == 25, "the living one behind the body")
end)

T("a shot that hits nothing returns an empty list", function()
	local chosen = TargetResolver.resolve({}, ORIGIN, FORWARD, 60, 0, at(60))
	assert(type(chosen) == "table", "a list")
	assert(#chosen == 0, "and empty")
	assert(
		#TargetResolver.resolve({ unit(-1) }, ORIGIN, FORWARD, 60, 0, at(60)) == 0,
		"nothing in front, nothing hit"
	)
end)

T("the impact point decides, and the fallback to maximum range is a real case", function()
	-- On a hit, the adapter passes where the ray actually landed. On a miss it passes
	-- `origin + direction * range`, so the sphere sits at the end of the shot instead of nowhere.
	local candidates = { unit(30), unit(58) }
	local onHit = TargetResolver.resolve(candidates, ORIGIN, FORWARD, 60, 0, at(30))
	assert(onHit[1].position.x == 30, "the shot landed at 30 and hit the one at 30")
	local onMiss = TargetResolver.resolve(candidates, ORIGIN, FORWARD, 60, 0, at(60))
	assert(onMiss[1].position.x == 58, "the shot landed at the range and hit the nearest to that")
end)

T("a radius includes everybody inside the sphere, wherever they are", function()
	local chosen =
		TargetResolver.resolve({ unit(10), unit(12), unit(14) }, ORIGIN, FORWARD, 60, 5, at(10))
	assert(#chosen == 3, "all three, got " .. #chosen)
	local tight =
		TargetResolver.resolve({ unit(10), unit(12), unit(14) }, ORIGIN, FORWARD, 60, 1, at(10))
	assert(#tight == 1, "and a tighter radius takes only the one at the impact, got " .. #tight)
end)

T("the splash ignores walls, on both sides of the impact", function()
	-- Occlusion was the raycast's job for the centre of the blast. A candidate behind a wall still
	-- takes the splash; occlusion-aware splash, like nearest, enters when something asks by name.
	local frente = unit(10)
	local detras = { id = "detras", alive = true, position = at(13) }
	local chosen = TargetResolver.resolve({ frente, detras }, ORIGIN, FORWARD, 60, 4, at(10))
	assert(#chosen == 2, "the wall between them changes nothing, got " .. #chosen)
end)

T("the splash discards the dead too", function()
	local chosen =
		TargetResolver.resolve({ unit(10), unit(12, false) }, ORIGIN, FORWARD, 60, 5, at(10))
	assert(#chosen == 1, "the corpse does not take splash, got " .. #chosen)
end)

T("a radius with nothing near the impact is empty", function()
	assert(
		#TargetResolver.resolve({ unit(1) }, ORIGIN, FORWARD, 60, 3, at(60)) == 0,
		"a blast far from everyone"
	)
end)

T("the sphere is centred on the impact point, not on the caster", function()
	-- A candidate at x = 41 is 11 from an impact at 30 and 41 from the caster: inside a sphere of 32
	-- around the shot, outside the same sphere around the caster.
	local chosen = TargetResolver.resolve({ unit(30), unit(41) }, ORIGIN, FORWARD, 60, 32, at(30))
	assert(#chosen == 2, "both, got " .. #chosen)
	assert(
		#TargetResolver.resolve({ unit(30), unit(41) }, ORIGIN, FORWARD, 60, 5, at(30)) == 1,
		"and only the impact one in a tight one"
	)
end)

T("the vertical case belongs to the distance, not to the ray", function()
	local above = { id = "above", alive = true, position = at(20, 9, 0) }
	assert(
		#TargetResolver.resolve({ above }, ORIGIN, FORWARD, 60, 0, at(20)) == 1,
		"it is in front and in range"
	)
	assert(
		#TargetResolver.resolve({ above }, ORIGIN, FORWARD, 60, 0, at(60)) == 1,
		"and nearest to the impact even from below"
	)
end)

T("junk in returns an empty list rather than a crash", function()
	-- A heartbeat that errors takes the whole server's time loop with it.
	assert(#TargetResolver.resolve(nil, ORIGIN, FORWARD, 60, 0, at(0)) == 0, "no candidates")
	assert(#TargetResolver.resolve({ unit(10) }, nil, FORWARD, 60, 0, at(10)) == 0, "no origin")
	assert(#TargetResolver.resolve({ unit(10) }, ORIGIN, nil, 60, 0, at(10)) == 0, "no direction")
	assert(
		#TargetResolver.resolve({ unit(10) }, ORIGIN, FORWARD, 60, 0, nil) == 0,
		"no impact point is a refusal, not a guess"
	)
	assert(
		#TargetResolver.resolve(
				{ { position = { x = 5 } }, "junk", 7 },
				ORIGIN,
				FORWARD,
				60,
				0,
				at(5)
			) == 0,
		"malformed units"
	)
	assert(
		#TargetResolver.resolve({ unit(10) }, ORIGIN, FORWARD, nil, 0, at(10)) == 0,
		"no range means no reach"
	)
end)

T("a missing position is not a position", function()
	assert(
		#TargetResolver.resolve({ { id = "x", alive = true } }, ORIGIN, FORWARD, 60, 0, at(10)) == 0,
		"no position"
	)
	assert(
		#TargetResolver.resolve(
				{ { id = "x", alive = true, position = { y = 1 } } },
				ORIGIN,
				FORWARD,
				60,
				0,
				at(10)
			) == 0,
		"a position without x"
	)
end)

T("alive must be true, not merely present", function()
	-- `alive == true` rather than `~= false`: a unit that forgot the field is not a target, and
	-- guessing on its behalf is how a corpse gets shot.
	local sinCampo = { id = "y", alive = nil, position = at(20) }
	assert(
		#TargetResolver.resolve({ sinCampo }, ORIGIN, FORWARD, 60, 0, at(20)) == 0,
		"absent alive is not alive"
	)
end)

T("a range of zero reaches nothing", function()
	assert(
		#TargetResolver.resolve({ unit(0.5) }, ORIGIN, FORWARD, 0, 0, at(0.5)) == 0,
		"zero reach"
	)
end)

return T.report()
