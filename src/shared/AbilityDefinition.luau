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
local EffectSystem = nil -- injected through init, like the catalog and the config
local TargetResolver

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

-- The fields a definition may carry. Anything else is reported, because a typo'd field is
-- IGNORED, not rejected: `casttime = 5` leaves the ability with no cast time at all, and the
-- difference between that and a deliberate custom field cannot be seen from here. Hence a
-- warning rather than an error — the framework says what it ignores and lets the game decide.
AbilityDefinition.ROOT_FIELDS = {
	"id",
	"displayName",
	"description",
	"cost",
	"cooldown",
	"castTime",
	"range",

	"targeting",
	"effects",
}

-- Per effect kind. This is the list that has to stay honest: if a kind reads a field at runtime,
-- that field belongs here, or the validator is describing a shape the code does not use.
AbilityDefinition.EFFECT_FIELDS = {
	damage = { "kind", "amount", "radius" },
	dot = { "kind", "amount", "duration", "interval", "stack" },
	heal = { "kind", "amount", "radius" },
	buff = { "kind", "stat", "multiplier", "duration", "stack" },
	debuff = { "kind", "stat", "multiplier", "duration", "stack" },
	dash = { "kind", "distance", "duration" },
}

AbilityDefinition.CATALOG = nil
AbilityDefinition.CONFIG = nil

-- Called once at startup. The config is injected rather than required so that a test can hand
-- this module any limits it wants to exercise, including ones no shipped config would use.
function AbilityDefinition.init(config, catalog, effectSystem, targetResolver)
	AbilityDefinition.CONFIG = config
	AbilityDefinition.CATALOG = catalog
	-- Optional: without it, `stack` values go unchecked rather than checked against a copy.
	EffectSystem = effectSystem
	-- Optional too, and for the same reason: without it, `targeting` goes unchecked. The vocabulary
	-- is injected rather than copied because a list that exists in two files is a list that will
	-- disagree one day, and the day it does is the day a typo validates clean.
	TargetResolver = targetResolver
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

-- Names an unknown field and, when the difference is only case, names the one that was meant.
-- The second half matters more than it looks: the ability still runs, so the only trace of a typo
-- is this line. Saying "unknown field" alone leaves the reader to spot it.
local function sortedLetters(text)
	local letras = {}
	for i = 1, #text do
		table.insert(letras, string.sub(text, i, i))
	end
	table.sort(letras)
	return table.concat(letras)
end

