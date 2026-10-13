--[[
	EffectSystem.luau — what is affecting whom right now, and what should happen next.

	It does not apply anything. Exactly like AbilityManager returning firings instead of dealing
	damage, this emits EVENTS and lets a thin Roblox adapter translate them into
	`Humanoid:TakeDamage`, a CFrame write, or — in a test — a line in a table. That is what keeps the
	rules here testable with no engine: stacking, durations, tick timing, expiry.

	Two flows, and the difference is the design:

	  - INSTANT effects (damage, heal, dash) become events the moment a firing is applied.
	  - TIMED effects (dot, buff, debuff) are registered and produce events as time passes, on
	    `advance`.

	A DoT tick is emitted as a plain damage event. The adapter does not need to know which flow it
	came from, which is the point: the adapter translates, it does not decide.

	The target is any table with `alive`, `health = { current, max }` and `position`. A dummy in a
	test and a Character behind the adapter are the same thing to this module, which is why the
	adapter can be stupid and this cannot.

	No requires and no Roblox: the config is injected.
]]

local EffectSystem = {}
EffectSystem.__index = EffectSystem

-- Every event this system emits. The adapter switches on these and nothing else, so this list is
-- the adapter's whole contract.
EffectSystem.EVENTS = { "damage", "heal", "dash", "buff", "debuff", "effectEnded" }

--[[
	The stacking policies an effect may declare, validated in AbilityDefinition:

	  refresh : the duration resets on the running instance; the magnitude does not add up
	  stack   : a second instance is kept, and both deal their damage or apply their multiplier
	  ignore  : if one is already running, the new one does nothing at all

	Declared per effect rather than defaulted silently, so a typo is caught at load.
]]
EffectSystem.STACKING = { "refresh", "stack", "ignore" }
EffectSystem.DEFAULT_STACKING = "refresh"

function EffectSystem.new(config)
	assert(type(config) == "table", "EffectSystem.new needs the config")

	local self = setmetatable({}, EffectSystem)
	self.config = config
	self.active = {} -- [targetId] = { [instanceId] = instance }
	self.nextInstanceId = 0
	return self
end

-- An effect's identity for stacking. Same ability, same kind, same stat: one effect. A buff with no
-- stat (a shield, a stance) still separates by kind and ability.
local function keyFor(abilityId, effect)
	return string.format(
		"%s|%s|%s",
		tostring(abilityId),
		tostring(effect.kind),
		tostring(effect.stat or "-")
	)
end

local function idOf(target)
	if type(target) ~= "table" then
		return nil
	end
	return target.id or target
end

local function isAlive(target)
	return type(target) == "table" and target.alive ~= false
end

--[[
	Runs one effect from one firing, and returns the events it produced.

	`context` carries the two things this module cannot know on its own:
	    source    : the target the effect came from
	    target    : the target it lands on
	    direction : a unit vector, for a dash. Supplied by the adapter, because computing one needs a
	                CFrame. The DISTANCE comes from the definition, so the client cannot widen the
	                vector: it never sends one.
]]
function EffectSystem:applyEffect(effect, abilityId, context)
	local events = {}
	if type(effect) ~= "table" or type(effect.kind) ~= "string" then
		return events
	end

	local target = context.target
	if effect.kind == "damage" or effect.kind == "heal" then
		if not isAlive(target) then
			-- Hitting or healing something already dead changes nothing, and emitting the event
			-- anyway would only make the adapter's job harder.
			return events
		end
		table.insert(events, {
			kind = effect.kind,
			target = target,
			amount = effect.amount,
			source = context.source,
			abilityId = abilityId,
		})
		return events
	elseif effect.kind == "dash" then
		if not isAlive(target) then
			return events
		end
		table.insert(events, {
			kind = "dash",
			target = target,
			distance = effect.distance,
			direction = context.direction,
			abilityId = abilityId,
		})
		return events
	end

	-- Everything below lives over time and has to be registered against a target.
	-- A timed effect on something already dead is a no-op, same as an instant one: it would tick
	-- damage onto a corpse, and the adapter — which translates without deciding — would apply it.
	if not isAlive(target) then
		return events
	end

	local id = idOf(target)
	if id == nil then
		return events
	end

	local stacking = effect.stack or EffectSystem.DEFAULT_STACKING
	local key = keyFor(abilityId, effect)
	self.active[id] = self.active[id] or {}

	-- Find a running instance with the same key.
	local existing = nil
	for _, instance in pairs(self.active[id]) do
		if instance.key == key then
			existing = instance
			if stacking ~= "stack" then
				break
			end
		end
	end

	if existing ~= nil and stacking == "ignore" then
		return events
	end

	if existing ~= nil and stacking == "refresh" then
		existing.remaining = effect.duration
		if effect.amount ~= nil then
			existing.amount = effect.amount
		end
		if effect.multiplier ~= nil then
			existing.multiplier = effect.multiplier
		end
		table.insert(events, {
			kind = effect.kind == "dot" and "damage"
				or (effect.kind == "debuff" and "debuff" or "buff"),
			target = target,
			stat = effect.stat,
			multiplier = existing.multiplier,
			remaining = existing.remaining,
			refreshed = true,
			abilityId = abilityId,
		})
		return events
	end

	self.nextInstanceId += 1
	local instance = {
		instanceId = self.nextInstanceId,
		key = key,
		abilityId = abilityId,
		-- Held so advance can name the target of a tick without a reverse lookup.
		target = target,
		kind = effect.kind,
		stat = effect.stat,
		amount = effect.amount,
		multiplier = effect.multiplier,
		remaining = effect.duration,
		interval = effect.interval,
		timeToTick = effect.kind == "dot" and effect.interval or 0,
		stacking = stacking,
	}
	self.active[id][instance.instanceId] = instance

	if effect.kind == "dot" then
		-- A DoT does not tick on the frame it lands: the ability's own damage effect is the initial
		-- hit, and ticking here would double it.
		return events
	end

	table.insert(events, {
		kind = effect.kind == "debuff" and "debuff" or "buff",
		target = target,
		stat = effect.stat,
		multiplier = effect.multiplier,
		remaining = effect.duration,
		abilityId = abilityId,
	})
	return events
