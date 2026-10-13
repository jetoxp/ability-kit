--[[
	AbilityManager.luau — one player's abilities: what is equipped, what may fire, and when.

	Three things live here that belong to a PLAYER rather than to one ability:

	  1. The global cooldown. A short lockout after any activation, so mashing two keys in one
	     frame cannot produce two effects. It is not a property of an ability, which is why it is
	     here and not in Ability.luau.
	  2. The loadout. Which ability sits on which slot, and the instances that back them.
	  3. The central tick. One call per server frame advances every equipped ability, so timing is
	     resolved in one place instead of in N places that can drift apart.

	What it deliberately does NOT do:
	  - spend resources. `activate` checks that the cost is payable and reports it; deducting is
	    the ResourceManager's job (phase 4), so the deduction happens once, not per ability.
	  - apply effects. `advance` returns what fired and what it should do; the EffectSystem
	    (phase 4) is what reads it.
	  - know about players, characters or remotes. The owner arrives as a parameter on each call
	    and is any table with `alive` and `resources`. That is what keeps this module loadable and
	    testable with no Roblox running — the same property every module here depends on.

	No requires: the Ability class and the catalog are injected through `new`.
]]

local AbilityManager = {}
AbilityManager.__index = AbilityManager

-- config  : Config
-- Ability : the Ability class (injected, not required — see the header)
-- catalog : id -> definition, as AbilityDefinition.buildCatalog produces
-- loadout : optional, slot -> ability id. DefaultLoadout.luau in the game; anything in a test.
function AbilityManager.new(config, Ability, catalog, loadout)
	assert(type(config) == "table", "AbilityManager.new needs the config")
	assert(
		type(Ability) == "table" and Ability.new ~= nil,
		"AbilityManager.new needs the Ability class"
	)

	local self = setmetatable({}, AbilityManager)
	self.config = config
	self.Ability = Ability
	self.catalog = catalog or {}
	self.slots = {}
	self.globalCooldown = 0
	self:applyLoadout(loadout or {})
	return self
end

--[[
	Replaces the loadout wholesale. Slots absent from the table are cleared.

	Wholesale rather than incremental on purpose: a loadout is a statement of what the player has,
	and merging two of them produces a third that neither of them described. Phase 8 hands this
	whatever the inventory says is equipped, which is why it takes a table and not a player.
]]
function AbilityManager:applyLoadout(loadout)
	for slot = 1, self.config.MAX_EQUIPPED do
		local abilityId = loadout[slot]
		if abilityId ~= nil then
			self:equip(slot, abilityId)
		else
			self:unequip(slot)
		end
	end
	return true
end

function AbilityManager:equip(slot, abilityId)
	if type(slot) ~= "number" or slot < 1 or slot > self.config.MAX_EQUIPPED then
		return false, "abilityNotEquipped"
	end
	if type(abilityId) ~= "string" or self.catalog[abilityId] == nil then
		-- An ability the catalog does not know about is a loadout bug, and equipping nothing
		-- there would leave a slot that silently does not respond to its key.
		return false, "abilityNotEquipped"
	end

	-- Replacing whatever was there: if it was mid-cast, that cast dies with it.
	if self.slots[slot] ~= nil then
		self.slots[slot]:interrupt("castInterrupted")
	end

	self.slots[slot] = self.Ability.new(self.catalog[abilityId], self.config)
	return true, nil
end

function AbilityManager:unequip(slot)
	if self.slots[slot] == nil then
		return false
	end
	-- Cancel the cast as part of removing it. The alternative is an ability that keeps casting
	-- after it is no longer equipped, and fires from a slot the player can no longer see.
	self.slots[slot]:interrupt("castInterrupted")
	self.slots[slot] = nil
	return true
end

function AbilityManager:getAbility(slot)
	return self.slots[slot]
end

function AbilityManager:getEquippedIds()
	local ids = {}
	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil then
			ids[slot] = ability:getDefinition().id
		end
	end
	return ids
end

--[[
	Whether something is already casting.

	This has to be enforced here, and forcing the test suite to think about it is how it was found:
	each ability only knows about itself, so two DIFFERENT abilities could both be casting at once.
	A 1.2s Heal and a 1s Poison started 0.35s apart — inside the server's own global cooldown —
	would channel in parallel, and `cancel` would then have two things to choose between. One cast
	at a time is a property of the player, so it is the manager's rule.
]]
function AbilityManager:isCasting()
	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil and ability:getState() == self.Ability.STATES.casting then
			return true, slot
		end
	end
	return false, nil
