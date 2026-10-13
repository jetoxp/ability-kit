# Phase 1 — Config, AbilityDefinition, and the four abilities

Framework de habilidades · `ability-kit` · every file in English, as agreed.

## What this phase delivers, and why it is shaped this way

Phase 1 has one job: make it **impossible to write an ability as code**. An ability is a
table, and the only general code that exists about abilities is the validator below. There is
no `if id == "FIREBALL"` anywhere in this kit, and that property is what every later phase
leans on.

Two decisions in here are worth knowing before you read the code:

**1. The effect vocabulary is declared, not invented.** `EFFECT_KINDS` lists the six
primitives (damage, dot, heal, buff, debuff, dash). Abilities compose them; an unknown kind
is a rejected definition. That is the line between a framework and a game: the pieces are
code, the content is data.

**2. The shape of the replicated state is pinned here, in phase 1, not in phase 5.** The
remote that carries it comes later, but what the server must expose (resources, cooldowns,
current cast) decides what every module has to be able to answer. Finding that out five
phases from now would mean reopening everything written before it.

## The file structure

```
src/shared/
  Config.luau              tunables + the state shape + player-facing messages
  AbilityDefinition.luau   the contract and its validator
  DefaultLoadout.luau      slot -> ability id
  abilities/
    Fireball.luau  Poison.luau  Dash.luau  Heal.luau    pure data, no requires
    init.luau             the catalog
tests/
  TestKit.luau  run.luau  AbilityDefinitionSpec.luau
```

The four ability files require nothing at all. That is not tidiness: it is what lets the
test suite load them in a plain Luau interpreter, with no Studio running.

## The code

*The state after review — this is what is in Studio and in git today.*

### `src/shared/Config.luau`

*Every tunable, and the shape of the state the server replicates.*

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

-- The state the server owns and pushes to the client. Documented here, not in a comment buried
-- in the manager, because three separate modules have to agree on it:
--
--   resources : { [name] = { current = number, max = number } }
--   cooldowns : { [abilityId] = secondsLeft }
--   cast      : { abilityId = string, endsAt = number, interrupted = boolean } | nil
--
-- Note what is NOT here: the client is never told a damage number, a hit result, or anything it
-- could use to decide an outcome. It gets what it needs to draw a bar and play an animation.
Config.STATE_FIELDS = { "resources", "cooldowns", "cast" }

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

### `src/shared/AbilityDefinition.luau`

*The data contract, the validator, and the catalog builder.*

