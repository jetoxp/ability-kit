# Phase 3 — the `AbilityManager`

Framework de habilidades · `ability-kit` · code and docs in English, explanations in Spanish.

## What this phase delivers, and why it is shaped this way

Phase 2 gave one ability its own timing. Phase 3 gives a **player** three things that belong to the
player rather than to any ability:

1. **The global cooldown.** A short lockout after any activation, so mashing two keys in one frame
   cannot produce two effects.
2. **The loadout.** Which ability sits on which slot, and the instances behind them.
3. **The central tick.** One call per server frame advances every equipped ability, so timing is
   resolved in one place instead of in N places that drift apart.

And it deliberately does not do three other things: it does not **spend resources** (phase 4), it
does not **apply effects** (phase 4), and it does not know what a player, a character or a remote
is. The owner arrives as a parameter on each call, as any table with `alive` and `resources`.

### The three decisions worth arguing about

**1. The order of the checks in `activate`, and why it is that order.** Slot, then casting, then the
global cooldown, then the ability's own rules. Checking the ability first would let a player with
one off-cooldown ability bypass the global cooldown by hammering that single key.

**2. Only a successful activation starts the global cooldown.** Starting it on a refusal would let a
player lock themselves out by pressing a key they cannot afford.

**3. `advance` returns the firings instead of applying them.** Same reason as phase 2: a manager that
reaches out and deals damage cannot be tested without an engine. A firing looks like
`{ slot = 2, id = "POISON", effects = <...>, ability = <instance> }`.

The tick walks slots in numeric order rather than with `pairs`, so two firings in one tick reach the
effect system in the same order on every run.

## The file structure

```
src/shared/
  AbilityManager.luau   NEW — 262 lines
  Ability.luau
  AbilityDefinition.luau
  Config.luau
  DefaultLoadout.luau   slot -> ability id, consumed by this phase
  abilities/            (Fireball, Poison, Dash, Heal, init)
tests/
  AbilityManagerSpec.luau   NEW — 31 cases
  AbilitySpec.luau  AbilityDefinitionSpec.luau  TestKit.luau  run.luau
```

## The code

*The state after review.*

### `src/shared/AbilityManager.luau`

*The phase. The header lists what it does and, more usefully, what it refuses to do.*

```lua
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
	ability on the requested slot, so the caller can log and the UI can react.

	The third value follows one rule across every return: it is the ability on that slot, or nil
	when the slot is empty. It is not "whatever object explained the refusal" — that would vary by
	branch and make the caller's logging depend on which check happened to fail.

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
		-- The third value is "the ability on the requested slot, if there is one", and that rule
		-- holds for every return in this function: nil means the slot itself is empty, never that
		-- a reason happened to be decided early.
		return false, "alreadyCasting", ability
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
			-- Keyed by slot, never by id. Two slots can hold the same ability, and keying by id
			-- would collapse them into a single cooldown that the client then draws on both slots
			-- or on neither. A hotbar is a list of slots; that is how it is drawn.
			cooldowns[slot] = ability:getCooldownRemaining()

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
```

### `src/shared/Config.luau`

*Included because review found the snapshot shape written down in two places. It is now written once, here.*

