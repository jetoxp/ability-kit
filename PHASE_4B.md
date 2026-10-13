# Phase 4b — the `EffectSystem`

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase delivers, and why it is shaped this way

The module that knows **what is affecting whom right now**, and what should happen next. It is the
one where the kit's design is actually tested, because applying damage is where every framework is
tempted to reach for the engine.

It does not. Exactly like `AbilityManager` returns firings instead of dealing damage, this emits
**events** and lets a thin Roblox adapter translate them. So the rules that are hard to get right —
stacking, durations, tick timing, expiry — are testable in a terminal, and the adapter that is hard
to test is left with nothing to decide.

### Two flows, and the difference is the design

- **Instant** (damage, heal, dash) become events the moment a firing is applied.
- **Timed** (dot, buff, debuff) are registered and produce events as time passes, on `advance`.

A DoT tick is emitted as a plain damage event. The adapter does not need to know which flow it came
from, which is the point: **the adapter translates, it does not decide.**

### The target

Any table with `alive`, `health = { current, max }` and `position`, plus an `id` used as the key.
A dummy in a test and a Character behind the adapter are the same thing to this module — which is
the whole reason the adapter can be stupid and this cannot.

### The dash, and where the vector comes from

The **distance** comes from the definition. The **direction** comes from the context, computed by
the adapter from the caster's CFrame. Neither comes from a client, because a client never sends one:
it asks for "dash" and the server decides everything else. A client cannot widen the vector or
cancel it, because it has no vector to widen.

### The three stacking policies

Declared per effect, defaulting to `refresh`:

- **refresh** — the duration resets on the running instance; the magnitude does not add up
- **stack** — a second instance is kept, and both deal their damage or apply their multiplier
- **ignore** — if one is already running, the new one does nothing at all

The stacking key is *ability + kind + stat*, so two different abilities on the same target do not
collide, and an AoE buff and a self buff on the same stat are separate effects.

## The file structure

```
src/shared/
  EffectSystem.luau   NEW — 320 lines
  Ability.luau  AbilityManager.luau  ResourceManager.luau
  AbilityDefinition.luau  Config.luau  DefaultLoadout.luau  abilities/
tests/
  EffectSystemSpec.luau   NEW — 23 cases
  the other four suites, TestKit.luau, run.luau
```

## The code

### `src/shared/EffectSystem.luau`

*The whole phase. Read `advance` for the DoT catch-up, and `applyEffect` for the stacking decision.*

```lua
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
```

### `tests/EffectSystemSpec.luau`

*23 cases. The ones worth reading: the long tick that must not swallow ticks, and the three stacking policies.*