```lua
--[[
	AbilityDefinition.luau — the data contract for one ability, and the rules that decide
	whether a definition is legal.

	This module is the whole reason the framework is "data-driven": an ability is a table, and
	the only code that exists about abilities in the general sense is the validation below. There
	is no `if id == "FIREBALL" then` anywhere in this kit, and that is the property to protect.

	The catalog is INJECTED (init) rather than required, which is what lets this file run in a
	plain Luau interpreter with no Roblox present. That is what makes the tests possible.
]]

-- No requires at the top, on purpose. This module must load in a plain Luau interpreter
-- where `script` does not exist, and that is only possible if nothing here reaches outside
-- for its dependencies. Everything it needs arrives through init().
local AbilityDefinition = {}

-- The vocabulary of the framework. Abilities compose these; they never invent a new one.
-- Adding a kind here is a deliberate act that touches exactly two places: the EffectSystem that
-- implements it, and this list. Anywhere else, an unknown kind is a rejected definition.
AbilityDefinition.EFFECT_KINDS = {
	"damage", -- instant hit, optionally to everything inside `radius`
	"dot", -- damage over time; the way a debuff deals damage
	"heal",
	"buff", -- a temporary stat multiplier on the caster or an ally
	"debuff", -- the same, aimed at someone else
	"dash", -- movement, resolved by the server so the client cannot teleport itself
}

AbilityDefinition.CATALOG = nil
AbilityDefinition.CONFIG = nil

-- Called once at startup. The config is injected rather than required so that a test can hand
-- this module any limits it wants to exercise, including ones no shipped config would use.
function AbilityDefinition.init(config, catalog)
	AbilityDefinition.CONFIG = config
	AbilityDefinition.CATALOG = catalog
end

local function config()
	return AbilityDefinition.CONFIG
end

-- warn is a Roblox global and does not exist when this file is run by the luau CLI. A
-- defensive log keeps the module honest in both places instead of crashing in tests.
local function log(message: string)
	if typeof(warn) == "function" then
		warn(message)
	else
		print(message)
	end
end

local function isPositiveNumber(value)
	return type(value) == "number" and value > 0 and value == value and value < math.huge
end

--[[
	Checks one definition.

	Returns two lists on purpose. `errors` are things that make the definition unusable, so the
	ability is dropped. `warnings` are things that will run fine but are probably not what
	someone meant. Collapsing the two means either rejecting working abilities or shipping
	balance mistakes silently, and both are worse than a second list.
]]
function AbilityDefinition.validate(definition)
	local cfg = config()
	if not cfg then
		return { "AbilityDefinition.init was never called" }, {}
	end

	local errors, warnings = {}, {}

	if type(definition) ~= "table" then
		table.insert(errors, "definition is not a table")
		return errors, warnings
	end

	-- Identity
	if type(definition.id) ~= "string" or definition.id == "" then
		table.insert(errors, "id must be a non-empty string")
	end
	if type(definition.displayName) ~= "string" or definition.displayName == "" then
		table.insert(errors, "displayName must be a non-empty string")
	end
	if definition.description ~= nil and type(definition.description) ~= "string" then
		table.insert(errors, "description must be a string when present")
	end

	-- Timing
	if
		definition.cooldown ~= nil
		and (type(definition.cooldown) ~= "number" or definition.cooldown < 0)
	then
		table.insert(errors, "cooldown must be a number >= 0")
	end
	if
		definition.castTime ~= nil
		and (type(definition.castTime) ~= "number" or definition.castTime < 0)
	then
		table.insert(errors, "castTime must be a number >= 0")
	end

	-- Cost: every key must be a real pool, and no cost may exceed that pool's maximum, because
	-- an ability nobody can ever cast is a definition bug that would otherwise look like a
	-- broken keybind.
	if definition.cost ~= nil then
		if type(definition.cost) ~= "table" then
			table.insert(errors, "cost must be a table like { mana = 25 }")
		else
			for pool, amount in pairs(definition.cost) do
				if cfg.RESOURCES[pool] == nil then
					table.insert(
						errors,
						string.format("cost names unknown resource '%s'", tostring(pool))
					)
				elseif not isPositiveNumber(amount) then
					table.insert(
						errors,
						string.format("cost.%s must be a positive number", tostring(pool))
					)
				elseif amount > cfg.RESOURCES[pool].max then
					table.insert(
						errors,
						string.format(
							"cost.%s (%d) exceeds the pool maximum (%d): this ability could never be cast",
							tostring(pool),
							amount,
							cfg.RESOURCES[pool].max
						)
					)
				end
			end
		end
	end

	-- Effects
	if type(definition.effects) ~= "table" or #definition.effects == 0 then
		table.insert(
			errors,
			"effects must be a non-empty array: an ability that does nothing is a bug"
		)
	else
		for index, effect in ipairs(definition.effects) do
			local where = string.format("effects[%d]", index)
			if type(effect) ~= "table" then
				table.insert(errors, where .. " is not a table")
				continue
			end

			local known = false
			for _, kind in ipairs(AbilityDefinition.EFFECT_KINDS) do
				if effect.kind == kind then
					known = true
					break
				end
			end
			if not known then
				table.insert(
					errors,
					string.format("%s has unknown kind '%s'", where, tostring(effect.kind))
				)
				continue
			end

			-- Per-kind requirements. Each one exists because its absence produced a bug that is
			-- silent at runtime: a dash of nil distance, a DoT that never ticks, a buff that
			-- multiplies by nothing.
			if effect.kind == "damage" or effect.kind == "heal" then
				if not isPositiveNumber(effect.amount) then
					table.insert(errors, where .. ".amount must be a positive number")
				elseif
					effect.amount
					> (
						effect.kind == "damage" and cfg.EFFECT_LIMITS.maxDamage
						or cfg.EFFECT_LIMITS.maxHeal
					)
				then
					table.insert(
						errors,
						string.format(
							"%s.amount (%d) is beyond the sanity limit",
							where,
							effect.amount
						)
					)
				end
				if
					effect.radius ~= nil and (type(effect.radius) ~= "number" or effect.radius < 0)
				then
					table.insert(errors, where .. ".radius must be a number >= 0 when present")
				end
			elseif effect.kind == "dot" then
				if not isPositiveNumber(effect.amount) then
					table.insert(errors, where .. ".amount must be a positive number")
				end
				if not isPositiveNumber(effect.duration) then
					table.insert(errors, where .. ".duration must be a positive number")
				elseif effect.duration > cfg.EFFECT_LIMITS.maxDuration then
					table.insert(
						errors,
						string.format(
							"%s.duration (%d) is beyond the sanity limit",
							where,
							effect.duration
						)
					)
				end
				if not isPositiveNumber(effect.interval) then
					table.insert(
						errors,
						where .. ".interval must be a positive number or it never ticks"
					)
				end
			elseif effect.kind == "buff" or effect.kind == "debuff" then
				if type(effect.stat) ~= "string" or effect.stat == "" then
					table.insert(errors, where .. ".stat must name what it changes")
				end
				if not isPositiveNumber(effect.multiplier) then
					table.insert(errors, where .. ".multiplier must be a positive number")
				end
				if not isPositiveNumber(effect.duration) then
					table.insert(errors, where .. ".duration must be a positive number")
				end
			elseif effect.kind == "dash" then
				if not isPositiveNumber(effect.distance) then
					table.insert(errors, where .. ".distance must be a positive number")
				elseif effect.distance > cfg.EFFECT_LIMITS.maxDashDistance then
					table.insert(
						errors,
						string.format(
							"%s.distance (%d) is beyond the sanity limit",
							where,
							effect.distance
						)
					)
				end
			end
		end
	end

	-- Taste rules. These run fine, so they are warnings: the framework does not know whether the
	-- designer meant it, and pretending otherwise would make it reject working content.
	if
		definition.cooldown == 0
		and definition.castTime == 0
		and type(definition.effects) == "table"
	then
		for _, effect in ipairs(definition.effects) do
			if effect.kind == "damage" and (effect.amount or 0) >= 20 then
				table.insert(warnings, "instant, no cooldown, and hits hard: spammable by design?")
				break
			end
		end
	end
	if definition.castTime ~= nil and definition.castTime > 0 and definition.cooldown == nil then
		table.insert(warnings, "no cooldown on a cast-time ability: the cast is the only cost")
	end

	return errors, warnings
end

--[[
	Checks a whole catalog at once.

	Accepts both shapes the kit uses: an ARRAY (what the catalog file returns, and what the
	tests pass) and a DICT keyed by id (what the game runs on after catalog building).

	The duplicate check keys on definition.id, never on the table key. That distinction is the
	whole point of this function: iterating an array yields 1, 2, 3..., and table keys are
	unique by construction, so keying on them can never collide — it would be a check that
	reads like a guarantee and enforces nothing. Two entries may share an index nowhere and
	still share an id, which is the case that silently makes the second ability unreachable.
]]
function AbilityDefinition.validateCatalog(catalog)
	local errors, warnings = {}, {}
	local seen = {}

	if type(catalog) ~= "table" then
		return { "catalog is not a table" }, warnings
	end

	for key, definition in pairs(catalog) do
		local label
		if
			type(definition) == "table"
			and type(definition.id) == "string"
			and definition.id ~= ""
		then
			label = definition.id
		else
			-- No usable id: name the position instead of the index-as-string, which would
			-- print as "1" and read like an ability called 1.
			label = string.format("<entry at key %s>", tostring(key))
		end

		if type(definition) ~= "table" then
			table.insert(errors, string.format("%s: definition is not a table", label))
			continue
		end

		-- Only a usable string id can be a duplicate. The guard around `label` above is NOT
		-- enough: it protects the message, not the write, and `seen[nil] = true` is a Lua error
		-- ("table index is nil"). A definition with no id is reported by validate() a few lines
		-- down, so this branch exists purely so the bookkeeping survives the trip there.
		local id = definition.id
		if type(id) == "string" and id ~= "" then
			if seen[id] then
				table.insert(errors, string.format("%s: duplicate id '%s'", label, id))
			end
			seen[id] = true
		end

		local defErrors, defWarnings = AbilityDefinition.validate(definition)
		for _, message in ipairs(defErrors) do
			table.insert(errors, string.format("%s: %s", label, message))
		end
		for _, message in ipairs(defWarnings) do
			table.insert(warnings, string.format("%s: %s", label, message))
		end
	end

	return errors, warnings
end

--[[
	Turns a list of definitions into the id-keyed catalog the rest of the game looks up.

	This exists as a function rather than as code inside the catalog file for one reason: the
	catalog file requires Roblox and cannot be loaded by the test suite, so anything living there
	is untestable by definition — which is exactly how a missing init() shipped. Here the entire
	order is covered by tests: validate the array while a duplicate is still twice visible, then
	index it.

	Returns nil plus the errors when the catalog is unusable, and that is structural, not
	cosmetic: the only way to receive a catalog is to receive one that had no errors, so a caller
	cannot half-succeed and let a broken table travel three modules before anyone notices.
]]
function AbilityDefinition.buildCatalog(definitions)
	local errors, warnings = AbilityDefinition.validateCatalog(definitions)
	if #errors > 0 then
		return nil, errors, warnings
	end

	-- pairs, not ipairs, to match what validateCatalog accepts. With ipairs a dict validated
	-- clean and then produced an EMPTY catalog without a single error: the validation said yes
	-- and the build returned nothing, which is the worst failure shape there is. The two
	-- functions must accept the same input or one of them lies.
	--
	-- (Contrast with the effects loop inside validate(), which uses ipairs on purpose: the order
	-- of a definition's effects is meaningful. Here it is not — the result is a lookup by id.)
	local catalog = {}
	for _, definition in pairs(definitions) do
		catalog[definition.id] = definition
	end
	return catalog, errors, warnings
end

-- Reads one definition out of the injected catalog. Returns nil rather than throwing, because a
-- missing ability is an expected case (a client asks for one it no longer has), not an error.
function AbilityDefinition.get(id)
	local catalog = AbilityDefinition.CATALOG
	if type(catalog) ~= "table" or type(id) ~= "string" then
		return nil
	end
	return catalog[id]
end

function AbilityDefinition.logValidation(catalog)
	local errors, warnings = AbilityDefinition.validateCatalog(catalog)
	for _, message in ipairs(errors) do
		log(string.format("[AbilityDefinition] ERROR %s", message))
	end
	for _, message in ipairs(warnings) do
		log(string.format("[AbilityDefinition] warning %s", message))
	end
	return #errors == 0
end

return AbilityDefinition
```

