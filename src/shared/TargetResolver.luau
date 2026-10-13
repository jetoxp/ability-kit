--[[
	TargetResolver.luau - who an ability lands on, decided without an engine.

	Two jobs: the VOCABULARY (which targeting values and which effect kinds are aimed) and the
	SELECTION (given candidates the engine already found, and the point the shot landed on, who is
	hit). It does no DETECTION and never touches the world, which is what makes it testable with
	tables and no Studio. The long-form reasoning lives in PHASE_6.md.

	Positions are plain `{ x, y, z }`, not Vector3. The adapter converts.
]]

local TargetResolver = {}

-- Read by AbilityDefinition through injection rather than copied into it. `nearest` is deliberately
-- absent: nothing uses it, and a value the validator accepts and nothing can exercise is dead
-- vocabulary that makes the next typo look valid.
TargetResolver.TARGETING = { "self", "raycast" }

-- The aimed kinds. Three readers - the validator, the Bootstrap's pre-split and this module's own
-- selection - reach them through isOffensive, never by walking this table.
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

local function isPosition(value)
	return type(value) == "table" and type(value.x) == "number"
end

local function isUnit(value)
	return type(value) == "table" and value.alive == true and isPosition(value.position)
end

local function distanceSquared(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

--[[
	Always a list: empty for a miss, one for a single-target shot, N for an area. `impactPoint` is
	required and never nil - the adapter passes where the ray landed, or `origin + direction * range`
	when it landed nowhere, so a miss centres the blast at the end of the shot rather than in the air.
]]
function TargetResolver.resolve(candidates, origin, direction, range, radius, impactPoint)
	local chosen = {}
	if
		type(candidates) ~= "table"
		or not isPosition(origin)
		or not isPosition(direction)
		or not isPosition(impactPoint)
	then
		return chosen
	end
	range, radius = tonumber(range) or 0, tonumber(radius) or 0

	if radius > 0 then
		local limit = radius * radius
		for _, unit in ipairs(candidates) do
			if isUnit(unit) and distanceSquared(unit.position, impactPoint) <= limit then
				table.insert(chosen, unit)
			end
		end
		return chosen
	end

	-- Single target: alive, in front, in range, nearest to where the shot landed. Dead candidates go
	-- here rather than in the adapter - a corpse is not a target, and a shot whose only reachable
	-- candidate is a corpse is a miss. `along >= 0` makes no exception for anybody, including a
	-- candidate on the ray's own origin.
	local best, bestDistance = nil, math.huge
	for _, unit in ipairs(candidates) do
		if isUnit(unit) then
			local from = {
				x = unit.position.x - origin.x,
				y = unit.position.y - origin.y,
				z = unit.position.z - origin.z,
			}
			local along = from.x * direction.x + from.y * direction.y + from.z * direction.z
			if along >= 0 and along <= range then
				local toImpact = distanceSquared(unit.position, impactPoint)
				if toImpact < bestDistance then
					best, bestDistance = unit, toImpact
				end
			end
		end
	end

	if best ~= nil then
		table.insert(chosen, best)
	end
	return chosen
end

return TargetResolver