```lua
--[[
	Config.luau — every tunable of the framework, in one place, and nothing that reads from
	Roblox. The point is that a consumer can change how this kit behaves without opening a
	single module that has logic in it.

	This file also pins the SHAPE of the replicated state before any module that uses it exists.
	That is deliberate. The remote that carries the snapshot arrives in a later phase, but the
	shape decides what every module has to expose, so discovering it late means reopening
	everything written before it.
]]

local Config = {}

-- Bump this when the save format changes so old data can be migrated instead of thrown away.
Config.SCHEMA_VERSION = 1

--[[
	The state the server owns and pushes to the client. It lives here, and only here, because
	several modules have to agree on it and a shape duplicated in two places drifts in silence.

	    resources     : { [name] = { current = number, max = number } }        (ResourceManager)
	    cooldowns     : { [slot] = secondsLeft }                               (AbilityManager)
	    equipped      : { [slot] = abilityId }                                 (AbilityManager)
	    globalCooldown: secondsLeft                                            (AbilityManager)
	    cast          : { id, slot, remaining, progress } | nil                (AbilityManager)

	Two of these were wrong in an earlier draft and are worth the note:

	`cooldowns` is keyed by SLOT, not by ability id. A loadout may hold the same ability on two
	slots, and keying by id collapses them into one cooldown that the client then draws twice —
	or once, for two slots. A hotbar is a list of slots; the client draws it by slot.

	`cast` carries `remaining` (seconds left) and `progress` (0 to 1), not an `endsAt` timestamp.
	The client's clock is not the server's, so a deadline it has to compare against its own time is
	a deadline it will get wrong by however far the two clocks disagree.

	Note what is absent: the client is never told a damage number, a hit result, a cost or an
	effect. It gets what it needs to draw a bar and play an animation.
]]
Config.STATE_FIELDS = { "resources", "cooldowns", "equipped", "globalCooldown", "cast" }

-- The subset AbilityManager is responsible for. Kept next to the full list, rather than derived
-- from it, so a test can check the manager emits exactly this and nothing else.
Config.MANAGER_FIELDS = { "cooldowns", "equipped", "globalCooldown", "cast" }

-- Seconds added after any ability fires. Stops two different keys being mashed in one frame
-- from producing two effects, and is short enough that it never feels unresponsive.
Config.GLOBAL_COOLDOWN = 0.35

-- How often the server ticks cooldowns and resource regeneration.
Config.TICK_RATE = 0.1

-- Resource pools. `regen` is per second, and 0 means the pool only refills another way.
Config.RESOURCES = {
	mana = { max = 100, regen = 6, start = 100 },
	stamina = { max = 100, regen = 12, start = 100 },
}

-- A definition may be listed here and nowhere else until it is equipped.
Config.MAX_EQUIPPED = 4

Config.CAST = {
	-- Taking damage interrupts a cast. Turn it off for a more forgiving game, but the cost is
	-- that a long cast becomes an uninterruptible free win in a duel.
	cancelOnDamage = true,
	-- Moving does not interrupt. Roblox players move constantly; cancelling on movement makes
	-- cast times feel like a bug rather than a mechanic.
	cancelOnMove = false,
}

Config.EFFECT_LIMITS = {
	-- Caps used by validation, so a mistyped number in a definition is caught at load instead of
	-- turning into a one-shot kill nobody can explain. These are sanity limits, not balance:
	-- a definition that needs more than this is far more likely to be a typo than a design.
	maxDamage = 500,
	maxHeal = 500,
	maxDuration = 30,
	maxRadius = 200,
	maxDashDistance = 200,
	-- An instant, free ability that hits at least this hard is almost certainly a mistake.
	-- Deliberately a warning and not an error: a framework informs, it does not decide for the
	-- game. A stricter consumer can promote it, an experimental one can ignore it.
	spammableDamageThreshold = 20,
}

-- Strings a PLAYER can see. Kept out of the modules on purpose: a framework should not decide
-- what language someone else's game speaks. A consumer overrides this table at startup.
Config.MESSAGES = {
	abilityNotEquipped = "You do not have that ability equipped.",
	abilityOnCooldown = "That ability is not ready yet.",
	notEnoughResources = "Not enough resources.",
	castInterrupted = "Your cast was interrupted.",
	alreadyCasting = "You are already casting.",
	invalidTarget = "That target is not valid.",
}

return Config
```

### `tests/AbilityManagerSpec.luau`

*34 cases: the loadout, the global cooldown, every refusal, the central tick, the snapshot, and the drift check.*

