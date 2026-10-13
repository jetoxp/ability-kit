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
  EffectSystem.luau       the rules: stacking, durations, tick timing, expiry
  Ability.luau  AbilityManager.luau  ResourceManager.luau
  AbilityDefinition.luau  Config.luau  DefaultLoadout.luau  abilities/
src/server/
  EffectAdapter.luau      NEW — the engine contact. No logic, on purpose.
tests/
  EffectSystemSpec.luau   31 cases
  the other four suites, TestKit.luau, run.luau
```

Two files in `src/shared` changed this round as well, and they are what makes the stacking policy
trustworthy: `AbilityDefinition` now validates `stack` against the policy list **the EffectSystem
declares**, rather than against a copy. A `stack = "refrsh"` is an error at load, naming the value
that was wrong. On an instant effect it comes back as an unknown field instead, because there is
nothing to stack.

If no EffectSystem is injected, the value goes unchecked rather than checked against a duplicate
list — a second copy of those policies is the drift this kit exists to avoid.

## The code

Every block below was regenerated from the working tree, and each carries the `git hash-object` of
the file it came from. A reader can check any of them against the repository instead of trusting
this document — which is the point, after an earlier version of this file pasted pre-fix code and
made the fixes unverifiable.

For the next review round the code will not be pasted whole at all: a round gets its diffs, not a
third copy of the file. A document that duplicates a file is a document that will one day disagree
with it.


### `src/shared/EffectSystem.luau`

*Read `advance` for the DoT catch-up, and `applyEffect` for the stacking decision.*

`git hash-object src/shared/EffectSystem.luau` -> `715eae5f4edd` -> `c0e6dc046d78`

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
		-- A DoT refresh emits NOTHING — its damage comes from the ticks, and emitting a `damage`
		-- event here once produced TakeDamage(nil) — but it does reset its budget. The tick counter
		-- is per-life, so carrying it across a refresh spends the new duration's allowance: a 4s/1s
		-- effect refreshed after 3.5s dealt one tick and expired with three stolen.
		if effect.kind == "dot" then
			existing.duration = effect.duration
			existing.ticksDealt = 0
			existing.timeToTick = math.max(effect.interval or 1, 0.001)
			return events
		end

		-- A refresh of a STAT effect is the opposite: the engine mirrors the stat, so it has to be
		-- told the previous application is over before the new one begins. Exactly two events, both
		-- of which the adapter already handles. Without the effectEnded, the adapter inserted a
		-- second entry and only ever received one removal: the list never emptied and the character
		-- kept the multiplier permanently.
		local previousMultiplier = existing.multiplier
		table.insert(events, {
			kind = "effectEnded",
			targetId = id,
			target = target,
			stat = existing.stat,
			multiplier = previousMultiplier,
			refreshed = true,
			abilityId = abilityId,
		})
		table.insert(events, {
			kind = effect.kind == "debuff" and "debuff" or "buff",
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
		-- The declared duration, kept as well as `remaining`: the tick cap is derived from it, and
		-- deriving it from a value that drains would cap the total at zero on the first tick.
		duration = effect.duration,
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
			if instance.kind == "dot" and isAlive(instance.target) then
				instance.timeToTick = instance.timeToTick - dt
				-- A while, not an if: a long tick must not swallow a tick of damage. Losing one on a
				-- lag spike is the phantom-timer bug with hit points instead of seconds.
				--
				-- But the catch-up window is BOUNDED by what the effect has left. Without that, one
				-- long dt drained a whole duration at once: a 2s/1s effect asked to advance 5 seconds
				-- dealt five ticks in a single frame, while the comment above promised two. The cap
				-- is computed from `remaining` BEFORE the drain below, which is the window that
				-- actually exists. The interval is floored away from zero so a bad definition cannot
				-- divide by it.
				local interval = math.max(instance.interval or 1, 0.001)
				-- The cap is the total the DURATION allows, not the ticks that fit in the window.
				-- A window cap of floor(remaining/interval) is a tick too tight: with 0.99s left on
				-- a 1s interval it is 0, which blocks a tick that fell due legitimately one frame
				-- before the expiry. Counting from the start cannot drift, because the schedule is
				-- fixed and the count is not.
				local maxTicks = math.floor((instance.duration or 0) / interval)
				while instance.timeToTick <= 0 and (instance.ticksDealt or 0) < maxTicks do
					table.insert(events, {
						kind = "damage",
						target = instance.target,
						amount = instance.amount,
						dot = true,
						abilityId = instance.abilityId,
					})
					instance.timeToTick = instance.timeToTick + interval
					instance.ticksDealt = (instance.ticksDealt or 0) + 1
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

### `src/server/EffectAdapter.luau`

*The only file in this kit that cannot be tested without an engine, which is why it is the only one
with no logic in it — every rule it could have imagined already lives in a module with a suite.*

`git hash-object src/server/EffectAdapter.luau` -> `769fbe81cd66` -> `b555bbccf124`

```lua
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
	-- [character] = { base = WalkSpeed before the first effect, multipliers = { running ones } }
	--
	-- A LIST, and this is the third attempt at it. A single flag lost the base on the first expiry.
	-- A counter still restored the base on the first expiry while a second effect was still running,
	-- because a counter says how many are left but not what they ask for. With the list, the speed
	-- is recomputed from what is actually running: two 2x effects are 4x, and when one expires the
	-- other's multiplier is still in the list and the character keeps its effect.
	--
	-- A Studio check caught both of the earlier versions; the pure suite could not, because this is
	-- engine state that lives in the seam between the modules.
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

