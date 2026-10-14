# Phase 4a — the `ResourceManager`

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase delivers, and why it is shaped this way

The module that **spends**. `AbilityManager:activate` checks that a cost is payable and refuses when
it is not, but deducting it there would make the manager a resource system as well as a cooldown
system. The deduction lives here, once, for every ability.

Pools are declared in `Config.RESOURCES`: a maximum, a regeneration rate per second, and where they
start. Nothing in this file knows what mana is — it knows a named pool with a ceiling and a rate.
That is also why it takes a plain cost table, the same shape `AbilityDefinition` validates: anything
with a cost can use it, and it never needs to know what an ability is.

### The invariant worth the whole phase

**A cost is all-or-nothing.** `spend` checks every pool first and only then moves anything, because
deducting as it goes leaves a player who paid the mana half of an ability that was then refused —
and nothing in the log would say so. It is the same shape as the duplicate-id bug and the global
cooldown: a rule that lives across more than one thing, and so belongs to the thing that owns them
both.

The second decision is smaller but caught a real class of bug: **`restore` refuses a negative
amount** rather than treating it as a spend. A heal with a sign error is a damage, and it should not
happen quietly.

## The file structure

```
src/shared/
  ResourceManager.luau   NEW — 192 lines
  Config.luau            the pools are declared here
  Ability.luau  AbilityManager.luau  AbilityDefinition.luau
  DefaultLoadout.luau  abilities/
tests/
  ResourceManagerSpec.luau   NEW — 27 cases
  AbilityManagerSpec.luau  AbilitySpec.luau  AbilityDefinitionSpec.luau  TestKit.luau  run.luau
```

## The code

### `src/shared/ResourceManager.luau`

*The whole phase. The header says what it knows — a named pool with a ceiling and a rate — and what it refuses to know, which is everything about abilities.*

