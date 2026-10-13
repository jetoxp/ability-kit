# Phase 2 — the `Ability` state machine

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase delivers, and why it is shaped this way

Phase 2 is one module: an ability instance that owns its own timing. Four states, and the whole
design is in how they connect:

```
idle ──startActivation──> casting ──cast completes──> active ──same instant──> cooldown ──> idle
  └────startActivation──> active  ──────────────────────┘
```

**`active` is an instant, not a duration.** It is the moment the effects are handed to the caller,
and then the cooldown begins. That buys one rule that is simple to state and easy to test:

> **Effects fire exactly once per activation.**

A DoT that fires twice because a tick ran late is damage nobody can explain, so the firing is a
one-way door: `advance` reports it, sets the cooldown, and leaves that state immediately.

### What this module deliberately does not know

That list is the design, more than the state diagram is:

- **How effects are applied.** That is the EffectSystem, phase 4. Here, `advance` returns the
  definition's effects and lets the caller deal with them.
- **What mana actually is**, beyond "do I have enough". Spending belongs to the ResourceManager,
  and it happens in one place instead of in every ability.
- **Who the owner is.** `canActivate` takes any table with `alive` and `resources`. A character, a
  test double, an NPC — if it has those two fields it can own an ability. That looseness is what
  makes every rule in this file testable in a terminal.
- **The global cooldown.** It belongs to the player, not to one ability, so it lives in the manager
  (phase 3).

### The two decisions worth arguing about

**1. Refusals return a reason key, not a boolean and not a sentence.** `canActivate` returns
`(false, "notEnoughResources")`, and that key indexes `Config.MESSAGES`. Inventing the player-facing
sentence at the call site is how a framework ends up hardcoding one language.

**2. `advance` returns `(fired, effects)` instead of applying anything.** The alternative — this
module reaching out and applying damage — would make the state machine untestable without an engine,
which is the mistake this kit has already paid for once.

## The file structure

```
src/shared/
  Ability.luau          the state machine
  AbilityDefinition.luau
  Config.luau
  DefaultLoadout.luau
  abilities/            (Fireball, Poison, Dash, Heal, init)
tests/
  AbilitySpec.luau      33 cases
  AbilityDefinitionSpec.luau
  TestKit.luau  run.luau
```

## The code

*The state after review — this is what is in Studio and in git today.*

### `src/shared/Ability.luau`

*The whole phase. Read the header comment first: the states, and what this module refuses to know.*