### `src/shared/DefaultLoadout.luau`

*slot -> ability id. Phase 8 replaces this table.*

```lua
--[[
	DefaultLoadout.luau — which ability sits on which slot, by default.

	Kept separate from the definitions on purpose: a definition should not know what key you
	bound it to. Phase 8 replaces this table with whatever the inventory says is equipped, and
	because the manager reads a loadout rather than a keyboard, that phase is a swap.
]]
return {
	[1] = "FIREBALL",
	[2] = "POISON",
	[3] = "DASH",
	[4] = "HEAL",
}
```

### `src/shared/abilities/Fireball.luau`

*Instant damage at range.*

```lua
--[[
	Fireball — instant damage at range.
	The simplest shape in the framework, and deliberately first: it proves the pipeline
	(intent -> validation -> effect) without any of the timing machinery a DoT needs.
]]
return {
	id = "FIREBALL",
	displayName = "Fireball",
	description = "Hurls a bolt of fire that burns a single target.",
	cost = { mana = 25 },
	cooldown = 3,
	castTime = 0.4,
	range = 60,
	effects = {
		{ kind = "damage", amount = 45, radius = 0 },
	},
}
```

### `src/shared/abilities/Poison.luau`

*Damage over time, as a debuff.*

```lua
--[[
	Poison — damage over time, applied as a debuff.
	This is the ability that stops the framework being a damage-dealer with extra steps: it
	only works if the EffectSystem can hold state on a character across several seconds and
	replicate that state to the client.
]]
return {
	id = "POISON",
	displayName = "Poison",
	description = "Coats the target in toxin. Damage continues after the hit.",
	cost = { mana = 20 },
	cooldown = 6,
	castTime = 0,
	range = 40,
	effects = {
		{ kind = "dot", amount = 6, duration = 4, interval = 1 },
	},
}
```

