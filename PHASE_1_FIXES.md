# Phase 1 — the two review bugs, fixed

Both were real. Both reproduced on the machine before any edit, and both are shown here with
the same probe run against the corrected code.

## Bug 1 — `validateCatalog` could not detect a duplicate

`for id, definition in pairs(catalog)` gives the **table key**, and on an array that key is
1, 2, 3… Table keys are unique by construction, so `seen[id]` could never collide. The check
read like a guarantee and enforced nothing.

```
before:   { Fireball, Fireball }  ->  0 errors
after:    { Fireball, Fireball }  ->  1 error: FIREBALL: duplicate id 'FIREBALL'
```

It now keys on `definition.id`, iterates with `pairs` so both an array and a dict are
accepted, uses the definition's own id as the message prefix, and guards non-table entries:

```
{ Fireball, "junk" }  ->  <entry at key 2>: definition is not a table
```

## Bug 2 — `get()` returned nil for every ability, always

The catalog returned an array; `get(id)` does `catalog[id]` with a string key. On an array
that is nil — for every ability, in every phase that followed.

```
before:   catalog["FIREBALL"]                         ->  nil
after:    AbilityDefinition.get("FIREBALL").displayName  ->  Fireball
          AbilityDefinition.get("NOPE")                   ->  nil   (still correct)
```

The catalog now validates the collected array **before** indexing, refuses to start if the
catalog is invalid, and builds a dict keyed by `definition.id`.

## Why the existing test passed while the code was broken

The duplicate test built `{ [1] = a, [2] = b }` — a table whose keys are already unique, which
is the shape the check happened to work on and **not** the shape the catalog actually passes.
The test was wrong in the same way the code was, so the two agreed with each other and neither
was right. The new cases use an array, which is what `init.luau` passes.

## The corrected files

### `src/shared/AbilityDefinition.luau`

*`validateCatalog` is the changed part; everything else is as it was.*

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
		if type(definition) == "table" and type(definition.id) == "string" and definition.id ~= "" then
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

		if seen[definition.id] then
			table.insert(errors, string.format("%s: duplicate id '%s'", label, tostring(definition.id)))
		end
		seen[definition.id] = true

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

### `src/shared/abilities/init.luau`

*Rewritten: validates the array, refuses to start on error, returns a dict by id.*

```lua
--[[
	init.luau — the ability catalog.

	Two things this file must get right, and both were wrong in review:

	1. The game looks abilities up BY ID. An array is not a lookup table: `catalog["FIREBALL"]`
	   on an array is nil, so every lookup would have missed. This returns a dict keyed by
	   definition.id, which is the key AbilityDefinition.get() reads.

	2. It validates BEFORE indexing. Two entries can share an id inside the array, and building
	   the dict first would let one silently overwrite the other — after which the duplicate is
	   undetectable, because the array that carried the evidence is gone. The check has to run on
	   the array, while both copies still exist.

	Requiring the ability modules is why this file is one of very few allowed to require others.
]]

local AbilityDefinition = require(script.Parent.AbilityDefinition)

local definitions = {
	require(script.Fireball),
	require(script.Poison),
	require(script.Dash),
	require(script.Heal),
}

-- Validation runs on the array, not on the built dict.
local errors, warnings = AbilityDefinition.validateCatalog(definitions)
for _, message in ipairs(warnings) do
	warn(string.format("[ability-kit] %s", message))
end
if #errors > 0 then
	-- Refusing to start is the point. Every later phase reads this table, so one wrong entry
	-- here shows up much later as a mysterious bug three modules away from its cause.
	error(string.format(
		"[ability-kit] the ability catalog is invalid, refusing to start:\n  %s",
		table.concat(errors, "\n  ")
	), 0)
end

local catalog = {}
for _, definition in ipairs(definitions) do
	catalog[definition.id] = definition
end

return catalog
```

### `tests/AbilityDefinitionSpec.luau`

*27 cases now, including the two that would have caught these.*

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

T("get works on the dict shape the catalog builds, and fails on the array it must not be", function()
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
end)

return T.report()
```

## State after the fixes

- `luau tests/run.luau` -> **27 passed, 0 failed**, 1 of 1 suites green
- `selene src/ tests/` -> **0 errors, 0 warnings**
- `stylua --check` -> clean

Neither bug could have been caught in Studio: the first fails as *silence*, and the
second fails as `nil` three modules away from its cause. They were caught by reading.