end

--[[
	Applies one firing from AbilityManager:advance and returns the events.

	This is the whole integration surface between the two modules: a firing in, events out, and
	neither of them knows the other exists.
]]
function EffectSystem:applyFiring(firing, context)
	local events = {}
	if type(firing) ~= "table" or type(firing.effects) ~= "table" then
		return events
	end

	local resolved = {
		source = context and context.source or nil,
		target = context and context.target or nil,
		direction = context and context.direction or nil,
	}

	for _, effect in ipairs(firing.effects) do
		for _, event in ipairs(self:applyEffect(effect, firing.id, resolved)) do
			table.insert(events, event)
		end
	end

	return events
end

function EffectSystem:advance(dt)
	local events = {}
	if type(dt) ~= "number" or dt <= 0 or dt ~= dt then
		return events
	end

	local expired = {}

	for id, instances in pairs(self.active) do
		for instanceId, instance in pairs(instances) do
			-- The tick is resolved BEFORE the duration is drained. Draining first loses the final
			-- bite whenever it coincides with the expiry: a 6-damage-per-second effect lasting two
			-- seconds owes two ticks, and would have dealt one.
			if instance.kind == "dot" then
				instance.timeToTick = instance.timeToTick - dt
				-- A while, not an if: a long tick must not swallow a tick of damage. Losing one on a
				-- lag spike is the phantom-timer bug with hit points instead of seconds.
				while instance.timeToTick <= 0 and instance.remaining > 0 do
					table.insert(events, {
						kind = "damage",
						target = instance.target,
						amount = instance.amount,
						dot = true,
						abilityId = instance.abilityId,
					})
					instance.timeToTick = instance.timeToTick + (instance.interval or 1)
				end
			end

			instance.remaining = instance.remaining - dt

			if instance.remaining <= 0 then
				table.insert(expired, { id = id, instanceId = instanceId, instance = instance })
			end
		end
	end

	-- Expiries are applied after the walk: removing from a table while iterating it is how a loop
	-- silently skips entries.
	for _, entry in ipairs(expired) do
		local instances = self.active[entry.id]
		if instances ~= nil then
			instances[entry.instanceId] = nil
			if next(instances) == nil then
				self.active[entry.id] = nil
			end
		end
		table.insert(events, {
			kind = "effectEnded",
			targetId = entry.id,
			target = entry.instance.target,
			stat = entry.instance.stat,
			multiplier = entry.instance.multiplier,
			abilityId = entry.instance.abilityId,
		})
	end

	return events
end

-- Everything running on one target, for replication and for tests.
function EffectSystem:getActiveFor(id)
	local out = {}
	local instances = self.active[id]
	if instances == nil then
		return out
	end
	for _, instance in pairs(instances) do
		table.insert(out, {
			abilityId = instance.abilityId,
			kind = instance.kind,
			stat = instance.stat,
			multiplier = instance.multiplier,
			remaining = instance.remaining,
		})
	end
	return out
end

function EffectSystem:hasActive(id, abilityId)
	local instances = self.active[id]
	if instances == nil then
		return false
	end
	for _, instance in pairs(instances) do
		if instance.abilityId == abilityId then
			return true
		end
	end
	return false
end

-- Drops everything on a target. A death, a respawn, a phase change.
function EffectSystem:clear(id)
	self.active[id] = nil
	return self
end

return EffectSystem
