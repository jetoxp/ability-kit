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