### `src/shared/abilities/Dash.luau`

*Server-resolved movement.*

```lua
--[[
	Dash — server-resolved movement.
	The movement is applied on the server. A client that asks for a dash gets one of a fixed
	length; it cannot ask for a bigger one. That is the whole point of the ability being data:
	there is no code path where a number from the client reaches a CFrame.
]]
return {
	id = "DASH",
	displayName = "Dash",
	description = "Surges forward, closing distance quickly.",
	cost = { stamina = 30 },
	cooldown = 5,
	castTime = 0,
	range = 0,
	effects = {
		{ kind = "dash", distance = 32, duration = 0.25 },
	},
}
```

### `src/shared/abilities/Heal.luau`

*Support, with the longest cast in the catalog.*

```lua
--[[
	Heal — support, with the longest cast in the catalog.
	A 1.2s cast is what makes interruption (Config.CAST.cancelOnDamage) a real mechanic rather
	than a line of code nobody ever hits. It is here as much to exercise that path as to heal.
]]
return {
	id = "HEAL",
	displayName = "Heal",
	description = "Mends the caster's wounds. Takes a moment to take hold.",
	cost = { mana = 40 },
	cooldown = 8,
	castTime = 1.2,
	range = 0,
	effects = {
		{ kind = "heal", amount = 45 },
	},
}
```