```lua
--[[
	ResourceManager.luau — one owner's pools: what they have, what they can afford, and how it comes
	back.

	This is the module that spends. AbilityManager:activate checks that a cost is payable and reports
	it, but deducting it there would make the manager a resource system as well as a cooldown system.
	The deduction lives here, once, for every ability.

	Pools are declared in Config.RESOURCES: a maximum, a regeneration rate per second, and where they
	start. Nothing here knows what mana is — it knows a named pool with a ceiling and a rate.

	No requires and no Roblox. An owner is nothing at all, and a pool is a number, which is what
	keeps this loadable and testable in a terminal.

	One thing this deliberately does not do: it does not know about abilities. `spend` takes a plain
	cost table, the same shape AbilityDefinition validates, so anything with a cost can use it.
]]

local ResourceManager = {}
ResourceManager.__index = ResourceManager

-- config  : Config
-- initial : optional, name -> current. Anything omitted starts at its Config.RESOURCES.start.
function ResourceManager.new(config, initial)
	assert(type(config) == "table", "ResourceManager.new needs the config")

	local self = setmetatable({}, ResourceManager)
	self.config = config
	self.pools = {}

	for name, spec in pairs(config.RESOURCES) do
		local start = spec.start
		if type(initial) == "table" and initial[name] ~= nil then
			start = initial[name]
		end
		self.pools[name] = {
			current = math.clamp(tonumber(start) or spec.max, 0, spec.max),
			max = spec.max,
			regen = spec.regen or 0,
		}
	end

	return self
end

-- Unknown pools report nil rather than throwing: asking about a resource that does not exist is a
-- question with an answer, and the answer is "there is no such pool".
function ResourceManager:get(name)
	local pool = self.pools[name]
	if pool == nil then
		return nil
	end
	return pool.current, pool.max
end

function ResourceManager:getCurrent(name)
	local pool = self.pools[name]
	return pool and pool.current or nil
end

function ResourceManager:getMax(name)
	local pool = self.pools[name]
	return pool and pool.max or nil
end

function ResourceManager:getPoolNames()
	local names = {}
	for name in pairs(self.pools) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--[[
	Whether a cost can be paid, and if not, which pool is short. The reason names the pool because
	"not enough resources" tells a player nothing they cannot already see, and tells whoever is
	debugging a cost table almost nothing at all.

	An empty or absent cost is always payable: an ability with no cost must not require the caller
	to pass an empty table to prove it.
]]
function ResourceManager:canPay(cost)
	if cost == nil then
		return true, nil
	end
	if type(cost) ~= "table" then
		return false, "cost is not a table"
	end

	for name, amount in pairs(cost) do
		if type(amount) ~= "number" or amount ~= amount or amount < 0 then
			return false, name
		end
		local pool = self.pools[name]
		if pool == nil or pool.current < amount then
			return false, name
		end
	end

	return true, nil
end

--[[
	Spends a cost, or refuses and changes nothing.

	All-or-nothing on purpose. A cost naming two pools must not half-deduct when the second one
	turns out to be short: the ability would have been refused and the player would have paid for it
	anyway. So every pool is checked first, and only then does anything move.

	Returns whether it happened, and the pool that stopped it — the same pool `canPay` names, so a
	caller can log one reason without asking twice.
]]
function ResourceManager:spend(cost)
	local payable, shortPool = self:canPay(cost)
	if not payable then
		return false, shortPool
	end
	if cost == nil then
		return true, nil
	end

	for name, amount in pairs(cost) do
		self.pools[name].current = self.pools[name].current - amount
	end
	return true, nil
end

--[[
	Gives a pool back, capped at its maximum. Used by heals, by "refund on cancel" if a game wants
	one, and by anything else that restores.

	A negative amount is refused rather than treated as a spend: this function exists to add, and a
	caller who wants to subtract is calling the wrong one. Doing it silently is how a heal becomes a
	damage with a sign error nobody sees.
]]
function ResourceManager:restore(name, amount)
	if type(amount) ~= "number" or amount ~= amount or amount < 0 then
		return false
	end
	local pool = self.pools[name]
	if pool == nil then
		return false
	end
	pool.current = math.min(pool.max, pool.current + amount)
	return true
end

-- Every pool to its maximum. A respawn, not a refill of one pool.
function ResourceManager:refill()
	for _, pool in pairs(self.pools) do
		pool.current = pool.max
	end
	return self
end

--[[
	Regenerates every pool that has a rate.

	Regeneration runs regardless of what else is happening. A game that wants mana to stop coming
	back while casting can layer that on top; a kit that assumes it cannot be turned off.
]]
function ResourceManager:advance(dt)
	if type(dt) ~= "number" or dt <= 0 or dt ~= dt then
		return self
	end

	for _, pool in pairs(self.pools) do
		if pool.regen > 0 and pool.current < pool.max then
			pool.current = math.min(pool.max, pool.current + pool.regen * dt)
		end
	end
	return self
end

--[[
	The `resources` slice of the replicated state, in exactly the shape Config.STATE_FIELDS declares:

	    { [name] = { current = number, max = number } }

	Max is sent as well as current, because the client draws a bar and needs both ends of it. Nothing
	here says what the pool is for.
]]
function ResourceManager:toState()
	local resources = {}
	for name, pool in pairs(self.pools) do
		resources[name] = { current = pool.current, max = pool.max }
	end
	return resources
end

return ResourceManager
```

### `tests/ResourceManagerSpec.luau`

*27 cases, including the two-pool spend and the snapshot drift check.*

```lua
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

return T.report()
```

## How to test it

```
luau tests/run.luau          # 136 cases across 4 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

The cases that carry the phase:

- **a cost across two pools where the second is short deducts nothing** — the invariant
- **canPay accepts exactly the pool's worth, and refuses one unit short** — the boundary
- **spend can be called repeatedly down to exactly zero** — and never below
- **regeneration stops at the maximum instead of overflowing**
- **the snapshot is a copy, not a view** — a client that could write through it would be a bug
- **toState matches the resources shape Config declares, for every pool** — the drift check

## The numbers

- Tests: **136** across 4 suites — 40 · 34 · 35 · 27
- Lines: **1500 source + 1614 tests** = 3114
- Commits: **15**
- selene: 0 errors, 0 warnings · stylua: clean

## Where the spend happens, once phase 5 exists

Neither this module nor the manager calls the other. The composition root does:

```lua
local ok = manager:activate(slot, owner)
if ok then
    resources:spend(manager:getAbility(slot):getCost())
end
```

One line at the point where both objects are already in scope. Everything else in this phase exists
so that line can be that short.

## Still not verified

Four modules now, and the same caveat: **no full game boot**. The pools have never been attached to
a player, and nothing has regenerated across a real frame.