end

function AbilityManager:isGlobalReady()
	return self.globalCooldown <= 0
end

function AbilityManager:getGlobalCooldown()
	return self.globalCooldown
end

--[[
	The activation entry point. This is the function the remote handler will call in phase 5, so
	it answers the way a remote needs: a boolean, a reason key from Config.MESSAGES, and the
	ability that was involved (or nil), so the caller can log and the UI can react.

	Order matters, and it is deliberate: the slot, then the global cooldown, then the ability's own
	rules. Checking the ability first would let a player with an off-cooldown ability bypass the GCD
	by hammering that one key.
]]
function AbilityManager:activate(slot, owner)
	local ability = self.slots[slot]
	if ability == nil then
		return false, "abilityNotEquipped", nil
	end

	-- Before the global cooldown, because it is the truer reason: a player mid-cast pressing
	-- another key is not "wait a moment", they are busy.
	if self:isCasting() then
		return false, "alreadyCasting", nil
	end

	if not self:isGlobalReady() then
		return false, "abilityOnCooldown", ability
	end

	local ok, reason = ability:canActivate(owner)
	if not ok then
		return false, reason, ability
	end

	if not ability:startActivation() then
		return false, "alreadyCasting", ability
	end

	-- Only a successful activation starts the global cooldown. Starting it on a refusal would let
	-- a player lock themselves out by pressing a key they cannot afford.
	self.globalCooldown = self.config.GLOBAL_COOLDOWN
	return true, nil, ability
end

-- Cancels whatever is casting. At most one ability can be casting at a time because activate()
-- enforces it (see isCasting), which is what makes a slot-less cancel honest rather than lucky.
function AbilityManager:cancel(reason)
	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil then
			local cancelled, message = ability:interrupt(reason)
			if cancelled then
				return true, message, slot
			end
		end
	end
	return false, nil, nil
end

--[[
	One server tick: advances the global cooldown and every equipped ability.

	Returns the firings, because this module does not apply effects. It takes no owner: applying the
	effects is the caller's job and the firing carries everything that needs. A parameter nobody
	reads is a promise the function does not keep. A firing looks like:

	    { slot = 2, id = "POISON", effects = <the definition's effects>, ability = <instance> }

	Slots are walked in numeric order rather than with `pairs`. Two abilities firing in the same
	tick would otherwise reach the effect system in a different order on different runs, which is
	the kind of thing that produces a bug you can only reproduce once.
]]
function AbilityManager:advance(dt)
	local firings = {}
	if type(dt) ~= "number" or dt <= 0 then
		return firings
	end

	if self.globalCooldown > 0 then
		self.globalCooldown = math.max(0, self.globalCooldown - dt)
	end

	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil then
			local fired, effects = ability:advance(dt)
			if fired then
				table.insert(firings, {
					slot = slot,
					id = ability:getDefinition().id,
					effects = effects,
					ability = ability,
				})
			end
		end
	end

	return firings
end

--[[
	The snapshot the server replicates.

	Small on purpose. The client needs to draw the bar, the cooldown sweeps and the cast bar, and
	anything else here is a map handed to whoever is reading the traffic.

	Note `resources` is absent: that is the ResourceManager's row of the same table (phase 4), and
	whoever assembles the final state joins them. Note also what is absent: costs, effects, and the
	definitions themselves.
]]
function AbilityManager:toState()
	local cooldowns = {}
	local equipped = {}
	local cast = nil

	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil then
			local id = ability:getDefinition().id
			equipped[slot] = id
			cooldowns[id] = ability:getCooldownRemaining()

			-- getCastProgress is 1 when there is nothing to cast, so the state check is what
			-- decides whether a cast bar exists at all.
			if ability:getState() == self.Ability.STATES.casting then
				cast = {
					id = id,
					slot = slot,
					remaining = ability:getCastRemaining(),
					progress = ability:getCastProgress(),
				}
			end
		end
	end

	return {
		globalCooldown = self.globalCooldown,
		cooldowns = cooldowns,
		equipped = equipped,
		cast = cast,
	}
end

-- Clears cooldowns and casts while keeping what is equipped. Used on respawn: a player who dies
-- should come back able to play, not waiting out a cooldown from their previous life.
function AbilityManager:reset()
	self.globalCooldown = 0
	for slot = 1, self.config.MAX_EQUIPPED do
		local ability = self.slots[slot]
		if ability ~= nil then
			ability:reset()
		end
	end
	return self
end

return AbilityManager