### `src/shared/abilities/init.luau`

*The catalog: a thin shell around the tested builder.*

```lua
--[[
	init.luau — the ability catalog.

	Thin on purpose. Everything that can be tested lives in AbilityDefinition.buildCatalog; what
	is left here is only the part that cannot be, because it needs Roblox: the requires.

	The Config line is not decoration. validate() reports "init was never called" for every
	definition when no config has been injected, and this file validates while it loads — that is,
	before any other module has had the chance to call init. Without it every definition fails,
	buildCatalog returns nil, and the game refuses to start over a config that was simply never
	handed over. That was the bug: the framework made the config injectable, and then the one
	place that validates at load time never injected it.
]]
local AbilityDefinition = require(script.Parent.AbilityDefinition)
local Config = require(script.Parent.Config)

local definitions = {
	require(script.Fireball),
	require(script.Poison),
	require(script.Dash),
	require(script.Heal),
}

-- Must run before validation. The second argument is nil on purpose: the catalog is what we are
-- about to build, and passing a previous one would hide a stale table behind a fresh one.
AbilityDefinition.init(Config, nil)

local catalog, errors, warnings = AbilityDefinition.buildCatalog(definitions)
for _, message in ipairs(warnings) do
	warn(string.format("[ability-kit] %s", message))
end
if catalog == nil then
	-- Refusing to start is the point: every later phase reads this table, so one wrong entry
	-- here surfaces much later as a mysterious bug three modules away from its cause.
	error(
		string.format(
			"[ability-kit] the ability catalog is invalid, refusing to start:\n  %s",
			table.concat(errors, "\n  ")
		),
		0
	)
end

-- Register it, so get(id) answers from the moment this module is required.
AbilityDefinition.init(Config, catalog)

return catalog
```

### `tests/AbilityDefinitionSpec.luau`

*32 cases, runnable with no Studio.*