local function unknownField(where, name, allowed)
	local texto = tostring(name)
	local lower = string.lower(texto)
	local firma = sortedLetters(lower)

	for _, candidate in ipairs(allowed) do
		local lowerCandidate = string.lower(candidate)
		-- Equal ignoring case covers `casttime` for `castTime`. Equal with the letters sorted
		-- covers a transposition, `raduis` for `radius`, which is the typo that actually happens
		-- when someone types a word they know. A genuine anagram of a real field would also match,
		-- which is a wrong suggestion in a warning — cheap, and worth the transposition it catches.
		if lowerCandidate == lower or sortedLetters(lowerCandidate) == firma then
			return string.format(
				"%s: unknown field '%s' — did you mean '%s'? It is ignored, so the ability will behave as if it were absent",
				where,
				texto,
				candidate
			)
		end
	end
	return string.format(
		"%s: unknown field '%s' is ignored, so the ability will behave as if it were absent",
		where,
		tostring(name)
	)
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
	-- Zero stays legal on purpose: Dash and Heal both declare range = 0, meaning "not aimed at
	-- anything". Only a negative or a non-number is a mistake.
	if definition.range ~= nil and (type(definition.range) ~= "number" or definition.range < 0) then
		table.insert(errors, "range must be a number >= 0 when present")
	end
	if type(definition.range) == "number" and definition.range > cfg.EFFECT_LIMITS.maxRange then
		table.insert(
			errors,
			string.format("range exceeds the sanity limit of %d", cfg.EFFECT_LIMITS.maxRange)
		)
	end

	-- Targeting. Absent means "self", which is the behaviour every definition had before this field
	-- existed — and the mirror rules below make that default safe: a definition that forgot the field
	-- and carries an offensive effect is a self+offensive contradiction, so it errors rather than
	-- silently burning its caster. The omission is caught exactly where it would have hurt.
	-- Absent means "self", and the rules run on the EFFECTIVE value rather than only when the field
	-- is written. Otherwise the default would not be safe at all: a Fireball that forgot the field
	-- would be silently self-cast, which is the phase 5 bug wearing a default's clothes.
	--
	-- Without a TargetResolver injected, targeting goes UNCHECKED rather than erroring -- the same
	-- precedent as `stack` without an EffectSystem. A check that cannot run is a check the caller
	-- opted out of, and inventing an error for it would make every fixture that does not care fail.
	local targeting = definition.targeting or "self"
	if TargetResolver ~= nil then
		if not TargetResolver.isTargeting(targeting) then
			table.insert(
				errors,
				string.format("unknown targeting '%s'", tostring(definition.targeting))
			)
		else
			local offensive = nil
			for _, effect in ipairs(definition.effects or {}) do
				if type(effect) == "table" and TargetResolver.isOffensive(effect.kind) then
					offensive = effect.kind
					break
				end
			end
			if targeting == "self" and offensive ~= nil then
				table.insert(
					errors,
					string.format(
						"self-targeting ability with offensive effect '%s': either a typo or a mechanic that needs its own name",
						offensive
					)
				)
			elseif targeting == "raycast" and offensive == nil then
				table.insert(
					errors,
					"raycast-targeting ability with no offensive effect: the ray is decorative and the effects would go to the caster anyway"
				)
			end
		end
	end

	-- Unknown root fields. Warned, not rejected: see ROOT_FIELDS above.
	for name in pairs(definition) do
		if not table.find(AbilityDefinition.ROOT_FIELDS, name) then
			table.insert(warnings, unknownField("definition", name, AbilityDefinition.ROOT_FIELDS))
		end
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
				-- Dash.luau uses duration, so it has to be checked. Leaving it out made the
				-- comment above a promise the code did not keep: duration = "fast" ran fine.
				if not isPositiveNumber(effect.duration) then
					table.insert(errors, where .. ".duration must be a positive number")
				end
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

	-- `stack` is only meaningful on what lives over time, and only with a value the EffectSystem
	-- knows. On an instant effect, where there is nothing to stack, the whitelist reports it as an
	-- unknown field, which is the right answer rather than a special case here.
	if EffectSystem ~= nil and type(definition.effects) == "table" then
		for index, effect in ipairs(definition.effects) do
			local where = string.format("effects[%d]", index)
			local timed = type(effect) == "table"
				and (effect.kind == "dot" or effect.kind == "buff" or effect.kind == "debuff")
			if timed and effect.stack ~= nil then
				local known = false
				for _, policy in ipairs(EffectSystem.STACKING) do
					if effect.stack == policy then
						known = true
						break
					end
				end
				if not known then
					table.insert(
						errors,
						string.format(
							"%s.stack '%s' is not one of: %s",
							where,
							tostring(effect.stack),
							table.concat(EffectSystem.STACKING, ", ")
						)
					)
				end
			end
		end
	end

	-- Unknown fields inside an effect, checked once its kind is known to be a real one. This is
	-- the per-kind half of the whitelist: `raduis` on a damage effect validated clean and then
	-- did nothing, because the real field it meant was never read.
	if type(definition.effects) == "table" then
		for index, effect in ipairs(definition.effects) do
			if type(effect) == "table" then
				local allowed = AbilityDefinition.EFFECT_FIELDS[effect.kind]
				if allowed then
					for name in pairs(effect) do
						if not table.find(allowed, name) then
							table.insert(
								warnings,
								unknownField(string.format("effects[%d]", index), name, allowed)
							)
						end
					end
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
			if
				effect.kind == "damage"
				and (effect.amount or 0) >= cfg.EFFECT_LIMITS.spammableDamageThreshold
			then
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

	if next(catalog) == nil then
		-- A warning, not an error: a game under construction can legitimately start with none.
		-- Worth saying out loud all the same, because the kit will then load, run, and do nothing
		-- at all — which is hard to tell apart from a broken build.
		table.insert(warnings, "the catalog is empty: the kit will load and no ability will exist")
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
