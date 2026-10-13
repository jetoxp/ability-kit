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