```lua
--[[
	AbilityDefinitionSpec.luau — runs with `luau tests/AbilityDefinitionSpec.luau`.
	No Studio, no Roblox, no dependencies. That is only possible because the module under test
	loads nothing: the config and the catalog are injected below.
]]

local TestKit = require("./TestKit")
-- Paths must be literal strings: the Luau CLI's require-by-string cannot resolve a
-- concatenated path, which is why the four abilities are listed out below instead of looped.
local AbilityDefinition = require("../src/shared/AbilityDefinition")
local Config = require("../src/shared/Config")

local T = TestKit.new("AbilityDefinition")

-- A definition that must pass. Each case starts from this and breaks exactly one thing, so a
-- failure points at one rule instead of at "the big table I pasted".
local function valid()
	return {
		id = "TEST_ABILITY",
		displayName = "Test Ability",
		description = "exists only in this file",
		cost = { mana = 10 },
		cooldown = 1,
		castTime = 0,
		range = 30,
		effects = { { kind = "damage", amount = 10, radius = 0 } },
	}
end

local function validate(def)
	AbilityDefinition.init(Config, {})
	return AbilityDefinition.validate(def)
end

-- ===== the legal path =====

T("a well-formed definition produces no errors and no warnings", function()
	local errors, warnings = validate(valid())
	assert(#errors == 0, "unexpected errors: " .. table.concat(errors, " | "))
	assert(#warnings == 0, "unexpected warnings: " .. table.concat(warnings, " | "))
end)

T("the four shipped abilities are all legal", function()
	-- Loaded by hand rather than in a loop: require-by-string needs a literal path, and a
	-- dynamic one fails as a load error that looks like a missing file.
	local shipped = {
		FIREBALL = require("../src/shared/abilities/Fireball"),
		POISON = require("../src/shared/abilities/Poison"),
		DASH = require("../src/shared/abilities/Dash"),
		HEAL = require("../src/shared/abilities/Heal"),
	}
	AbilityDefinition.init(Config, {})
	for name, definition in pairs(shipped) do
		local errors = AbilityDefinition.validate(definition)
		assert(#errors == 0, name .. " should be legal, got: " .. table.concat(errors, " | "))
	end
	assert(shipped.FIREBALL.id == "FIREBALL", "the definition must carry its own id")
end)

-- ===== errors =====

T("a definition that is not a table is rejected", function()
	local errors = validate("not a table")
	assert(#errors == 1 and errors[1]:find("not a table"), "should say it is not a table")
end)

T("a missing id is an error", function()
	local def = valid()
	def.id = nil
	local errors = validate(def)
	assert(#errors > 0, "an ability with no id is unreachable, so it must be rejected")
end)

T("an empty id is an error", function()
	local def = valid()
	def.id = ""
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a missing displayName is an error", function()
	local def = valid()
	def.displayName = nil
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a negative cooldown is an error", function()
	local def = valid()
	def.cooldown = -1
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a negative castTime is an error", function()
	local def = valid()
	def.castTime = -0.5
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a cost naming an unknown resource pool is an error", function()
	local def = valid()
	def.cost = { honk = 10 }
	local errors = validate(def)
	assert(#errors > 0 and table.concat(errors):find("honk"), "should name the bad pool")
end)

T("a cost larger than the pool maximum is an error", function()
	local def = valid()
	def.cost = { mana = Config.RESOURCES.mana.max + 1 }
	local errors = validate(def)
	assert(#errors > 0, "an ability nobody can ever cast is a definition bug")
end)

T("a negative cost is an error", function()
	local def = valid()
	def.cost = { mana = -5 }
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("zero effects is an error", function()
	local def = valid()
	def.effects = {}
	local errors = validate(def)
	assert(#errors > 0 and table.concat(errors):find("does nothing"), "should say it does nothing")
end)

T("an unknown effect kind is an error", function()
	local def = valid()
	def.effects = { { kind = "kaboom", amount = 10 } }
	local errors = validate(def)
	assert(#errors > 0 and table.concat(errors):find("kaboom"), "should name the unknown kind")
end)

T("damage with no amount is an error", function()
	local def = valid()
	def.effects = { { kind = "damage" } }
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("damage beyond the sanity limit is an error", function()
	local def = valid()
	def.effects = { { kind = "damage", amount = Config.EFFECT_LIMITS.maxDamage + 1 } }
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a DoT with no interval is an error: it would never tick", function()
	local def = valid()
	def.effects = { { kind = "dot", amount = 5, duration = 3 } }
	local errors = validate(def)
	assert(#errors > 0 and table.concat(errors):find("never ticks"), "should say it never ticks")
end)

T("a DoT longer than the limit is an error", function()
	local def = valid()
	def.effects = {
		{ kind = "dot", amount = 5, duration = Config.EFFECT_LIMITS.maxDuration + 1, interval = 1 },
	}
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a buff with no stat is an error", function()
	local def = valid()
	def.effects = { { kind = "buff", multiplier = 1.5, duration = 5 } }
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("a dash with no distance is an error", function()
	local def = valid()
	def.effects = { { kind = "dash", duration = 0.2 } }
	assert(#validate(def) > 0, "this definition must be rejected, not silently accepted")
end)

T("validating before init returns an error instead of crashing", function()
	AbilityDefinition.init(nil, nil)
	local errors = AbilityDefinition.validate(valid())
	assert(#errors > 0 and table.concat(errors):find("init"), "should say init was never called")
end)

T("two abilities sharing an id are caught on an ARRAY, the shape the catalog passes", function()
	-- This is the case that was code dead: iterating an array yields numeric keys, which are
	-- unique by construction, so keying the check on the table key could never collide.
	local a, b = valid(), valid()
	a.id, b.id = "SAME_ID", "SAME_ID"
	AbilityDefinition.init(Config, {})
	local errors = AbilityDefinition.validateCatalog({ a, b })
	assert(#errors > 0, "a duplicate id makes the second ability unreachable forever")
	assert(table.concat(errors):find("duplicate"), "the error must say what is wrong")
	assert(table.concat(errors):find("SAME_ID"), "and name the id that is duplicated")
end)

T("two abilities sharing an id are caught on a DICT too", function()
	local a, b = valid(), valid()
	a.id, b.id = "SAME_ID", "SAME_ID"
	AbilityDefinition.init(Config, {})
	local errors = AbilityDefinition.validateCatalog({ FIRST = a, SECOND = b })
	assert(#errors > 0, "the dict shape must be checked as well")
end)

T("a non-table entry is reported instead of crashing the catalog check", function()
	AbilityDefinition.init(Config, {})
	local errors = AbilityDefinition.validateCatalog({ valid(), "not a table" })
	assert(#errors > 0, "a junk entry must be reported, not thrown")
	assert(table.concat(errors):find("not a table"), "and it must say so in plain words")
end)

-- ===== warnings, not errors =====

T("instant, free, hard-hitting damage is a WARNING, not an error", function()
	local def = valid()
	def.cooldown = 0
	def.castTime = 0
	def.cost = nil
	def.effects = { { kind = "damage", amount = 40 } }
	local errors, warnings = validate(def)
	assert(#errors == 0, "it is legal, it is just probably a mistake")
	assert(#warnings > 0 and table.concat(warnings):find("spammable"), "should call it spammable")
end)

T("a cast with no cooldown is only a warning", function()
	local def = valid()
	def.castTime = 1.5
	def.cooldown = nil
	local errors, warnings = validate(def)
	assert(#errors == 0, "a long cast with no cooldown is legal, it is only worth flagging")
	assert(#warnings > 0, "expected this to be reported as a warning")
end)

-- ===== lookup =====

T("get returns the definition it was given, and nil for anything else", function()
	local def = valid()
	AbilityDefinition.init(Config, { TEST_ABILITY = def })
	assert(AbilityDefinition.get("TEST_ABILITY") == def, "get must return the same table")
	assert(AbilityDefinition.get("NOPE") == nil, "an unknown id must return nil")
	assert(AbilityDefinition.get(nil) == nil, "a nil id must not throw")
end)

T(
	"get works on the dict shape the catalog builds, and fails on the array it must not be",
	function()
		-- The contract the catalog has to honour. If it returned the array it collects, every
		-- lookup would be nil and nothing would say why.
		local fireball = require("../src/shared/abilities/Fireball")
		local heal = require("../src/shared/abilities/Heal")

		local asArray = { fireball, heal }
		local asDict = {}
		for _, definition in ipairs(asArray) do
			asDict[definition.id] = definition
		end

		AbilityDefinition.init(Config, asDict)
		assert(AbilityDefinition.get("FIREBALL") == fireball, "the dict must be keyed by id")

		AbilityDefinition.init(Config, asArray)
		assert(
			AbilityDefinition.get("FIREBALL") == nil,
			"an array cannot be looked up by id: this is the bug the dict shape exists to prevent"
		)
	end
)

T("a definition with no id is REPORTED, not a crash", function()
	-- seen[definition.id] = true with a nil id is "table index is nil". The guard around the
	-- message label did not cover the write, which is how this shipped.
	AbilityDefinition.init(Config, {})
	local ok, result = pcall(function()
		return AbilityDefinition.validateCatalog({
			{ displayName = "no id here", effects = { { kind = "damage", amount = 5 } } },
		})
	end)
	assert(ok, "validateCatalog must survive an entry with no id, got: " .. tostring(result))
	assert(#result > 0, "and it must report the missing id")
	assert(table.concat(result):find("id"), "the error has to mention the id")
end)

T("buildCatalog reports a missing init instead of building a broken catalog", function()
	-- Bug 3's test, and the reason the build lives here at all. The suite calls init() by hand
	-- everywhere, which is exactly why it missed this: the real catalog validates during
	-- require, before any other module has had the chance to call init.
	AbilityDefinition.init(nil, nil)
	local catalog, errors =
		AbilityDefinition.buildCatalog({ require("../src/shared/abilities/Fireball") })
	assert(catalog == nil, "an unusable catalog must come back as nil, not as a table")
	assert(#errors > 0, "and the reason must be reported")
	assert(table.concat(errors):find("init"), "specifically, that init was never called")
	AbilityDefinition.init(Config, {})
end)

T("buildCatalog returns a dict keyed by id for a valid array", function()
	local a, b = valid(), valid()
	a.id, b.id = "ALPHA", "BETA"
	AbilityDefinition.init(Config, {})
	local catalog, errors = AbilityDefinition.buildCatalog({ a, b })
	assert(#errors == 0, "a valid array must produce no errors")
	assert(catalog.ALPHA == a and catalog.BETA == b, "and be keyed by definition.id")
end)

T("buildCatalog refuses to build at all when two ids collide", function()
	-- The alternative — return the dict and let the second entry overwrite the first — is how
	-- a duplicate becomes undetectable: after indexing, the evidence is gone.
	local a, b = valid(), valid()
	a.id, b.id = "TWICE", "TWICE"
	AbilityDefinition.init(Config, {})
	local catalog, errors = AbilityDefinition.buildCatalog({ a, b })
	assert(catalog == nil, "a duplicate must produce no catalog at all")
	assert(#errors > 0, "and say why")
end)

T("buildCatalog accepts the same input shapes validateCatalog does", function()
	-- The contract has to match. With ipairs a dict validated clean and then built an EMPTY
	-- catalog, with no error anywhere: validation said yes, the build returned nothing.
	local a, b = valid(), valid()
	a.id, b.id = "ALPHA", "BETA"
	AbilityDefinition.init(Config, {})

	local fromArray, arrayErrors = AbilityDefinition.buildCatalog({ a, b })
	assert(#arrayErrors == 0, "an array must keep working")
	assert(fromArray.ALPHA == a and fromArray.BETA == b, "and be keyed by id")

	local fromDict, dictErrors = AbilityDefinition.buildCatalog({ FIRST = a, SECOND = b })
	assert(#dictErrors == 0, "a dict is legal input, same as for validateCatalog")
	assert(next(fromDict) ~= nil, "a dict must not silently produce an empty catalog")
	assert(fromDict.ALPHA == a and fromDict.BETA == b, "and must be keyed by definition.id")
end)

return T.report()
```

