--[[
	TargetAdapter.luau — DETECTION, the half that needs a world.

	Three jobs, and all three need the engine:

	  1. the raycast, with the caster filtered out of its own shot;
	  2. the impact point, INCLUDING the fallback when the ray hits nothing;
	  3. Characters into the units the pure modules read.

	It does no selection. Which candidate wins, whether the sphere catches anybody, what happens on a
	miss — all of that is TargetResolver's, and it is pure so it has a suite. This file is the price of
	that suite: about forty lines nobody can test without Studio, in exchange for a hundred that
	everybody can.

	It also does not decide whether a miss is an error. A miss is a miss: the resolver says so with an
	empty list and the caller reads it.
]]

local TargetAdapter = {}
TargetAdapter.__index = TargetAdapter

-- Vector3 -> { x, y, z }, the shape every pure module reads. See the note in EffectAdapter.describe.
local function point(v)
	return { x = v.X, y = v.Y, z = v.Z }
end

function TargetAdapter.new(config, effectAdapter)
	local self = setmetatable({}, TargetAdapter)
	self.config = config
	self.effects = effectAdapter -- for describe() and directionOf(), the two engine reads
	return self
end

--[[
	Every Character in the world that could be hit.

	Deliberately includes the caster: the resolver makes no exception for anybody, and the splash
	catching whoever stands in the blast is geometry rather than a targeting decision. The raycast's
	filter is what keeps the caster out of its own shot, and it is one line below.
]]
function TargetAdapter:gather()
	local units = {}
	for _, model in ipairs(workspace:GetDescendants()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") ~= nil then
			local unit = self.effects.describe(model)
			if unit ~= nil then
				table.insert(units, unit)
			end
		end
	end
	return units
end

--[[
	The ray, and where it landed.

	Returns `(impactPoint, hitInstance)`. `impactPoint` is NEVER nil: when the ray reaches nothing it
	is `origin + direction * range`, so the sphere centres at the end of the shot instead of nowhere.
	That is the adapter's half of the contract the resolver is written against.

	The caster is excluded from the ray, and that exclusion is the ONLY enforcement of "the caster is
	never a direct target" — the resolver is not told who the caster is and makes no exception. Remove
	this filter and the first thing a Fireball hits is the arm firing it.
]]
function TargetAdapter:castRay(casterCharacter, range, direction)
	local root = casterCharacter and casterCharacter:FindFirstChild("HumanoidRootPart") or nil
	if root == nil or direction == nil then
		return nil, nil
	end

	local origin = root.Position
	local reach = direction * math.max(range or 0, 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { casterCharacter }
	params.IgnoreWater = true

	local result = workspace:Raycast(origin, reach, params)
	if result ~= nil then
		return point(result.Position), result.Instance
	end
	return point(origin + reach), nil
end

return TargetAdapter