-- Recomputes WalkSpeed from the base and everything currently running. Called after any change,
-- so there is exactly one place that writes this number and no arithmetic to keep in sync.
function EffectAdapter:recomputeSpeed(character, humanoid)
	local entry = self.speedEffects[character]
	if entry == nil then
		return
	end
	if #entry.multipliers == 0 then
		-- Nothing running: back to what the character had, and forget the entry.
		humanoid.WalkSpeed = entry.base
		self.speedEffects[character] = nil
		return
	end

	-- The product of what is running. Two 2x effects are 4x; a 2x and a 0.5x cancel out. A game
	-- that wants a different rule (the strongest wins, the last wins) composes before this layer,
	-- which is why the rule is written down here rather than implied.
	local combined = 1
	for _, multiplier in ipairs(entry.multipliers) do
		combined *= multiplier
	end
	humanoid.WalkSpeed = entry.base * combined
end

function EffectAdapter:applySpeedEffect(character, humanoid, multiplier)
	local entry = self.speedEffects[character]
	if entry == nil then
		-- The first effect remembers the speed the character had, so restoring needs nothing from
		-- the definition and survives any number of effects.
		entry = { base = humanoid.WalkSpeed, multipliers = {} }
		self.speedEffects[character] = entry
	end
	table.insert(entry.multipliers, multiplier or 1)
	self:recomputeSpeed(character, humanoid)
end