```lua
--[[
	AbilityManagerSpec.luau — runs with `luau tests/AbilityManagerSpec.luau`. No Studio.

	The catalog is built by hand here rather than with AbilityDefinition.buildCatalog on purpose:
	the definitions in this file exist to give the manager something to equip, and reusing the
	validator would make a failure here point at the wrong module.
]]

local TestKit = require("./TestKit")
local Config = require("../src/shared/Config")
local Ability = require("../src/shared/Ability")
local AbilityManager = require("../src/shared/AbilityManager")

local T = TestKit.new("AbilityManager")

local function instant(id, cooldown)
	return {
		id = id,
		displayName = id,
		cost = { mana = 10 },
		cooldown = cooldown or 2,
		castTime = 0,
		range = 0,
		effects = { { kind = "damage", amount = 10 } },
	}
end

local function slow(id)
	return {
		id = id,
		displayName = id,
		cost = { mana = 10 },
		cooldown = 8,
		castTime = 1,
		range = 0,
		effects = { { kind = "heal", amount = 10 } },
	}
end

local CATALOG = {
	FLASH = instant("FLASH"),
	BOLT = instant("BOLT"),
	HEAL = slow("HEAL"),
	POISON = slow("POISON"),
}

local function owner(mana, alive)
	return {
		alive = alive ~= false,
		resources = { mana = { current = mana or 100, max = 100 } },
	}
end

local function managerWith(loadout)
	return AbilityManager.new(Config, Ability, CATALOG, loadout or { [1] = "FLASH", [2] = "BOLT" })
end

-- ===== the loadout =====

T("a new manager equips the ids the loadout names, on the slots it names", function()
	local m = managerWith({ [1] = "FLASH", [3] = "HEAL" })
	assert(m:getAbility(1):getDefinition().id == "FLASH", "slot 1 must hold FLASH")
	assert(m:getAbility(3):getDefinition().id == "HEAL", "slot 3 must hold HEAL")
	assert(m:getAbility(2) == nil, "a slot the loadout omits must stay empty")
end)

T("equip refuses a slot outside 1..MAX_EQUIPPED", function()
	local m = managerWith({})
	local okZero = m:equip(0, "FLASH")
	assert(not okZero, "slot 0 does not exist")
	local okHigh = m:equip(Config.MAX_EQUIPPED + 1, "FLASH")
	assert(not okHigh, "and neither does one past the end")
end)

T("equip refuses an ability the catalog does not know", function()
	local m = managerWith({})
	local ok, reason = m:equip(1, "NOT_IN_CATALOG")
	assert(not ok, "an unknown id must not leave a slot that silently ignores its key")
	assert(reason == "abilityNotEquipped", "got: " .. tostring(reason))
end)

T("equip replaces what was in the slot", function()
	local m = managerWith({ [1] = "FLASH" })
	m:equip(1, "BOLT")
	assert(m:getAbility(1):getDefinition().id == "BOLT", "the slot must hold the new ability")
end)

T("equipping over an ability that is casting kills that cast", function()
	local m = managerWith({ [1] = "HEAL" })
	m:activate(1, owner())
	assert(m:isCasting(), "the cast must have started")
	m:equip(1, "FLASH")
	assert(not m:isCasting(), "the old cast must not outlive its ability")
end)

T("unequip clears the slot and refuses an already empty one", function()
	local m = managerWith({ [1] = "FLASH" })
	assert(m:unequip(1), "the slot was occupied")
	assert(m:getAbility(1) == nil, "and must be empty now")
	assert(not m:unequip(1), "unequipping nothing is a no-op, not a success")
end)

T("unequipping mid-cast cancels the cast", function()
	local m = managerWith({ [1] = "HEAL" })
	m:activate(1, owner())
	m:unequip(1)
	local fired = m:advance(2)
	assert(#fired == 0, "an ability that is no longer equipped must not fire from a hidden slot")
end)

T("applyLoadout replaces the loadout instead of merging it", function()
	local m = managerWith({ [1] = "FLASH", [2] = "BOLT" })
	m:applyLoadout({ [1] = "HEAL" })
	assert(m:getAbility(1):getDefinition().id == "HEAL", "slot 1 takes the new id")
	assert(m:getAbility(2) == nil, "and slot 2 must be cleared, not merged")
end)

T("getEquippedIds reports the occupied slots by id", function()
	local m = managerWith({ [1] = "FLASH", [3] = "HEAL" })
	local ids = m:getEquippedIds()
	assert(ids[1] == "FLASH", "slot 1")
	assert(ids[2] == nil, "slot 2 is empty")
	assert(ids[3] == "HEAL", "slot 3")
end)

-- ===== the global cooldown =====

T("nothing is on the global cooldown to start with", function()
	local m = managerWith({})
	assert(m:isGlobalReady(), "a fresh manager must be ready")
	assert(m:getGlobalCooldown() == 0, "and its timer at zero")
end)

T("a successful activation starts the global cooldown", function()
	local m = managerWith({ [1] = "FLASH" })
	m:activate(1, owner())
	assert(not m:isGlobalReady(), "the activation must lock the others out")
	assert(
		math.abs(m:getGlobalCooldown() - Config.GLOBAL_COOLDOWN) < 0.0001,
		"and for exactly Config.GLOBAL_COOLDOWN"
	)
end)

T("a REFUSED activation does not start the global cooldown", function()
	-- Otherwise a player locks themselves out by pressing a key they cannot afford.
	local m = managerWith({ [1] = "FLASH" })
	local ok = m:activate(1, owner(0))
	assert(not ok, "with no mana the activation must fail")
	assert(m:isGlobalReady(), "and must not cost the player their global cooldown")
end)

T("the global cooldown blocks a DIFFERENT ability, which is its whole purpose", function()
	local m = managerWith({ [1] = "FLASH", [2] = "BOLT" })
	m:activate(1, owner())
	local ok, reason = m:activate(2, owner())
	assert(not ok, "mashing two keys in one frame must not produce two effects")
	assert(reason == "abilityOnCooldown", "got: " .. tostring(reason))
end)

T("the global cooldown runs down with the tick and then releases", function()
	local m = managerWith({ [1] = "FLASH", [2] = "BOLT" })
	m:activate(1, owner())
	m:advance(Config.GLOBAL_COOLDOWN + 0.01)
	assert(m:isGlobalReady(), "after the tick the next ability must be allowed")
	assert(m:activate(2, owner()), "and it must actually activate")
end)

-- ===== the activation =====

T("activating an empty slot is refused as not equipped", function()
	local m = managerWith({})
	local ok, reason = m:activate(3, owner())
	assert(not ok, "an empty slot has nothing to fire")
	assert(reason == "abilityNotEquipped", "got: " .. tostring(reason))
end)

T("activating without enough mana is refused, and names the reason", function()
	local m = managerWith({ [1] = "FLASH" })
	local ok, reason = m:activate(1, owner(5))
	assert(not ok, "5 mana cannot pay a cost of 10")
	assert(reason == "notEnoughResources", "got: " .. tostring(reason))
	assert(Config.MESSAGES[reason] ~= nil, "the reason must be one Config can translate")
end)

T("activating a dead owner is refused", function()
	local m = managerWith({ [1] = "FLASH" })
	local ok, reason = m:activate(1, owner(100, false))
	assert(not ok, "the dead cannot cast")
	assert(reason == "invalidTarget", "got: " .. tostring(reason))
end)

T("a second activation while one is casting is refused, even for a different ability", function()
	-- Each ability only knows about itself, so without the manager's rule a 1.2s Heal and a 1s
	-- Poison started 0.35s apart — inside the server's own global cooldown — channel in parallel.
	local m = managerWith({ [1] = "HEAL", [2] = "POISON" })
	m:activate(1, owner())
	m:advance(Config.GLOBAL_COOLDOWN + 0.01)
	local ok, reason = m:activate(2, owner())
	assert(not ok, "two casts at once is not a thing this kit allows")
	assert(reason == "alreadyCasting", "got: " .. tostring(reason))
end)

T("activate returns the ability it involved so the caller can log it", function()
	local m = managerWith({ [1] = "FLASH" })
	local ok, _, ability = m:activate(1, owner())
	assert(ok, "the activation must succeed")
	assert(ability == m:getAbility(1), "and hand back the instance")
end)

-- ===== cancel =====

T("cancel stops the cast in progress and reports which slot", function()
	local m = managerWith({ [1] = "HEAL", [2] = "POISON" })
	m:activate(1, owner())
	local cancelled, message, slot = m:cancel("castInterrupted")
	assert(cancelled, "a cast in progress must be cancellable")
	assert(slot == 1, "and must report the slot, got " .. tostring(slot))
	assert(message == Config.MESSAGES.castInterrupted, "with the translatable message")
	assert(not m:isCasting(), "and nothing casting afterwards")
end)

T("cancel with nothing casting is a no-op", function()
	local m = managerWith({ [1] = "FLASH" })
	local cancelled = m:cancel()
	assert(not cancelled, "there was nothing to cancel")
end)

T("a cancelled cast leaves the ability idle, off cooldown, and able to fire again", function()
	local m = managerWith({ [1] = "HEAL" })
	m:activate(1, owner())
	m:cancel()
	local ability = m:getAbility(1)
	assert(ability:isReady(), "back to idle")
	assert(
		ability:getCooldownRemaining() == 0,
		"and nothing charged for a cast that never happened"
	)
	-- Past the global cooldown first: cancelling refunds the ability, not the player's input lock.
	m:advance(Config.GLOBAL_COOLDOWN + 0.01)
	assert(m:activate(1, owner()), "so it can be started again")
end)

-- ===== the tick =====

T("advance reports an instant ability's firing with its slot, id and effects", function()
	local m = managerWith({ [2] = "FLASH" })
	m:activate(2, owner())
	local firings = m:advance(0.05)
	assert(#firings == 1, "exactly one firing")
	assert(firings[1].slot == 2, "carrying its slot")
	assert(firings[1].id == "FLASH", "its id")
	assert(firings[1].effects == CATALOG.FLASH.effects, "and the effects to apply")
end)

T("two abilities firing in the same tick come back in slot order, not in pairs order", function()
	-- Otherwise the effect system sees them in a different order on different runs, and that is a
	-- bug that reproduces once in a hundred games.
	--
	-- With the shipped global cooldown this is unreachable: an instant cannot start while another
	-- ability casts, and two instants cannot both start inside 0.35s. So the case runs against a
	-- config with the lockout at zero — an injected copy, not a mutated Config, so a failure in
	-- here cannot poison whatever suite runs next.
	local unlocked = table.clone(Config)
	unlocked.GLOBAL_COOLDOWN = 0

	local m = AbilityManager.new(unlocked, Ability, CATALOG, { [1] = "FLASH", [2] = "BOLT" })
	m:activate(1, owner())
	m:activate(2, owner())
	local firings = m:advance(0.05)
	assert(#firings == 2, "both must fire on this tick, got " .. #firings)
	assert(firings[1].slot == 1, "slot 1 comes first")
	assert(firings[2].slot == 2, "and slot 2 second")
end)

T("an ability's own cooldown runs while the global one does", function()
	local m = managerWith({ [1] = "FLASH" })
	m:activate(1, owner())
	m:advance(0.05)
	local afterFiring = m:getAbility(1):getCooldownRemaining()
	m:advance(1)
	assert(
		m:getAbility(1):getCooldownRemaining() < afterFiring,
		"the per-ability cooldown must tick, not only the global one"
	)
end)

T("a nonsense dt produces no firings and moves nothing", function()
	local m = managerWith({ [1] = "FLASH" })
	m:activate(1, owner())
	local firings = m:advance(0)
	assert(#firings == 0, "dt = 0 must fire nothing")
	local firings2 = m:advance("soon")
	assert(#firings2 == 0, "and neither must a string")
end)

-- ===== the snapshot =====

T("toState carries the four fields and nothing that would help an exploiter", function()
	local m = managerWith({ [1] = "FLASH", [2] = "HEAL" })
	m:activate(1, owner())
	m:advance(0.05)
	local state = m:toState()
	assert(state.globalCooldown ~= nil, "the client draws the greyed-out slots from this")
	assert(state.cooldowns ~= nil and state.cooldowns[1] ~= nil, "keyed by slot, per ability")
	assert(state.equipped ~= nil and state.equipped[1] == "FLASH", "and what is on each slot")
	assert(state.cost == nil, "the cost is not the client's business")
	assert(state.effects == nil, "nor the effects")
	assert(state.catalog == nil, "nor the catalog")
end)

T("toState carries no cast while nothing is casting", function()
	local m = managerWith({ [1] = "FLASH" })
	assert(m:toState().cast == nil, "an idle player has no cast bar")
end)

T("toState carries the cast, its slot and its progress while casting", function()
	local m = managerWith({ [1] = "HEAL" })
	m:activate(1, owner())
	m:advance(0.5)
	local state = m:toState()
	assert(state.cast ~= nil, "a casting player has one")
	assert(state.cast.id == "HEAL", "with the right id")
	assert(state.cast.slot == 1, "and slot")
	assert(state.cast.progress > 0.4 and state.cast.progress < 0.6, "and a drawable progress")
end)

T("reset clears cooldowns and casts but keeps what is equipped", function()
	local m = managerWith({ [1] = "FLASH", [2] = "HEAL" })
	m:activate(2, owner())
	m:advance(0.3)
	m:reset()
	assert(m:isGlobalReady(), "a respawn must not inherit a global cooldown")
	assert(m:getAbility(2):isReady(), "nor a cast in progress")
	assert(m:getAbility(1) ~= nil, "but the loadout survives death")
	assert(m:getAbility(2) ~= nil, "on every slot")
end)

-- ===== independence =====

T("two managers, two players: no shared slots, timers or cooldowns", function()
	local firstManager = managerWith({ [1] = "FLASH" })
	local secondManager = managerWith({ [1] = "FLASH" })
	firstManager:activate(1, owner())
	firstManager:advance(0.05)
	assert(secondManager:isGlobalReady(), "the second player's global cooldown must be untouched")
	assert(secondManager:getAbility(1):isReady(), "and their ability ready")
	assert(
		firstManager:getAbility(1) ~= secondManager:getAbility(1),
		"instances must not be shared"
	)
end)

T("the same ability on two slots keeps two separate cooldowns", function()
	-- Keying the snapshot by id collapsed these into one, and the client drew a cooldown on both
	-- slots or on neither. Keyed by slot, each one is its own.
	local m = managerWith({ [1] = "FLASH", [2] = "FLASH" })
	assert(m:getAbility(2) ~= nil, "a loadout may hold the same ability twice, which is the point")
	m:activate(1, owner())
	m:advance(0.05)
	local state = m:toState()
	assert(state.cooldowns[1] > 0, "slot 1 must show its own cooldown")
	assert(state.cooldowns[2] == 0, "and slot 2 must not inherit it")
end)

T("the snapshot carries exactly the fields Config reserves for the manager", function()
	-- The drift check. Config is the one place the shape is written down, so a field appearing in
	-- one side and not the other becomes a failing test instead of a divergence nobody notices.
	local m = managerWith({ [1] = "HEAL" })
	m:activate(1, owner())
	m:advance(0.2)
	local snapshot = m:toState()

	for _, field in ipairs(Config.MANAGER_FIELDS) do
		assert(
			snapshot[field] ~= nil,
			"Config declares '" .. field .. "' and the snapshot omits it"
		)
	end

	for name in pairs(snapshot) do
		local declared = false
		for _, field in ipairs(Config.MANAGER_FIELDS) do
			if field == name then
				declared = true
				break
			end
		end
		assert(
			declared,
			"the snapshot carries '" .. name .. "', which Config.MANAGER_FIELDS does not declare"
		)
	end
end)

T(
	"activate returns the slot's ability on every return, and nil only when the slot is empty",
	function()
		local m = managerWith({ [1] = "HEAL" })
		local _, _, onSuccess = m:activate(1, owner())
		assert(onSuccess == m:getAbility(1), "a success hands back the ability")

		m:advance(Config.GLOBAL_COOLDOWN + 0.01)
		local ok, reason, onEmpty = m:activate(2, owner())
		assert(
			not ok and reason == "abilityNotEquipped",
			"slot 2 is empty, got " .. tostring(reason)
		)
		assert(onEmpty == nil, "so there is no ability to hand back")

		m:activate(1, owner())
		local _, _, onCasting = m:activate(1, owner())
		assert(
			onCasting == m:getAbility(1),
			"a refusal on an occupied slot still names its ability"
		)
	end
)

return T.report()
```

