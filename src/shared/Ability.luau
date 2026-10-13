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
		-- Covers cooldown, and the single `active` instant: a frame may advance by zero, leaving an
		-- ability that has started but not yet handed over its effects. The reason given is
		-- `abilityOnCooldown`, which is not literally true of `active` but is what the player
		-- experiences — the key does nothing right now — and it is the only refusal key a client
		-- already knows how to draw. Deliberate, and pinned by a case in AbilityManagerSpec.
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
	-- Defensive: advance() and reset() both leave this at zero, so today it is always zero here.
	-- Written anyway because the failure it prevents is the mirror of the one that was just fixed:
	-- a stale overshoot would be credited to the NEXT firing and shorten a cooldown by time that
	-- never passed. Unreachable is not the same as impossible.
	self.castOvershoot = 0
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

	-- A cancelled cast goes on no cooldown, and this module charges nothing for it — but "nothing"
	-- here is about the ABILITY: its own state and its cooldown. What the cast may already have cost
	-- the player in resources is not this module's business, and phase 5 decided it: the cost is paid
	-- at the activation, so an interrupted cast is a paid cast. See "An interrupted cast is a paid
	-- cast" in PHASE_5.md before changing either half of that.
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