```lua
--[[
	Ability.luau — one ability instance, as a state machine.

	The four states are the whole design:

	    idle ──startActivation──> casting ──cast completes──> cooldown ──> idle
	      └────startActivation──> active  ──the same instant──> cooldown ──> idle

	`active` is a single instant, not a duration. It is the moment the effects are handed to the
	caller, and then the cooldown begins. That keeps one rule simple to state and easy to test:
	**effects fire exactly once per activation**. A DoT that fires twice because a tick ran late
	is the kind of bug that shows up as damage nobody can explain, so the firing is a one-way door:
	`advance` reports it, and the state leaves that instant immediately.

	What this module deliberately does NOT know:
	  - how effects are applied (that is the EffectSystem, phase 4)
	  - what mana is, beyond "do I have enough" (ResourceManager, phase 4)
	  - who the owner is, beyond what `canActivate` is told (a plain table, which is what makes
	    every rule here testable in a terminal with no Roblox running)
	  - the global cooldown, which is a property of the player, not of one ability (phase 3)

	No requires: everything arrives through `new`. Same reason as AbilityDefinition — this file
	has to load in a plain Luau interpreter, and the tests are the point.
]]

local Ability = {}
Ability.__index = Ability

Ability.STATES = {
	idle = "idle",
	casting = "casting",
	active = "active",
	cooldown = "cooldown",
}

--[[
	Creates an instance from a validated definition and the config.

	The definition is NOT copied: two players with the same ability share one table, and nothing in
	here writes to it. All the mutable state lives on the instance. If that ever stops being true,
	it will be because someone put mutable state in a definition, which the validator cannot see.
]]
function Ability.new(definition, config)
	assert(type(definition) == "table", "Ability.new needs a definition")
	assert(type(config) == "table", "Ability.new needs the config")

	local self = setmetatable({}, Ability)
	self.definition = definition
	self.config = config
	self:reset()
	return self
end

-- Back to a fresh instance. Used on spawn and on respawn, so a player who dies mid-cooldown does
-- not come back with the cooldown still running.
function Ability:reset()
	self.state = Ability.STATES.idle
	self.cooldownRemaining = 0
	self.castRemaining = 0
	self.castOvershoot = 0
	self.effectsEmitted = false
	return self
end

function Ability:getDefinition()
	return self.definition
end

function Ability:getState()
	return self.state
end

function Ability:getCooldownRemaining()
	return self.cooldownRemaining
end

function Ability:getCastRemaining()
	return self.castRemaining
end

-- 0 to 1, for a progress bar. 1 when there is nothing to cast (an instant ability has no
-- progress to draw, and returning 0 there would make the UI look stuck).
function Ability:getCastProgress()
	local total = self.definition.castTime or 0
	if total <= 0 then
		return 1
	end
	return math.clamp(1 - (self.castRemaining / total), 0, 1)
end

function Ability:isReady()
	return self.state == Ability.STATES.idle
end

--[[
	Whether this ability could be activated right now, and if not, why not.

	Returns a reason drawn from Config.MESSAGES rather than a boolean, because the caller has to
	explain the refusal to a player and inventing that string at the call site is how a kit ends up
	hardcoding a language. The reason is for the LOG and for the UI; it is never an error.

	`owner` is any table with `alive` and `resources`:
	    { alive = true, resources = { mana = { current = 40, max = 100 } } }
	Deliberately loose. A character, a dummy in a test, a NPC — if it has those two fields, it can
	own an ability, and none of that requires Roblox to exist.
]]
function Ability:canActivate(owner)
	if self.state == Ability.STATES.casting then
		return false, "alreadyCasting"
	end
	if self.state ~= Ability.STATES.idle then
		-- Covers cooldown and the single active instant. Reaching active from outside is not
		-- possible through the public surface, but a state machine that only checks the states it
		-- expects is the one that gets stuck.
		return false, "abilityOnCooldown"
	end
	if owner == nil or owner.alive == false then
		return false, "invalidTarget"
	end

	local cost = self.definition.cost
	if cost ~= nil then
		local resources = owner.resources
		if type(resources) ~= "table" then
			return false, "notEnoughResources"
		end
		for pool, amount in pairs(cost) do
			local available = resources[pool]
			if
				type(available) ~= "table"
				or type(available.current) ~= "number"
				or available.current < amount
			then
				return false, "notEnoughResources"
			end
		end
	end

	return true, nil
end

-- Spends nothing itself. It reports what the activation costs and lets the caller take it, so the
-- deduction happens in one place (the ResourceManager) instead of in every ability.
function Ability:getCost()
	return self.definition.cost or {}
end

--[[
	Begins the activation. The caller must have checked canActivate first; this trusts that.

	Two entry points on purpose:
	  - a cast time greater than zero enters `casting` and waits to be advanced
	  - anything else enters `active` immediately, and the very next `advance` reports the firing
	Not collapsing these into "fire now" is what lets the interrupt path exist at all.
]]
function Ability:startActivation()
	if self.state ~= Ability.STATES.idle then
		return false
	end

	local castTime = self.definition.castTime or 0
	if castTime > 0 then
		self.state = Ability.STATES.casting
		self.castRemaining = castTime
	else
		self.state = Ability.STATES.active
		self.castRemaining = 0
	end
	self.effectsEmitted = false
	return true
end

--[[
	Advances the machine by `dt` seconds.

	Returns two values that say whether the effects should be applied now:
	    fired  : boolean
	    effects: the definition's effects, or nil

	The caller applies them. This module has no idea what a damage effect is, which is what keeps
	it loadable and testable outside Studio.

	A cast that completes fires on the SAME call that ends it, so no tick is lost and no tick is
	repeated: `effectsEmitted` closes the door behind the single firing.
]]
function Ability:advance(dt)
	if type(dt) ~= "number" or dt <= 0 then
		return false, nil
	end

	-- Cooldowns run down in every state: a cooldown that only ticks while idle would stretch
	-- whenever the player used something else.
	if self.cooldownRemaining > 0 then
		self.cooldownRemaining = math.max(0, self.cooldownRemaining - dt)
	end

	if self.state == Ability.STATES.casting then
		self.castRemaining = self.castRemaining - dt
		if self.castRemaining <= 0 then
			-- Keep the overshoot instead of clamping it away. On a normal tick it is microseconds;
			-- on a lag spike it is seconds, and dropping them starts the cooldown at full value
			-- while real time has already passed. The result is a cooldown that is longer than it
			-- says, only sometimes, which is the worst way for a number to be wrong.
			self.castOvershoot = -self.castRemaining
			self.castRemaining = 0
			self.state = Ability.STATES.active
		end
	end

	-- idle means the cooldown finished: the state is derived from the timer rather than tracked
	-- twice, so the two can never disagree.
	if self.state == Ability.STATES.cooldown and self.cooldownRemaining <= 0 then
		self.state = Ability.STATES.idle
	end

	if self.state == Ability.STATES.active and not self.effectsEmitted then
		self.effectsEmitted = true
		self.state = Ability.STATES.cooldown
		-- The leftover of the tick that finished the cast is credited here, so a hitch cannot
		-- silently lengthen the wait.
		self.cooldownRemaining = math.max(0, (self.definition.cooldown or 0) - self.castOvershoot)
		self.castOvershoot = 0
		if self.cooldownRemaining <= 0 then
			self.state = Ability.STATES.idle
		end
		return true, self.definition.effects
	end

	return false, nil
end

--[[
	Cancels a cast in progress. Returns whether anything was cancelled, so a caller can decide
	whether it is worth telling the player.

	Calling this on an ability that is not casting is not an error: damage arrives while idle all
	the time, and the effect system should be able to call this unconditionally.
]]
function Ability:interrupt(reason)
	if self.state ~= Ability.STATES.casting then
		return false, nil
	end

	self.state = Ability.STATES.idle
	self.castRemaining = 0
	self.effectsEmitted = false

	-- A cancelled cast costs nothing and goes on no cooldown. Charging for a cast that never
	-- happened is the kind of thing players notice and never forgive.
	-- The reason comes from inside the kit, but a caller can pass anything. Falling back keeps a
	-- refusal explainable: a nil here reaches the player as an empty message and reads as a bug.
	local message = self.config.MESSAGES[reason or "castInterrupted"]
		or self.config.MESSAGES.castInterrupted
	return true, message
end

--[[
	The snapshot piece the server replicates. Deliberately small: the client needs to draw a bar
	and a cooldown sweep, and giving it anything more is giving an exploiter a map.

	Note what is absent: the cost, the effects, the damage. The client is told about the frame of
	the ability, never about its consequences.
]]
function Ability:toState()
	return {
		id = self.definition.id,
		state = self.state,
		cooldown = self.cooldownRemaining,
		cast = self.castRemaining,
	}
end

return Ability
```

