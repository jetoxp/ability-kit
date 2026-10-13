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
			local given = initial[name]
			-- Strict, and deliberately matching canPay, which refuses a string cost. A module that
			-- rejects "50" in one place and quietly converts it in another is not being lenient, it
			-- is being inconsistent — and the place it converts is the one nobody tests.
			-- An assert rather than a refusal because this is a construction-time programming error,
			-- like the ones Ability.new makes, not a runtime condition.
			assert(
				type(given) == "number" and given == given,
				string.format("initial.%s must be a number, got %s", name, type(given))
			)
			start = given
		end
		self.pools[name] = {
			current = math.clamp(start, 0, spec.max),
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

	Zero is accepted and does nothing, and that is the intended reading of the boundary: 0 is a
	valid amount that changes no pool, not a spend in disguise. The guard is `< 0`, not `<= 0`.
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

	Returns self, like refill. The module's signatures fall into two groups on purpose: the ones that
	just move state are chainable and return self, and the ones that can be refused are transactions
	and return (ok, reason). Nothing does both.
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
	The pool table itself, in the shape an ability owner is read from.

	`Ability:canActivate` reads `owner.resources[pool].current`, which is exactly what these pools
	already are — so handing this back is what lets the composition root ask "can you afford it?"
	by calling `manager:activate`, without a second affordability check that could disagree with
	the first. Phase 5's note about checking canPay before activating is answered here: the check
	the manager already performs IS canPay, when it is handed these.

	Returned by reference on purpose. A copy would let the two drift apart one frame at a time.
]]
function ResourceManager:getOwnerResources()
	return self.pools
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
