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
