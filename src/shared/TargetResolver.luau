--[[
	TargetResolver.luau — who an ability lands on, decided without an engine.

	Two jobs, and they are the two this kit keeps separating:

	  * the VOCABULARY — which targeting values exist, and which effect kinds are aimed;
	  * the SELECTION — given candidates the engine has already found, and the point the shot landed
	    on, who is actually hit.

	It does not do DETECTION. It never asks where a wall is, never asks what is in the way, and never
	touches the world: a candidate that reached this module has already been through the raycast, and
	the point it landed on has already been computed by it. That is what makes it testable with three
	tables and no Studio.

	Positions are plain `{ x, y, z }` numbers, not Vector3. The adapter converts, and the price of one
	conversion is a module with a suite.
]]

local TargetResolver = {}

--[[
	The targeting vocabulary.

	Read by AbilityDefinition through injection, never copied into it: a list that exists in two files
	is a list that will disagree one day, and the day it does is the day a typo validates clean.

	`nearest` is deliberately absent. No definition uses it, and "nearest" without its specification is
	ambiguous in three ways that matter — nearest within what range, nearest in the facing cone or in
	every direction, and whether walls count. It enters when a definition needs it and brings its own
	specification with it.
]]
TargetResolver.TARGETING = { "self", "raycast" }

--[[
	The effect kinds that are aimed, declared ONCE.

	Three readers: the validator, which refuses the two combinations where aiming is a contradiction;
	the Bootstrap, which pre-splits a firing into aimed and not; and this module's own selection. Three
	copies of a list of three strings is exactly the drift the enum rule already kills, so it gets the
	same treatment: one list, read everywhere, written here only.
]]
TargetResolver.OFFENSIVE_KINDS = { "damage", "dot", "debuff" }

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

function TargetResolver.isTargeting(value)
	return contains(TargetResolver.TARGETING, value)
end

function TargetResolver.isOffensive(kind)
	return contains(TargetResolver.OFFENSIVE_KINDS, kind)
end

local function sub(a, b)
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function distance(a, b)
	local d = sub(a, b)
	return math.sqrt(dot(d, d))
end

local function isPosition(value)
	return type(value) == "table" and type(value.x) == "number"
end

local function isUnit(value)
	return type(value) == "table" and value.alive == true and isPosition(value.position)
end

--[[
	Chooses from the candidates. ALWAYS returns a list:

	    radius == 0  ->  zero elements (a miss) or the one nearest the impact point
	    radius  > 0  ->  every living candidate inside the sphere centred on the impact point

	A resolver that returned a single target in one case and a list in the other would push that
	special case into every caller. With a list, the caller is a loop that happens to run once.

	`impactPoint` is required and is never nil — the adapter always has one, because a raycast that
	hit nothing reports `origin + direction * range` rather than nothing at all. A nil here would move
	the "what if there was no hit" decision into this module or into every caller, and it is neither's
	to make: the sphere is centred at the end of the shot, not in the air behind a wall.

	Two rules that are pure and therefore testable, and that the adapter also happens to enforce:

	  * THE CASTER IS NEVER A DIRECT TARGET. The ray starts at the caster's root, so the caster sits
	    at t = 0, and t = 0 is not a hit — nothing is ever struck at zero distance. With a radius the
	    caster can be caught by the splash, which is a different sentence and is meant to be.
	  * THE SPHERE IGNORES WALLS. The raycast did the occlusion work for the centre of the blast, and
	    a candidate behind a wall relative to the impact point still takes the splash. Oclusion-aware
	    splash, like `nearest`, enters when something asks for it by name.
]]
function TargetResolver.resolve(candidates, origin, direction, range, radius, impactPoint)
	local chosen = {}
	if type(candidates) ~= "table" or not isPosition(origin) or not isPosition(direction) then
		return chosen
	end
	if not isPosition(impactPoint) then
		return chosen
	end

	range = tonumber(range) or 0
	radius = tonumber(radius) or 0

	if radius > 0 then
		for _, unit in ipairs(candidates) do
			if isUnit(unit) and distance(unit.position, impactPoint) <= radius then
				table.insert(chosen, unit)
			end
		end
		return chosen
	end

	-- Single target: alive, in front, within range, nearest to where the shot landed.
	local best = nil
	local bestDistance = math.huge
	for _, unit in ipairs(candidates) do
		if isUnit(unit) then
			local along = dot(sub(unit.position, origin), direction)
			if along > 0 and along <= range then
				local near = distance(unit.position, impactPoint)
				if near < bestDistance then
					best = unit
					bestDistance = near
				end
			end
		end
	end

	if best == nil then
		-- A miss. Empty, not nil and not the caster: the caller decides what a shot that hits
		-- nothing costs, and D6 says it costs the same as one that hits.
		return chosen
	end

	table.insert(chosen, best)
	return chosen
end

return TargetResolver
