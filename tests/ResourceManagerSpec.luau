--[[
	ResourceManagerSpec.luau — runs with `luau tests/ResourceManagerSpec.luau`. No Studio.

	The interesting case here is not "does mana go down". It is what happens when a cost names two
	pools and only one of them is short, because that is where a half-paid ability hides.
]]

local TestKit = require("./TestKit")
local Config = require("../src/shared/Config")
local ResourceManager = require("../src/shared/ResourceManager")

local T = TestKit.new("ResourceManager")

local function fresh(initial)
	return ResourceManager.new(Config, initial)
end

-- ===== the pools come from Config =====

T("every pool declared in Config exists, with its max and its starting value", function()
	local r = fresh()
	for name, spec in pairs(Config.RESOURCES) do
		local current, max = r:get(name)
		assert(current ~= nil, "pool '" .. name .. "' must exist")
		assert(max == spec.max, "and carry its ceiling")
		assert(current == spec.start, "and start where Config says")
	end
end)

T("an unknown pool reports nil instead of throwing", function()
	local r = fresh()
	assert(r:get("honk") == nil, "get on a pool that does not exist is a question, not an error")
	assert(r:getCurrent("honk") == nil, "and so is getCurrent")
	assert(r:getMax("honk") == nil, "and getMax")
end)

T("a starting value can be injected, and is clamped into the pool", function()
	local r = fresh({ mana = 5 })
	assert(r:getCurrent("mana") == 5, "the injected value must win")
	local over = ResourceManager.new(Config, { mana = Config.RESOURCES.mana.max + 100 })
	assert(over:getCurrent("mana") == Config.RESOURCES.mana.max, "a value past the ceiling clamps")
	local under = ResourceManager.new(Config, { mana = -10 })
	assert(under:getCurrent("mana") == 0, "and one below zero clamps too")
end)