## How to test it

Nothing here needs Studio. From the project folder:

```
luau tests/run.luau          # 32 cases
selene src/ tests/           # 0 errors, 0 warnings
stylua --check src/ tests/   # prints nothing
```

In Studio the tree lands under `ReplicatedStorage.AbilityKit` (verified: the catalog loads
and `get("FIREBALL")` answers). There is nothing to click yet — this phase is data and
rules.

## What review found in this phase

Four bugs were found by reading, not by running. They fall into **two shapes**, and every
one of them passed the test suite first:

| # | Bug | Shape |
|---|-----|-------|
| 1 | `validateCatalog` keyed duplicates on the table key, which on an array is 1, 2, 3… — unique by construction, so the check could never fire | a check that cannot fire |
| 4 | `seen[definition.id] = true` with a nil id crashed, and the guard one line above protected the message, not the write | a guard that misses its own case |
| 2 | The catalog returned an array; `get(id)` looked up by string, so it returned nil for every ability | a dependency never delivered |
| 3 | The config became injectable, and the catalog — the one file that validates at load — never injected it, so the game refused to start | a dependency never delivered |

The two middle rows are worth more than the fixes. **The test agreed with the bug**: it built
`{ [1] = a, [2] = b }` — a table whose keys are already unique, which is the shape that
worked, not the shape the catalog passes. Code and test shared one misreading, so they
confirmed each other.

The same held for the rest: the suite called `init()` by hand in every case, which is
exactly what the real catalog cannot do. That is why the build now lives in a function —
`buildCatalog` — instead of in the file that needs Roblox. **Untestable code shipped a
missing dependency, so the fix was to make it testable, not to test it harder.**

## The numbers

- Tests: **32**, in 1 suite, no Studio
- Lines: **585 source + 419 tests** = 1004
- Commits: **5** (scaffold, phase 1, and three rounds of review fixes)
- selene: 0 errors, 0 warnings · stylua: clean

## Still not verified

No full game boot: there is no Bootstrap yet, so the catalog has only been loaded the way
the boot will load it — by `require`, from the same data model. That path is verified; the
boot itself arrives with the server phase.