function EffectAdapter:removeSpeedEffect(character, humanoid, multiplier)
	local entry = self.speedEffects[character]
	if entry == nil then
		return false
	end

	-- Exactly the multiplier the ending event carried. There is no fallback: this layer does not
	-- decide, and "remove something anyway" is deciding. The EffectSystem announces the value it is
	-- ending, and a game that ends an effect without one of those gets a no-op rather than a guess.
	local index = table.find(entry.multipliers, multiplier)
	if index == nil then
		return false
	end
	table.remove(entry.multipliers, index)

	self:recomputeSpeed(character, humanoid)
	return true
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

	-- An end is cleanup, and cleanup cannot depend on being alive: a character that dies with a
	-- speed effect running never gets its entry removed otherwise, and the adapter leaks a record
	-- of a character that is gone. Handled before the health guard for that reason.
	if event.kind == "effectEnded" then
		if humanoid == nil or event.stat ~= "speed" then
			return false
		end
		return self:removeSpeedEffect(character, humanoid, event.multiplier)
	end

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
```

### `tests/EffectSystemSpec.luau`

*31 cases. The ones worth reading: the long tick that must not swallow ticks, and the three stacking policies.*

`git hash-object tests/EffectSystemSpec.luau` -> `32ce5e751e67` -> `1b303df9c83a`

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

T("a dt longer than the whole duration cannot deal more ticks than the duration allows", function()
	-- The case the suite never crossed: every DoT case ran with dt smaller than remaining, which is
	-- exactly the gap. A 2s/1s effect owes two ticks, and a 5-second frame must not mint five.
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 2, 1) }, "POISON", dummy())
	local events = system:advance(5)
	local ticks = 0
	for _, event in ipairs(events) do
		if event.kind == "damage" then
			ticks += 1
		end
	end
	assert(ticks == 2, "a 2s effect with a 1s interval owes 2 ticks, dealt " .. ticks)
end)

T("a huge dt on a long DoT still stops at the duration", function()
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local events = system:advance(1000)
	local ticks = 0
	for _, event in ipairs(events) do
		if event.kind == "damage" then
			ticks += 1
		end
	end
	assert(ticks == 4, "4 seconds at 1s interval is 4 ticks, dealt " .. ticks)
end)

T("the normal catch-up still works when dt is shorter than the duration", function()
	-- The cap must not break the case it was added alongside: 3.5s of a 4s effect is still 3 ticks.
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local events = system:advance(3.5)
	local ticks = 0
	for _, event in ipairs(events) do
		if event.kind == "damage" then
			ticks += 1
		end
	end
	assert(ticks == 3, "3.5s at a 1s interval is 3 ticks, dealt " .. ticks)
end)

T("refreshing a DoT emits NOTHING, and extends the duration silently", function()
	-- It used to emit a damage event with amount = nil, which the adapter turns into
	-- TakeDamage(nil). The Studio check missed it because it never refreshed a DoT.
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	system:advance(0.5)
	local events = apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	assert(#events == 0, "a refresh has nothing to report, got " .. #events)

	local active = system:getActiveFor("DUMMY")
	assert(#active == 1, "and must not leave two instances")
	assert(active[1].remaining > 3.9, "with the duration back at full")
end)

T("a dead target stops receiving ticks", function()
	-- The registration guard stopped a corpse being poisoned. This is the other half: a target that
	-- dies with effects running must stop producing damage for them.
	local system = EffectSystem.new(Config)
	local victim = dummy()
	apply(system, { dot(6, 4, 1) }, "POISON", victim)
	system:advance(0.5)
	victim.alive = false
	local events = system:advance(1.5)
	for _, event in ipairs(events) do
		assert(event.kind ~= "damage", "a dead target must not be dealt damage")
	end
end)

T("refreshing a DoT resets its tick budget instead of spending the old one", function()
	-- The bug the previous refresh test could not see: it advanced 0.5s, refreshed, and checked
	-- remaining — never advancing AFTER the refresh, which is where the budget is spent.
	local system = EffectSystem.new(Config)
	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	system:advance(3.5) -- three of the four ticks spent

	apply(system, { dot(6, 4, 1) }, "POISON", dummy())
	local events = system:advance(4)
	local ticks = 0
	for _, event in ipairs(events) do
		if event.kind == "damage" then
			ticks += 1
		end
	end
	assert(ticks == 4, "a refreshed 4s effect owes 4 more ticks, dealt " .. ticks)
end)

T("refreshing a stat effect announces the end of the old one before the new one", function()
	-- One event was not enough: the adapter mirrors the stat, so a refresh that stayed silent left
	-- an entry in its list that no later expiry ever removed — a permanent speed change.
	local system = EffectSystem.new(Config)
	apply(system, { buff(1.5, 5) }, "HASTE", dummy())
	local events = apply(system, { buff(1.5, 5) }, "HASTE", dummy())
	assert(#events == 2, "a stat refresh is two events, got " .. #events)
	assert(events[1].kind == "effectEnded", "the end of the old application comes first")
	assert(events[1].multiplier == 1.5, "carrying the multiplier being ended")
	assert(events[2].kind == "buff", "and the new application follows")
	assert(system:hasActive("DUMMY", "HASTE"), "still one instance, refreshed")
	assert(#system:getActiveFor("DUMMY") == 1, "and not two")
end)

T("refreshing a debuff announces its end too", function()
	local system = EffectSystem.new(Config)
	local slow = { kind = "debuff", stat = "speed", multiplier = 0.5, duration = 4 }
	apply(system, { slow }, "SLOW", dummy())
	local events = apply(system, { slow }, "SLOW", dummy())
	assert(
		#events == 2 and events[1].kind == "effectEnded",
		"a debuff refresh is announced as well"
	)
	assert(events[2].kind == "debuff", "and re-applied as a debuff")
end)

return T.report()
```

## How to test it

```
luau tests/run.luau          # 172 cases across 5 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

The adapter has no suite, and that is the design rather than an omission: it cannot be exercised
without an engine. What it has instead is a **check in Studio**, run against a real Humanoid.

## The Studio check

Instead of starting a playtest, the check builds a throwaway character, exercises every event the
adapter translates, and then destroys it — leaving the place exactly as it was found:

```
ADAPTADOR CARGADO desde ServerScriptService ✓
  describe    -> alive=true  health=100/100  pos=0, 10, 0
  damage 30   -> Health = 70
  heal 100    -> Health = 100  (cap at MaxHealth=100)
  buff x2     -> WalkSpeed = 32   (base was 16)
  effectEnded -> WalkSpeed = 16   (back to the base)
  dash 32     -> 0, 10, 0  ->  0, 10, -32
  throwaway model destroyed: true  (Workspace clean)