### `tests/AbilitySpec.luau`

*33 cases: every transition, every guard, the once-only firing, the dt credit, and the boundary.*

```lua
--[[
	AbilitySpec.luau — runs with `luau tests/AbilitySpec.luau`. No Studio.
	The state machine is the part of a kit that is easiest to get subtly wrong, so it gets the
	most cases: every transition, every guard, and the one invariant that matters most.
]]

local TestKit = require("./TestKit")
local Config = require("../src/shared/Config")
local Ability = require("../src/shared/Ability")

local T = TestKit.new("Ability")

-- An instant ability: no cast, a cooldown, a cost.
local function instant()
	return {
		id = "FLASH",
		displayName = "Flash",
		cost = { mana = 25 },
		cooldown = 3,
		castTime = 0,
		range = 0,
		effects = { { kind = "damage", amount = 30 } },
	}
end

-- A cast ability: 1 second, interruptible.
local function slow()
	return {
		id = "SLOW_CAST",
		displayName = "Slow Cast",
		cost = { mana = 40 },
		cooldown = 8,
		castTime = 1,
		range = 0,
		effects = { { kind = "heal", amount = 45 } },
	}
end

local function ownerWith(mana, alive)
	return {
		alive = alive ~= false,
		resources = { mana = { current = mana or 100, max = 100 } },
	}
end

local function newAbility(definition)
	return Ability.new(definition or instant(), Config)
end

-- ===== the lifecycle =====

T("a new ability starts idle, ready, and off cooldown", function()
	local a = newAbility()
	assert(a:getState() == Ability.STATES.idle, "should be idle")
	assert(a:isReady(), "and ready")
	assert(a:getCooldownRemaining() == 0, "and off cooldown")
end)

T("an instant ability fires on the first advance, with its effects", function()
	local a = newAbility()
	a:startActivation()
	local fired, effects = a:advance(0.05)
	assert(fired, "an instant ability must fire on the next tick")
	assert(effects == a:getDefinition().effects, "and hand over the definition's effects")
end)

T("the effects fire exactly once, however many ticks run", function()
	-- The invariant. A DoT applied twice is damage nobody can explain, so the firing is one-way.
	local a = newAbility()
	a:startActivation()
	local firedCount = 0
	for _ = 1, 20 do
		local fired = a:advance(0.1)
		if fired then
			firedCount += 1
		end
	end
	assert(firedCount == 1, "fired " .. firedCount .. " times, must be exactly 1")
end)

T("an instant ability's cooldown starts when it fires, not before", function()
	local a = newAbility()
	a:startActivation()
	assert(a:getCooldownRemaining() == 0, "nothing is on cooldown before the effect lands")
	a:advance(0.05)
	assert(a:getCooldownRemaining() == 3, "and the full cooldown after it")
	assert(a:getState() == Ability.STATES.cooldown, "the tick that fires must leave it on cooldown")
end)

T("a cast ability enters casting and does not fire until the cast completes", function()
	local a = newAbility(slow())
	a:startActivation()
	assert(a:getState() == Ability.STATES.casting, "should be casting")

	local fired = a:advance(0.4)
	assert(not fired, "0.4s into a 1s cast must not fire")
	assert(a:getState() == Ability.STATES.casting, "and must still be casting")
	assert(a:getCastRemaining() > 0.5, "with time left")
end)

T("the cast completes and fires on the same tick that ends it", function()
	local a = newAbility(slow())
	a:startActivation()
	a:advance(0.6)
	local fired, effects = a:advance(0.5)
	assert(fired, "the tick that finishes the cast must fire, not the one after")
	assert(effects ~= nil, "the firing must hand over the effects")
	assert(a:getState() == Ability.STATES.cooldown, "and go straight to cooldown")
end)

T("the cooldown runs out and the ability returns to idle", function()
	local a = newAbility()
	a:startActivation()
	a:advance(0.05)
	a:advance(3)
	assert(a:getState() == Ability.STATES.idle, "after the cooldown, idle again")
	assert(a:isReady(), "and ready")
end)

T("the cooldown ticks while casting, so it never stretches", function()
	local a = newAbility(slow())
	a:startActivation()
	a:advance(0.5)
	assert(a:getState() == Ability.STATES.casting, "0.4s into a 1s cast is still casting")
	-- Put it on cooldown by hand, then keep casting: the timer must still move.
	a.cooldownRemaining = 5
	a:advance(0.2)
	assert(a:getCooldownRemaining() < 5, "a cooldown that only ticks while idle stretches")
end)

T("a zero-cooldown ability returns to idle the moment it fires", function()
	local def = instant()
	def.cooldown = 0
	local a = newAbility(def)
	a:startActivation()
	a:advance(0.05)
	assert(a:getState() == Ability.STATES.idle, "no cooldown means ready again immediately")
end)

-- ===== the guards =====

T("canActivate says yes, with no reason, when everything is in order", function()
	local ok, reason = newAbility():canActivate(ownerWith(100))
	assert(ok, "should be activatable")
	assert(reason == nil, "a success carries no reason")
end)

T("canActivate refuses while on cooldown, and says which", function()
	local a = newAbility()
	a:startActivation()
	a:advance(0.05)
	local ok, reason = a:canActivate(ownerWith(100))
	assert(not ok, "on cooldown is a refusal")
	assert(reason == "abilityOnCooldown", "got: " .. tostring(reason))
	assert(Config.MESSAGES[reason] ~= nil, "the reason must be a key Config can translate")
end)

T("canActivate refuses while already casting, and says which", function()
	local a = newAbility(slow())
	a:startActivation()
	local ok, reason = a:canActivate(ownerWith(100))
	assert(not ok, "a cast in progress cannot be started again")
	assert(reason == "alreadyCasting", "got: " .. tostring(reason))
end)

T("canActivate refuses without enough mana", function()
	local ok, reason = newAbility():canActivate(ownerWith(24))
	assert(not ok, "24 mana cannot pay a cost of 25")
	assert(reason == "notEnoughResources", "got: " .. tostring(reason))
end)

T("canActivate accepts exactly enough mana", function()
	local ok = newAbility():canActivate(ownerWith(25))
	assert(ok, "the boundary has to pass, or the cost is off by one")
end)

T("canActivate refuses a cost naming a pool the owner does not have", function()
	local def = instant()
	def.cost = { stamina = 10 }
	local ok, reason = newAbility(def):canActivate(ownerWith(100))
	assert(not ok, "having mana is not having stamina")
	assert(reason == "notEnoughResources", "a cost in a pool the owner lacks is a refusal")
end)

T("canActivate refuses a dead owner, and an absent one", function()
	local a = newAbility()
	local ok, reason = a:canActivate(ownerWith(100, false))
	assert(not ok, "the dead cannot cast")
	assert(reason == "invalidTarget", "got: " .. tostring(reason))

	local ok2 = a:canActivate(nil)
	assert(not ok2, "no owner is a refusal, not a crash")
end)

T("canActivate refuses when the owner has no resources table at all", function()
	local ok, reason = newAbility():canActivate({ alive = true })
	assert(not ok, "no resources means no resources")
	assert(reason == "notEnoughResources", "having no resources table means no resources")
end)

T("a free ability needs no resources", function()
	local def = instant()
	def.cost = nil
	local ok = newAbility(def):canActivate({ alive = true })
	assert(ok, "an ability with no cost must not require a resource table")
	assert(next(newAbility(def):getCost()) == nil, "and getCost must return an empty table")
end)

-- ===== the interrupt =====

T("interrupting a cast returns a message drawn from Config", function()
	local a = newAbility(slow())
	a:startActivation()
	local cancelled, message = a:interrupt("castInterrupted")
	assert(cancelled, "a cast in progress must be cancellable")
	assert(message == Config.MESSAGES.castInterrupted, "and carry the translatable message")
end)

T("interrupting a cast costs nothing and goes on no cooldown", function()
	local a = newAbility(slow())
	a:startActivation()
	a:interrupt()
	assert(a:getState() == Ability.STATES.idle, "back to idle")
	assert(a:getCooldownRemaining() == 0, "charging for a cast that never happened is unforgivable")
end)

T("an interrupted cast never fires", function()
	local a = newAbility(slow())
	a:startActivation()
	a:interrupt()
	local fired = a:advance(5)
	assert(not fired, "a cancelled cast must not land later")
end)

T("interrupting while idle is a no-op, not an error", function()
	local ok, message = newAbility():interrupt()
	assert(not ok, "nothing was cancelled")
	assert(message == nil, "a no-op interrupt carries no message")
end)

T("interrupting during a cooldown leaves the cooldown alone", function()
	local a = newAbility()
	a:startActivation()
	a:advance(0.05)
	local before = a:getCooldownRemaining()
	local ok = a:interrupt()
	assert(not ok, "there is no cast to cancel")
	assert(a:getCooldownRemaining() == before, "and the cooldown must survive untouched")
end)

-- ===== the snapshot =====

T("toState carries the four fields the client needs and nothing else", function()
	local a = newAbility()
	a:startActivation()
	a:advance(0.05)
	local state = a:toState()
	assert(state.id == "FLASH", "the snapshot must carry the id")
	assert(state.state == Ability.STATES.cooldown, "and the state")
	assert(state.cooldown > 0, "the client draws the sweep from this")
	assert(state.cast ~= nil, "and the cast timer")
	assert(state.cost == nil, "the client must not be told the cost")
	assert(state.effects == nil, "nor the effects: that is a map for an exploiter")
	assert(state.definition == nil, "nor the definition itself")
end)

T("getCastProgress reports 1 for an instant ability and a fraction for a cast", function()
	local instantAbility = newAbility()
	assert(instantAbility:getCastProgress() == 1, "nothing to cast, nothing to draw")

	local a = newAbility(slow())
	a:startActivation()
	assert(a:getCastProgress() == 0, "at the start")
	a:advance(0.5)
	local halfway = a:getCastProgress()
	assert(halfway > 0.4 and halfway < 0.6, "halfway through a 1s cast, got " .. halfway)
end)

T("reset clears a cooldown and a cast in progress", function()
	local a = newAbility(slow())
	a:startActivation()
	a:advance(0.3)
	a:reset()
	assert(a:getState() == Ability.STATES.idle, "a respawn mid-cast must come back ready")
	assert(a:getCooldownRemaining() == 0, "and off cooldown")
	assert(a:getCastRemaining() == 0, "and with no cast left")
end)

T("two instances of the same definition do not share state", function()
	-- The definition is shared by design; the state must not be. If this ever fails, someone has
	-- put mutable state in a definition, where the validator cannot see it.
	local def = instant()
	local first = Ability.new(def, Config)
	local second = Ability.new(def, Config)
	first:startActivation()
	first:advance(0.05)
	assert(second:isReady(), "the second instance must still be fresh")
	assert(second:getCooldownRemaining() == 0, "and off cooldown")
	assert(def.cooldown == 3, "and the definition must not have been written to")
end)

T("a nonsense dt is refused instead of corrupting the timers", function()
	local a = newAbility()
	a:startActivation()
	local fired = a:advance(0)
	assert(not fired, "dt = 0 advances nothing")
	local fired2 = a:advance("soon")
	assert(not fired2, "and a string must not move anything either")
	assert(a:getCooldownRemaining() == 0, "timers untouched")
end)

T("interrupt falls back to the default message for a reason the config does not know", function()
	-- A caller can pass any string. A nil here reaches the player as an empty message and reads as
	-- a bug in a system that is working perfectly.
	local a = newAbility(slow())
	a:startActivation()
	local cancelled, message = a:interrupt("aReasonNobodyDefined")
	assert(cancelled, "the cast must still cancel")
	assert(
		message == Config.MESSAGES.castInterrupted,
		"and the player must get a sentence, not nil"
	)
end)

T("the leftover dt from the tick that finishes a cast is credited to the cooldown", function()
	-- 1.4s of dt against a 1.0s cast and an 8s cooldown. Losing the 0.4 puts the ability further
	-- from ready than it is, and only ever on a tick that ran long.
	local a = newAbility(slow())
	a:startActivation()
	local fired = a:advance(1.4)
	assert(fired, "the cast completes")
	assert(
		math.abs(a:getCooldownRemaining() - 7.6) < 0.001,
		"0.4s must be credited, got " .. a:getCooldownRemaining()
	)
end)

T("a lag spike does not mint cooldown out of nothing", function()
	-- The case that motivated the rule: a 3s hitch against a 1s cast. Without the credit the
	-- ability waits 2 seconds longer than the definition says, and never in a reproducible way.
	local a = newAbility(slow())
	a:startActivation()
	a:advance(3)
	assert(
		math.abs(a:getCooldownRemaining() - 6) < 0.001,
		"2s of overshoot must be credited, got " .. a:getCooldownRemaining()
	)
end)

T("a cast completing exactly on the boundary fires and leaves no negative timer", function()
	-- advance(castTime) exactly, where a <= versus < hides.
	local a = newAbility(slow())
	a:startActivation()
	local fired = a:advance(1)
	assert(fired, "a 1s advance on a 1s cast must complete it, not miss by a float hair")
	assert(a:getCastRemaining() == 0, "and leave no negative cast time")
	assert(
		math.abs(a:getCooldownRemaining() - 8) < 0.001,
		"with nothing to credit, the full cooldown stands, got " .. a:getCooldownRemaining()
	)
end)

T("startActivation twice does nothing the second time", function()
	local a = newAbility()
	assert(a:startActivation(), "the first call starts it")
	assert(not a:startActivation(), "the second must be refused, or the same ability fires twice")
	assert(a:getState() == Ability.STATES.active, "and the state must be untouched")
end)

return T.report()
```

