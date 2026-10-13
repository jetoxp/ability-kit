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

-- The subset AbilityManager is responsible for, kept next to the full list rather than derived
-- from it, so a test can check the manager emits exactly this and nothing else.
--
-- Split into required and optional because `cast` is absent whenever nobody is casting, and in Lua
-- an absent key and a nil value are the same thing: a check written as `snapshot[field] ~= nil`
-- over one flat list silently depends on a cast being in progress to pass. That is the coupling
-- this split removes — the test now runs in both states and says so.
Config.MANAGER_REQUIRED_FIELDS = { "cooldowns", "equipped", "globalCooldown" }
Config.MANAGER_OPTIONAL_FIELDS = { "cast" }

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