```

And a second check, for the case the first one could not see — **two speed effects running at once**,
through the real EffectSystem and the real adapter:

```
base WalkSpeed = 16
buff A x2   -> 32        one running
buff B x3   -> 96        two running: the product, 2 x 3 = 6
expires A   -> 48        B is still running, so 3x remains
expires B   -> 16        now, and only now, the base
live effects at the end: 0
throwaway model destroyed: true
```

And nothing was left behind: the model is destroyed and `Parent == nil` is checked before the
result is returned. The only change to the place was Rojo adding `EffectAdapter` under
`ServerScriptService.AbilityServer`.

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

And in the adapter, one decision worth recording: **a speed effect remembers the character's
original WalkSpeed**, so restoring on expiry is possible without a definition having to carry
it. Engine state, kept in the engine layer, which is why it is not in the EffectSystem.

## The numbers

- Tests: **172** across 5 suites — AbilityDefinitionSpec 42 · AbilitySpec 34 · AbilityManagerSpec 35 · ResourceManagerSpec 30 · EffectSystemSpec 31
- Lines: **2180 source + 2101 tests** = 4281 (the adapter is 236 of the source)
- Commits: **25**
- selene: 0 errors, 0 warnings · stylua: clean
- Studio check: passed twice, against a real Humanoid, with nothing left in the place

## What the review found, and what it cost to accept

Four findings, all correct, and the first two were the most embarrassing kind: **bugs the code's own
comments promised were fixed.**

| # | Finding | Shape |
|---|---------|-------|
| 1 | a DoT advanced by 5 seconds dealt 5 ticks instead of 2 — the catch-up window was unbounded | a claim the code did not keep |
| 2 | refreshing a DoT emitted a `damage` event with `amount = nil`, which reaches the adapter as `TakeDamage(nil)` | an event shaped like another one |
| 3 | two stacked speed buffs restored wrongly: the first expiry dropped the character to base while the second was still running | a rule that spans objects, in the layer that cannot see them |
| 4 | the pure system kept ticking for a target that died mid-effect | a guard on one path, not the other |

The comment on finding 1 read *"a 6-damage-per-second effect lasting two seconds owes two ticks"*,
and the code gave five on a large `dt`. The suite did not catch it because **every DoT case used a
`dt` smaller than `remaining`** — the window was never the constraint. The test that was supposed to
cover the catch-up used `dt = 3.5` against a duration of 4.

Finding 3 is the one with a lesson attached. It lives in **the seam between the two modules**: the
EffectSystem knows how many instances are running, the adapter knows what the engine needs, and
neither test suite crosses that line. The spec tests stacking without an adapter; the Studio check
tested the adapter without stacking. **The fix took three attempts** — a flag, then a counter, then
the list of multipliers it needed — and only the Studio check could tell them apart, because the
state being restored is engine state.

That is the honest limit of the pure/adapter split: it catches what lives on either side, not what
lives between them. The answer is not a cleverer split, it is **a check that crosses the seam**, and
that is what the second block above is.

## Round two of the same phase

The review found two more, and **both were introduced by the fixes of round one**:

| # | Finding | Shape |
|---|---------|-------|
| A | a refreshed DoT kept the spent tick budget, so a 4s effect refreshed after 3.5s dealt one tick and expired with three stolen | a counter that outlived what it counted |
| B | a refreshed speed buff left the multiplier permanent: the system stayed silent, the adapter inserted a second entry, and only one expiry ever arrived | an announcement one layer made and the other never heard |

Finding A's test is the lesson: the case for the refresh advanced 0.5s, refreshed, and checked
`remaining` — **never advancing after the refresh**, which is the only place the budget is spent.

Finding B needed a protocol, not a patch, and it is written into the refresh branch: **a DoT refresh
resets its timers silently; a stat refresh announces the end of the old application and then the new
one.** Two events, both of which the adapter already handled. The asymmetry is real and deliberate —
a DoT is timer state the engine cannot see, a stat is state the engine mirrors.

Both are the same shape this phase keeps producing: **a rule that lives between two layers, where
neither suite looks.**

## What is left in this phase

Nothing code-side. The phase is complete: the rules have a suite, the engine contact has a
check, and the stacking policy is validated at load against the module that owns it.

Known limitations, written down rather than hidden:

- **Only `speed` is translated** for buffs and debuffs. Any other stat is an event the game
  handles itself, because inventing a mapping would be deciding — the one thing the adapter is
  not allowed to do.
- **The dash is a single displacement**, not a motion over time. A smooth version needs a
  `LinearVelocity` for the duration, which belongs to the character/movement phase.
- **The `Baseplate` and `SpawnLocation` are untouched**, and Rojo will not remove them: the
  project describes `Workspace` without a `$path`, and that default means unknown instances
  are left alone. Adding a `$path` there later would start deleting what it does not describe.

## Still not verified

Five modules with suites, one adapter with a Studio check, and the same caveat at the end of
phase 4: **no full game boot**. Nothing here has been driven by a real player pressing a real
key — that arrives with the Bootstrap and the remote, in phase 5.