## How to test it

```
luau tests/run.luau          # 73 cases across 2 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

**In Studio there is nothing to look at yet**, and that is expected: this module touches no
Roblox API, so the Luau interpreter exercises it exactly as well as Studio would. The engine
check matters when there is something to wire up, which is phase 3.

## What review found in this phase

Six findings, none critical, and — the useful part — each one has a shape:

| # | Finding | Shape |
|---|---------|-------|
| 1 | `interrupt` returned nil when the reason was not in `Config.MESSAGES` | a message that isn't there |
| 2 | the leftover `dt` from the tick that finished a cast was dropped, so a 3s hitch lost 2s of cooldown credit | time that goes missing, only sometimes |
| 3 | `veces`, `mitad`, `antes`, `uno`, `dos` — Spanish identifiers in a file whose own header says English | a convention that holds only if something enforces it |
| 4 | the case "refuses while already casting" carried the message *"the dead cannot cast"* | a test that points at the wrong bug |
| 5 | `startActivation` refuses a second call, and no case covered it | a public guard with no case |
| 6 | no case for `advance(castTime)` exactly | where a `<=` versus `<` hides |

And one more, found while fixing them — mine, and the one worth remembering:

> **the rename of `actual` to `available` was applied to the declaration and not to the usages.**
> `canActivate` read a variable that no longer existed, three selene errors, two red tests. The
> grep had already printed the leftover lines and I read them as a false positive because "it's
> what I just renamed". After a rename, every hit for the old name is real until proven otherwise.

Finding 2 is the one with teeth. On a normal tick the loss is microseconds; on a lag spike it is
seconds, and it makes a cooldown longer than the number it reports — a wrong value that only
appears sometimes, which is the hardest kind to ever reproduce from a bug report.

## The numbers

- Tests: **73** across 2 suites — -> 40 passed, 0 failed, of 40  |    -> 33 passed, 0 failed, of 33
- Lines: **975 source + 892 tests** = 1867
- Commits: **9**
- selene: 0 errors, 0 warnings · stylua: clean

## What is not here yet, on purpose

- **The global cooldown** and per-player state — phase 3, in the manager.
- **Spending the resources.** `canActivate` checks, `getCost` reports, and nobody deducts yet.
- **Anything wired to a player.** No remote, no Bootstrap, no character. Phases 3 and 5.

## Still not verified

Same caveat as phase 1, now covering two modules: **no full game boot**. There is no Bootstrap,
so nothing here has been exercised through the path a real player takes. What is verified is the
logic itself, exhaustively, and that it loads by the same `require` path the boot will use.
