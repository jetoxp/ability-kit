--[[
	TargetResolver.luau — who an ability lands on, decided without an engine.

	Two jobs, and they are the two this kit keeps separating:

	  * the VOCABULARY — which targeting values exist and which effect kinds are aimed;
	  * the SELECTION — given candidates the engine has already found, who is actually hit.

	It does not do DETECTION. It never asks where a wall is, never asks what is in the way, and never
	touches the world: a candidate that reached this module has already been through the raycast. That
	is what makes it testable with three tables and no Studio, and it is why the decision about what
	matters — in front, in range, nearest, inside the sphere — lives here and not in the adapter.

	Positions are plain `{ x, y, z }` numbers, not Vector3. The adapter converts, and the price of
	one conversion is a module with a suite.
]]

local TargetResolver = {}

--[[
	The targeting vocabulary.

	Read by AbilityDefinition through injection, never copied into it: a list that exists in two
	files is a list that will disagree one day, and the day it does is the day a typo validates clean.

	`nearest` is deliberately absent. No definition uses it, and "nearest" without its specification
	is ambiguous in three ways that matter — nearest within what range, nearest in the facing cone or
	in every direction, and whether walls count. Dead vocabulary that the validator accepts and
	nothing can exercise is worse than no vocabulary at all; it enters when a definition needs it and
	brings its own specification with it.
]]
TargetResolver.TARGETING = { "self", "raycast" }

--[[
	The effect kinds that are aimed.

	Everything not in this list lands on the caster whatever the ability says, which is why the
	validator refuses both combinations where that would be a contradiction: an offensive effect in a
	self ability, and a raycast ability with nothing offensive in it.
]]
TargetResolver.OFFENSIVE = { "damage", "dot", "debuff" }

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
	return contains(TargetResolver.OFFENSIVE, kind)
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

local function isUnit(value)
	return type(value) == "table" and value.alive == true and type(value.position) == "table"
end

--[[
	Chooses from the candidates. ALWAYS returns a list:

	    radius == 0  ->  zero elements (a miss) or one (the nearest in front)
	    radius  > 0  ->  everybody inside the sphere centred on the impact point

	A resolver that returned a single target in one case and a list in the other would push that
	special case into every caller. With a list, the caller is a loop that happens to run once.

	The direction is a unit vector and the client never supplies it — it comes from the caster's
	HumanoidRootPart through the adapter. A candidate behind the caster is not a candidate: t < 0 is
	excluded, which is the difference between a shot and a magnet.
]]
function TargetResolver.resolve(candidates, origin, direction, range, radius)
	local chosen = {}
	if type(candidates) ~= "table" or type(origin) ~= "table" or type(direction) ~= "table" then
		return chosen
	end
	if type(origin.x) ~= "number" or type(direction.x) ~= "number" then
		return chosen
	end

	range = tonumber(range) or 0
	radius = tonumber(radius) or 0

	-- The first hit: nearest along the direction, in front, within range, alive.
	local first = nil
	local firstDistance = math.huge
	for _, unit in ipairs(candidates) do
		if isUnit(unit) then
			local along = dot(sub(unit.position, origin), direction)
			if along >= 0 and along <= range and along < firstDistance then
				first = unit
				firstDistance = along
			end
		end
	end

	if first == nil then
		-- A miss. Empty, not nil and not the caster: the caller decides what a shot that hits
		-- nothing costs, and D6 says it costs the same as one that hits.
		return chosen
	end

	if radius <= 0 then
		table.insert(chosen, first)
		return chosen
	end

	-- The sphere is centred on the IMPACT POINT, not on the caster and not on the middle of the
	-- group, so a wide shot still lands where it landed.
	local impact = {
		x = origin.x + direction.x * firstDistance,
		y = origin.y + direction.y * firstDistance,
		z = origin.z + direction.z * firstDistance,
	}
	for _, unit in ipairs(candidates) do
		if isUnit(unit) and distance(unit.position, impact) <= radius then
			table.insert(chosen, unit)
		end
	end
	return chosen
end

return TargetResolver
