--[[
	EffectAdapter.luau — the thin layer that turns events into engine calls.

	Its whole job is translation. It does not decide whether damage should land, whether a dash is
	allowed, or whether a buff is deserved: EffectSystem already decided all of that, and this file's
	one responsibility is that a `damage` event becomes `Humanoid:TakeDamage` and nothing clever
	happens in between.

	It is the only file in this kit that cannot be tested without an engine, which is precisely why it
	is the only one with no logic in it. Every rule it could have imagined lives in a module with a
	suite.

	This is server-side. The client never runs any of it, and never sends anything it reads from.
]]

local EffectAdapter = {}
EffectAdapter.__index = EffectAdapter

function EffectAdapter.new(config)
	assert(type(config) == "table", "EffectAdapter.new needs the config")
	local self = setmetatable({}, EffectAdapter)
	self.config = config
	-- [character] = { base = WalkSpeed before the first effect, count = how many are running }
	--
	-- A COUNT, not a single flag. The EffectSystem allows two speed effects to stack, and with a
	-- flag the first expiry restored the base and deleted the memory while the second was still
	-- running: the character dropped to base speed with a buff supposedly still on, and the second
	-- expiry then had nothing left to restore. Restoring happens when the count reaches zero.
	--
	-- LIMITATION: the adapter applies the most recent multiplier, so two DIFFERENT multipliers
	-- running at once are not composed into a product. Compose them in the game layer before here.
	self.speedEffects = {}
	return self
end

local function rootOf(character)
	return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

local function humanoidOf(character)
	return character:FindFirstChildOfClass("Humanoid")
end

--[[
	The unit the pure modules read, taken off a Character.

	This is the one place in the kit that knows a Humanoid exists. Everything above it speaks in
	`{ id, alive, health = { current, max }, position }`, which is why the EffectSystem has a suite
	and this file has a `print` check.
]]
function EffectAdapter.describe(character)
	if typeof(character) ~= "Instance" then
		return nil
	end
	local humanoid = humanoidOf(character)
	if humanoid == nil then
		return nil
	end
	local root = rootOf(character)
	return {
		id = character,
		instance = character,
		alive = humanoid.Health > 0,
		health = { current = humanoid.Health, max = humanoid.MaxHealth },
		position = root and root.Position or Vector3.zero,
	}
end

--[[
	A unit vector for a dash, from where the caster is facing, flattened so a dash never launches
	somebody into the sky because they were looking slightly up.

	The DISTANCE is never taken from here: it comes from the definition, and the client never sends
	either value. This only answers "which way", which is the one thing the pure module cannot know.
]]
function EffectAdapter.directionOf(character)
	if typeof(character) ~= "Instance" then
		return nil
	end
	local root = rootOf(character)
	if root == nil then
		return nil
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then
		-- Looking straight up or down. There is no facing to dash along, so there is no dash, and
		-- returning a zero vector would put a NaN into a CFrame somewhere downstream.
		return nil
	end
	return flat.Unit
end

function EffectAdapter:applySpeedEffect(character, humanoid, multiplier)
	local entry = self.speedEffects[character]
	if entry == nil then
		-- The first effect remembers the speed the character had, so restoring is possible without
		-- a definition having to carry the original.
		entry = { base = humanoid.WalkSpeed, count = 0 }
		self.speedEffects[character] = entry
	end
	entry.count += 1
	-- Applied to the remembered base, never to the previous multiplier, so two 2x effects cannot
	-- compound into an accidental 4x.
	humanoid.WalkSpeed = entry.base * (multiplier or 1)
end

--[[
	Applies one event. Returns whether it did something, which is all the caller needs to know.

	A `false` is not an error: an event aimed at something that no longer has a Humanoid is an
	ordinary thing to happen, and the EffectSystem is not told about it because it has no opinion
	about instances either.
]]
function EffectAdapter:apply(event)
	if type(event) ~= "table" or type(event.kind) ~= "string" then
		return false
	end

	local target = event.target
	if type(target) ~= "table" then
		return false
	end

	local character = target.instance
	if typeof(character) ~= "Instance" then
		return false
	end

	local humanoid = humanoidOf(character)
	if humanoid == nil or humanoid.Health <= 0 then
		-- Re-checked here rather than trusted from the unit: a tick of DoT can arrive on the frame
		-- a character dies, and the unit was read before that.
		return false
	end

	if event.kind == "damage" then
		humanoid:TakeDamage(event.amount)
		return true
	elseif event.kind == "heal" then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + event.amount)
		return true
	elseif event.kind == "dash" then
		local direction = event.direction
		if direction == nil or direction.Magnitude < 0.001 then
			return false
		end
		-- A single displacement, standing in for a smooth dash. The travel distance is the
		-- definition's; the direction is the caster's facing. A game that wants the motion to take
		-- time gives the humanoid a LinearVelocity for the duration instead — that belongs to the
		-- character phase, not here, and it is noted rather than guessed at.
		local root = rootOf(character)
		if root == nil then
			return false
		end
		character:PivotTo(character:GetPivot() + direction.Unit * event.distance)
		return true
	elseif event.kind == "buff" or event.kind == "debuff" then
		if event.stat ~= "speed" then
			-- Only walk speed has an obvious engine equivalent. Anything else is a stat this
			-- framework does not own, and inventing a mapping would be deciding, which is the one
			-- thing this file is not allowed to do.
			return false
		end
		self:applySpeedEffect(character, humanoid, event.multiplier)
		return true
	elseif event.kind == "effectEnded" then
		if event.stat ~= "speed" then
			return false
		end
		local entry = self.speedEffects[character]
		if entry == nil then
			return false
		end
		entry.count -= 1
		-- Only the LAST running effect restores. Doing it on the first one is how a character ends
		-- up at base speed while a buff is still supposed to be on.
		humanoid.WalkSpeed = entry.base
		if entry.count <= 0 then
			self.speedEffects[character] = nil
		end
		return true
	end

	return false
end

-- Applies a whole batch, which is what a tick produces. Returns how many landed.
function EffectAdapter:applyAll(events)
	local applied = 0
	for _, event in ipairs(events) do
		if self:apply(event) then
			applied += 1
		end
	end
	return applied
end

return EffectAdapter