```lua
--[[
	EffectSystemSpec.luau — runs with `luau tests/EffectSystemSpec.luau`. No Studio, no Roblox.

	The two things worth reading here are the DoT tick catch-up and the three stacking policies.
	Everything else is an event shaped the way the adapter expects.
]]

local TestKit = require("./TestKit")
local Config = require("../src/shared/Config")
local EffectSystem = require("../src/shared/EffectSystem")

local T = TestKit.new("EffectSystem")

local function dummy(id, alive)
	return {
		id = id or "DUMMY",
		alive = alive ~= false,
		health = { current = 100, max = 100 },
		position = { x = 0, y = 0, z = 0 },
	}
end

local function dot(amount, duration, interval, stack)
	return {
		kind = "dot",
		amount = amount or 6,
		duration = duration or 4,
		interval = interval or 1,
		stack = stack,
	}
end

local function buff(multiplier, duration, stack, stat)
	return {
		kind = "buff",
		stat = stat or "speed",
		multiplier = multiplier or 1.5,
		duration = duration or 5,
		stack = stack,
	}
end

local function apply(system, effects, abilityId, target, extra)
	local context = {
		source = extra and extra.source or nil,
		target = target,
		direction = extra and extra.direction,
	}
	return system:applyFiring({ id = abilityId or "TEST", effects = effects, slot = 1 }, context)
end

-- ===== instant =====

T("an instant damage effect becomes one damage event, carrying the amount", function()
	local system = EffectSystem.new(Config)
	local target = dummy()
	local events = apply(system, { { kind = "damage", amount = 45 } }, "FIREBALL", target)
	assert(#events == 1, "one effect, one event, got " .. #events)
	assert(events[1].kind == "damage", "and it is a damage event")
	assert(events[1].amount == 45, "with the definition's amount")
	assert(events[1].target == target, "aimed at the target it was given")
end)

T("an instant heal becomes a heal event", function()
	local system = EffectSystem.new(Config)
	local events = apply(system, { { kind = "heal", amount = 45 } }, "HEAL", dummy())
	assert(#events == 1 and events[1].kind == "heal", "a heal must be its own event kind")
	assert(events[1].amount == 45, "with its amount")
end)

T("nothing lands on something already dead", function()
	local system = EffectSystem.new(Config)
	local dead = dummy("DEAD", false)
	local events = apply(
		system,
		{ { kind = "damage", amount = 45 }, { kind = "heal", amount = 45 } },
		"X",
		dead
	)
	assert(#events == 0, "a corpse takes no damage and receives no heal, got " .. #events)
end)

T("a timed effect on a dead target is not even registered", function()
	-- Otherwise it ticks damage onto a corpse, and the adapter — which translates without deciding
	-- — would faithfully apply it.
	local system = EffectSystem.new(Config)
	local dead = dummy("DEAD", false)
	local events = apply(system, { dot(6, 4, 1) }, "POISON", dead)
	assert(#events == 0, "no event")
	assert(not system:hasActive("DEAD", "POISON"), "and nothing registered")
end)

-- ===== dash =====

T("a dash carries the definition's distance and the context's direction", function()
	local system = EffectSystem.new(Config)
	local target = dummy()
	local direction = { x = 0, y = 0, z = -1 }
	local events = apply(
		system,
		{ { kind = "dash", distance = 32, duration = 0.25 } },
		"DASH",
		target,
		{ direction = direction }
	)
	assert(#events == 1 and events[1].kind == "dash", "one dash event")
	assert(
		events[1].distance == 32,
		"the distance comes from the definition, never from a caller's target"
	)
	assert(events[1].direction == direction, "and the direction from the context")
end)

T("a dash with no direction in the context still emits, with nil direction", function()
	-- The adapter is what fails then, not this module: it is the one that needs a CFrame.
	local system = EffectSystem.new(Config)
	local events = apply(system, { { kind = "dash", distance = 32 } }, "DASH", dummy())
	assert(#events == 1 and events[1].direction == nil, "the kit does not invent a facing")
end)

-- ===== dot =====

T("a DoT registers on landing and does not tick immediately", function()
	-- The ability's own damage effect is the initial hit. Ticking here would double it.
	local system = EffectSystem.new(Config)
	local events = apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	assert(#events == 0, "nothing on the landing frame, got " .. #events)
	assert(system:hasActive("DUMMY", "POISON"), "but it must be registered")
end)

T("a DoT ticks once per interval", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local events = system:advance(1.01)
	assert(#events == 1, "one second, one tick, got " .. #events)
	assert(events[1].kind == "damage", "emitted as a plain damage event")
	assert(events[1].amount == 6, "with the tick amount")
	assert(
		events[1].dot == true,
		"and marked as coming from a DoT, for anything that wants to know"
	)
end)

T("a long tick does not swallow DoT ticks", function()
	-- The case that matters on a lag spike: 3.5 seconds must produce 3 ticks of damage, not one.
	-- Losing them is the phantom-timer bug with hit points instead of seconds.
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local events = system:advance(3.5)
	assert(#events == 3, "3.5s at a 1s interval is 3 ticks, got " .. #events)
end)

T("a DoT stops ticking when its duration runs out", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 2, 1) }, "POISON", dummy())
	local first = system:advance(1.01)
	assert(#first == 1, "tick one")
	local rest = system:advance(1.01)
	assert(#rest == 2, "tick two plus the expiry, got " .. #rest)
	local after = system:advance(1)
	assert(#after == 0, "and nothing after it has expired, got " .. #after)
	assert(not system:hasActive("DUMMY", "POISON"), "with nothing left registered")
end)

T("expiry is reported with an effectEnded event", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 1, 1) }, "POISON", dummy())
	local events = system:advance(3)
	local ended = 0
	for _, event in ipairs(events) do
		if event.kind == "effectEnded" then
			ended += 1
		end
	end
	assert(ended == 1, "an expiring effect must say so, got " .. ended)
end)

-- ===== buffs and debuffs =====

T("a buff registers and emits a buff event with its multiplier", function()
	local system = EffectSystem.new(Config)
	local events = apply(system, { buff(1.5, 5) }, "HASTE", dummy())
	assert(#events == 1 and events[1].kind == "buff", "one buff event")
	assert(events[1].multiplier == 1.5, "carrying the multiplier")
	assert(events[1].stat == "speed", "and the stat it changes")
	assert(system:hasActive("DUMMY", "HASTE"), "and the effect is running")
end)

T("a debuff is its own event kind, aimed at the same target", function()
	local system = EffectSystem.new(Config)
	local events = apply(
		system,
		{ { kind = "debuff", stat = "speed", multiplier = 0.7, duration = 4 } },
		"SLOW",
		dummy()
	)
	assert(#events == 1 and events[1].kind == "debuff", "a debuff must not be reported as a buff")
end)

T("an expiring buff reports effectEnded so the adapter can undo it", function()
	-- A speed multiplier the adapter applied has to be taken back, and this is the only signal it
	-- gets. A buff that expires silently is a permanent speed change.
	local system = EffectSystem.new(Config)
	apply(system, { buff(1.5, 2) }, "HASTE", dummy())
	local events = system:advance(2.5)
	assert(#events == 1, "only the expiry, got " .. #events)
	assert(events[1].kind == "effectEnded", "and it must be effectEnded")
	assert(events[1].stat == "speed" and events[1].multiplier == 1.5, "with what to undo")
end)

-- ===== stacking =====

T("the default stacking is refresh, and it resets the duration without adding a second", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	system:advance(3)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local active = system:getActiveFor("DUMMY")
	assert(#active == 1, "a refresh must not leave two instances, got " .. #active)
	assert(active[1].remaining > 3.9, "and the duration must be back at full")
end)

T("stacking ignore leaves the running effect alone", function()
	local system = EffectSystem.new(Config)
	apply(system, { buff(1.5, 5, "ignore") }, "HASTE", dummy())
	system:advance(2)
	local events = apply(system, { buff(3.0, 5, "ignore") }, "HASTE", dummy())
	assert(#events == 0, "an ignored re-application produces no event, got " .. #events)
	local active = system:getActiveFor("DUMMY")
	assert(#active == 1, "and no second instance")
	assert(active[1].multiplier == 1.5, "and the original magnitude survives")
end)

T("stacking stack keeps both instances and doubles the ticks", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1, "stack") }, "POISON", dummy())
	apply(system, { dot(6, 4, 1, "stack") }, "POISON", dummy())
	local active = system:getActiveFor("DUMMY")
	assert(#active == 2, "both must be kept, got " .. #active)
	local events = system:advance(1.01)
	assert(#events == 2, "so one second deals two ticks, got " .. #events)
end)

T("two different abilities on one target do not stack with each other", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	apply(system, { dot(6, 4, 1) }, "ACID", dummy())
	assert(#system:getActiveFor("DUMMY") == 2, "different abilities are different effects")
end)

T("two targets do not share effects", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy("FIRST"))
	assert(not system:hasActive("SECOND", "POISON"), "the other target is untouched")
	assert(#system:getActiveFor("SECOND") == 0, "and has nothing running")
end)

-- ===== applyFiring and housekeeping =====

T("one firing with several effects produces an event for each", function()
	local system = EffectSystem.new(Config)
	local events = apply(system, {
		{ kind = "damage", amount = 20 },
		{ kind = "dot", amount = 6, duration = 4, interval = 1 },
	}, "COMBO", dummy())
	assert(#events == 1, "the instant one emits, the timed one registers, got " .. #events)
	assert(system:hasActive("DUMMY", "COMBO"), "and both took effect")
end)

T("a nonsense firing or dt produces nothing and does not throw", function()
	local system = EffectSystem.new(Config)
	assert(#system:applyFiring(nil, {}) == 0, "a nil firing")
	assert(#system:applyFiring({ effects = nil }, {}) == 0, "a firing with no effects")
	assert(#system:advance(0) == 0, "dt = 0")
	assert(#system:advance(-1) == 0, "a negative dt")
	assert(#system:advance("soon") == 0, "a string dt")
end)

T("clear drops everything on a target", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1), buff(1.5, 5) }, "POISON", dummy())
	assert(#system:getActiveFor("DUMMY") == 2, "two effects running")
	system:clear("DUMMY")
	assert(#system:getActiveFor("DUMMY") == 0, "and a death or a respawn clears both")
end)

T("getActiveFor reports what a client would need, and only that", function()
	local system = EffectSystem.new(Config)
	apply(system, { buff(1.5, 5) }, "HASTE", dummy())
	local active = system:getActiveFor("DUMMY")
	assert(#active == 1, "one effect")
	local info = active[1]
	assert(info.abilityId == "HASTE", "with the ability")
	assert(info.kind == "buff" and info.stat == "speed", "the kind and stat")
	assert(info.multiplier == 1.5 and info.remaining ~= nil, "the magnitude and what is left")
	assert(info.target == nil, "and not the target object itself")
end)

return T.report()
```

