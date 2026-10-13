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
	-- Getting two into one tick needs the instant ability on a LOWER slot than the cast: activate
	-- the cast, wait out the global cooldown, activate the instant, and then advance far enough
	-- that the cast finishes on the same tick the instant fires.
	-- With the shipped global cooldown this is unreachable, and that is worth stating: an instant
	-- cannot start while another ability casts, and two instants cannot both start inside 0.35s.
	-- Lowering the cooldown to zero is the only honest way to reach the case and check the order.
	local original = Config.GLOBAL_COOLDOWN
	Config.GLOBAL_COOLDOWN = 0
	local m = managerWith({ [1] = "FLASH", [2] = "BOLT" })
	m:activate(1, owner())
	m:activate(2, owner())
	local firings = m:advance(0.05)
	Config.GLOBAL_COOLDOWN = original
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
	assert(state.cooldowns ~= nil and state.cooldowns.FLASH ~= nil, "per ability")
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
	local uno = managerWith({ [1] = "FLASH" })
	local dos = managerWith({ [1] = "FLASH" })
	uno:activate(1, owner())
	uno:advance(0.05)
	assert(dos:isGlobalReady(), "the second player's global cooldown must be untouched")
	assert(dos:getAbility(1):isReady(), "and their ability ready")
	assert(uno:getAbility(1) ~= dos:getAbility(1), "instances must not be shared")
end)

return T.report()