T("getPoolNames returns every declared pool, sorted", function()
	local names = fresh():getPoolNames()
	assert(#names == 2, "the kit declares mana and stamina, got " .. #names)
	assert(names[1] == "mana" and names[2] == "stamina", "and they come back in a stable order")
end)

-- ===== canPay =====

T("an absent or empty cost is always payable", function()
	local r = fresh()
	-- An ability with no cost must not force the caller to pass an empty table to prove it.
	assert(r:canPay(nil), "nil cost")
	assert(r:canPay({}), "empty cost")
end)

T("canPay accepts exactly the pool's worth, and refuses one unit short", function()
	local r = fresh({ mana = 25 })
	assert(r:canPay({ mana = 25 }), "the boundary must pass, or every cost is off by one")
	local ok, short = r:canPay({ mana = 26 })
	assert(not ok, "one more than you have is a refusal")
	assert(short == "mana", "and it must name the pool that is short, got " .. tostring(short))
end)

T("canPay names the pool that is short, not just 'not enough'", function()
	local r = fresh({ mana = 100, stamina = 0 })
	local ok, short = r:canPay({ mana = 10, stamina = 5 })
	assert(not ok, "stamina is empty")
	assert(short == "stamina", "and stamina is what must be reported")
end)

T("canPay refuses a cost naming a pool that does not exist", function()
	local r = fresh()
	local ok, short = r:canPay({ honk = 1 })
	assert(not ok, "there is no such pool")
	assert(short == "honk", "and the refusal must name it")
end)

T("canPay refuses a cost that is not a table", function()
	local ok = fresh():canPay("25 mana")
	assert(not ok, "a string is not a cost")
end)

T("canPay refuses a negative or non-numeric amount", function()
	local r = fresh()
	assert(not r:canPay({ mana = -5 }), "a negative cost is a refund in disguise")
	assert(not r:canPay({ mana = "lots" }), "and so is a string")
end)

-- ===== spend, and the invariant =====

T("spend deducts the cost", function()
	local r = fresh({ mana = 100 })
	local ok = r:spend({ mana = 25 })
	assert(ok, "the spend must succeed")
	assert(r:getCurrent("mana") == 75, "and deduct exactly 25")
end)

T("a cost across TWO pools where the second is short deducts NOTHING", function()
	-- The invariant. Deducting as you go would leave the player having paid the mana for an ability
	-- that was refused, and nothing in the log would say so.
	local r = fresh({ mana = 100, stamina = 3 })
	local ok, short = r:spend({ mana = 40, stamina = 10 })
	assert(not ok, "the spend must be refused")
	assert(short == "stamina", "naming stamina, got " .. tostring(short))
	assert(r:getCurrent("mana") == 100, "and mana must be untouched: all or nothing")
	assert(r:getCurrent("stamina") == 3, "with stamina untouched as well")
end)

T("a refused spend leaves every pool exactly as it was", function()
	local r = fresh({ mana = 10, stamina = 10 })
	local beforeMana, beforeStamina = r:getCurrent("mana"), r:getCurrent("stamina")
	r:spend({ mana = 5, stamina = 999 })
	assert(r:getCurrent("mana") == beforeMana, "mana unchanged")
	assert(r:getCurrent("stamina") == beforeStamina, "stamina unchanged")
end)

T("spending a nil cost succeeds and changes nothing", function()
	local r = fresh({ mana = 50 })
	assert(r:spend(nil), "a free ability must be spendable")
	assert(r:getCurrent("mana") == 50, "and cost nothing")
end)

T("spend can be called repeatedly down to exactly zero", function()
	local r = fresh({ mana = 50 })
	assert(r:spend({ mana = 25 }), "first")
	assert(r:spend({ mana = 25 }), "second")
	assert(r:getCurrent("mana") == 0, "and lands on zero, not below it")
	assert(r:spend({ mana = 1 }) == false, "a third attempt must fail")
	assert(r:getCurrent("mana") == 0, "without going negative")
end)

-- ===== restore, refill =====

T("restore adds to a pool and caps at its maximum", function()
	local r = fresh({ mana = 10 })
	assert(r:restore("mana", 30), "a restore must succeed")
	assert(r:getCurrent("mana") == 40, "and add what it was given")
	r:restore("mana", 1000)
	assert(
		r:getCurrent("mana") == Config.RESOURCES.mana.max,
		"an over-restore must cap, not overshoot"
	)
end)

T("restore refuses a negative amount instead of treating it as a spend", function()
	-- A heal with a sign error is a damage, and it should not happen quietly.
	local r = fresh({ mana = 50 })
	assert(not r:restore("mana", -20), "a negative restore is refused")
	assert(r:getCurrent("mana") == 50, "and nothing changes")
end)

T("restore refuses an unknown pool and a non-numeric amount", function()
	local r = fresh()
	assert(not r:restore("honk", 10), "no such pool")
	assert(not r:restore("mana", "lots"), "and a string is not an amount")
end)

T("refill takes every pool to its maximum", function()
	local r = fresh({ mana = 0, stamina = 0 })
	r:refill()
	for name, spec in pairs(Config.RESOURCES) do
		assert(r:getCurrent(name) == spec.max, "a respawn leaves pool '" .. name .. "' full")
	end
end)

-- ===== regeneration =====

T("advance regenerates at the configured rate", function()
	local r = fresh({ mana = 0 })
	r:advance(1)
	assert(
		math.abs(r:getCurrent("mana") - Config.RESOURCES.mana.regen) < 0.001,
		"one second must give exactly one second of regen"
	)
end)

T("regeneration is proportional to dt", function()
	local r = fresh({ mana = 0 })
	r:advance(0.5)
	assert(
		math.abs(r:getCurrent("mana") - Config.RESOURCES.mana.regen * 0.5) < 0.001,
		"half a second is half the regen"
	)
end)

T("regeneration stops at the maximum instead of overflowing", function()
	local r = fresh()
	r:advance(1000)
	assert(r:getCurrent("mana") == Config.RESOURCES.mana.max, "a long tick must cap, not climb")
end)

T("a nonsense dt regenerates nothing", function()
	local r = fresh({ mana = 0 })
	r:advance(0)
	r:advance(-5)
	r:advance("soon")
	assert(r:getCurrent("mana") == 0, "none of those are a duration")
end)

T("regeneration does not touch pools already at their maximum", function()
	local r = fresh()
	local before = r:getCurrent("mana")
	r:advance(3)
	assert(r:getCurrent("mana") == before, "a full pool stays full")
end)

-- ===== the snapshot =====

T("toState matches the resources shape Config declares, for every pool", function()
	-- The drift check, same pattern as the manager's: Config writes the shape down once, and this
	-- fails if the two disagree instead of letting them diverge in silence.
	local r = fresh({ mana = 40 })
	local state = r:toState()
	assert(type(state) == "table", "the slice is a table")

	for _, name in ipairs(r:getPoolNames()) do
		local pool = state[name]
		assert(pool ~= nil, "pool '" .. name .. "' must appear in the snapshot")
		assert(type(pool.current) == "number", "with a numeric current")
		assert(type(pool.max) == "number", "and a numeric max, because the client draws both ends")
	end
	assert(state.honk == nil, "and nothing that is not a pool")
end)

T("the snapshot is a copy, not a view: writing to it does not change the pools", function()
	local r = fresh({ mana = 40 })
	local state = r:toState()
	state.mana.current = 999
	assert(r:getCurrent("mana") == 40, "a snapshot the client could write through is a bug")
end)

-- ===== independence =====

T("two managers do not share pools", function()
	local firstManager = fresh({ mana = 100 })
	local secondManager = fresh({ mana = 100 })
	firstManager:spend({ mana = 60 })
	assert(secondManager:getCurrent("mana") == 100, "the second owner is untouched")
end)

T("a string starting value is refused, matching canPay's strictness", function()
	-- Half-indulgent is worse than either extreme: a module that rejects "50" as a cost and accepts
	-- it as a starting value is inconsistent, and it is inconsistent in the untested direction.
	local ok = pcall(function()
		return ResourceManager.new(Config, { mana = "50" })
	end)
	assert(not ok, "a string must not be quietly converted")
end)

T("restore with zero is legal and changes nothing", function()
	-- The guard is < 0, not <= 0. Worth pinning so the boundary is a decision rather than a hole
	-- somebody later closes by accident.
	local r = fresh({ mana = 40 })
	assert(r:restore("mana", 0), "zero is a valid amount")
	assert(r:getCurrent("mana") == 40, "that changes no pool")
end)

T("getOwnerResources hands back the live pools in the shape an owner is read from", function()
	-- Ability:canActivate reads owner.resources[pool].current. This is that, so the manager's own
	-- affordability check is the only one needed.
	local r = fresh({ mana = 100 })
	local pools = r:getOwnerResources()
	assert(pools.mana.current == 100, "the shape must match what canActivate reads")
	assert(pools.mana.max == Config.RESOURCES.mana.max, "including the max")

	r:spend({ mana = 40 })
	assert(pools.mana.current == 60, "and it must be live, not a snapshot of the pools")

	local fakeOwner = { alive = true, resources = pools }
	local Ability = require("../src/shared/Ability")
	local ability = Ability.new({
		id = "X",
		displayName = "X",
		cost = { mana = 30 },
		cooldown = 0,
		castTime = 0,
		range = 0,
		effects = { { kind = "damage", amount = 1 } },
	}, Config)
	assert(ability:canActivate(fakeOwner), "and an ability must be able to read it directly")
end)

return T.report()