## How to test it

```
luau tests/run.luau          # 162 cases across 5 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

**Still nothing to see in Studio**, and this is the last module for which that is true: it touches no
Roblox API either. The engine contact arrives with the adapter, in the next step.

## What writing it found

Three bugs, all mine, all in the module rather than the tests:

> **The last bite of a DoT was lost.** An effect dealing 6 damage per second for 2 seconds owes two
> ticks; it delivered one, because `remaining` was drained *before* the tick was resolved, so when
> the tick and the expiry fell on the same `advance` the tick saw a negative duration and skipped.
> **The same shape as the phantom cooldown in phase 2 — time that goes missing at a boundary — with
> hit points instead of seconds.**

- **The target was not stored on the instance**, so `advance` would have read `nil` when emitting a
  tick. Caught by re-reading the module before running anything.
- **Timed effects had no dead-target guard.** An instant effect checked, a DoT did not, so a corpse
  could be poisoned and the adapter — which translates without deciding — would have applied the
  damage faithfully.

And one from the review side, on the ResourceManager: `tonumber(start) or spec.max` accepted a
**string** starting value while `canPay` refuses a string cost with rigour. Half-indulgent is worse
than either extreme, and it is inconsistent in the direction nobody tests. It now asserts, like
`Ability.new` does for its arguments.

The same round added **`ResourceManager:getOwnerResources()`**, which returns the live pools in the
shape `Ability:canActivate` reads (`owner.resources[pool].current`). That is what answers the phase-5
note about checking affordability *before* activating: the check the manager already performs **is**
that check, when it is handed these.

## The numbers

- Tests: **162** across 5 suites — AbilityDefinitionSpec 40 · AbilitySpec 34 · AbilityManagerSpec 35 · ResourceManagerSpec 30 · EffectSystemSpec 23
- Lines: **1865 source + 1956 tests** = 3821
- Commits: **17**
- selene: 0 errors, 0 warnings · stylua: clean

## What is left in this phase

- **Validating `stack` in `AbilityDefinition`.** The policies are implemented and tested here, but a
  typo like `stack = "refrsh"` currently falls back to the default in silence. That is the next
  small change: add it to the per-kind field whitelist and refuse an unknown value.
- **The `EffectAdapter`**, the thin Roblox layer that turns these events into `Humanoid:TakeDamage`
  and CFrame writes. It cannot be tested off-engine, which is why it is being kept to translation
  only — and why it gets a check in Studio rather than a suite.
- **The Studio check**, and with it a warning owed to the user: an effects test needs a target. The
  plan is the player's own character in a playtest, rather than inserting a dummy into their place.

## Still not verified

Five modules, and the caveat is unchanged and now almost the whole point: **no full game boot, and
nothing has touched Roblox.** Every rule in this kit is verified, exhaustively, against tables and
events. The first line that talks to the engine is in the next step, and it is deliberately the
smallest one.