## How to test it

```
luau tests/run.luau          # 108 cases across 3 suites
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

Still nothing to look at in Studio, and still for the same reason: no module here touches a
Roblox API, so the interpreter exercises them as well as the engine would.

## What writing the suite found

> **Two DIFFERENT abilities could cast at the same time.** Each ability only knows about itself,
> so a 1.2s Heal and a 1s Poison started 0.35s apart — inside the server's own global cooldown —
> would channel in parallel, and `cancel` would then have two things to choose between. One cast
> at a time is a property of the player, so `activate` now enforces it. The comment claiming
> "at most one ability can be casting" was true of the *implementation* and false of the
> *system*, which is the worse of the two ways for a comment to be wrong.

Also: `advance(dt, owner)` took an owner it never read, and two of the cases were wrong in
that they forgot a rule the kit enforces — the second of which revealed that the slot-ordering
rule is unreachable with the shipped cooldown, so that case injects a config with the lockout
at zero rather than pretending the path runs.

## What review found in this phase

Six more, and the shapes are different from phase 1's:

| # | Finding | Shape |
|---|---------|-------|
| 1 | `equip(1,"FLASH")` and `equip(2,"FLASH")` were allowed, and `cooldowns` keyed by id collapsed two slots into one cooldown the client drew twice | a key that is not unique |
| 2 | the snapshot shape diverged from the one pinned in Config — and Config itself was missing two fields | a shape written down twice |
| 3 | the ordering case mutated the global `Config.GLOBAL_COOLDOWN`; an exception mid-test would have poisoned every suite after it | a test that can poison its neighbours |
| 4 | `uno`, `dos` in the newest spec — the Spanish sweep had been run on the older files only | a convention checked by hand |
| 5 | `activate`'s third return varied by branch, so the caller's logging depended on which check failed | a return contract with exceptions |
| 6 | this document had raw test output pasted into its numbers block | a document generated rather than written |

Finding 2 is the one that mattered most. `Config` claimed a shape, `AbilityManager` produced a
different one, and nothing compared them — so they would have drifted again the first time
either changed. Both are now one list (`Config.STATE_FIELDS`, and the manager's subset), and a
test fails if the snapshot carries a field the list does not declare.

Two decisions were made rather than fixed:

- **`cooldowns` is keyed by slot, not by id.** A hotbar is a list of slots and the client draws
  it that way; an ability id is not unique on it. The phase-1 pin was wrong, not the manager.
- **`cast` carries `remaining` and `progress`, not an `endsAt`.** The client's clock is not the
  server's, so a deadline it must compare against its own time is one it will get wrong by
  however far the two disagree.

## The numbers

- Tests: **108** across 3 suites — AbilityDefinitionSpec: 40 · AbilitySpec: 34 · AbilityManagerSpec: 34
- Lines: **1300 source + 1324 tests** = 2624
- Commits: **13**
- selene: 0 errors, 0 warnings · stylua: clean

## What is not here yet, on purpose

- **Spending resources.** `activate` checks the cost is payable and the refusal is wired;
  deducting is the ResourceManager's, so it happens once instead of per ability.
- **Applying effects.** The firings carry them; nothing reads them yet.
- **The remote, the Bootstrap, the character.** Phase 5. Nothing here has touched a player.

## Still not verified

Three modules now share the caveat: **no full game boot**. What is verified is the logic, and
that these modules load by the same `require` path the boot will use.
