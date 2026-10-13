--[[
	NetSpec.luau — runs with `luau tests/NetSpec.luau`. No Studio.

	The client-facing trust boundary. Short, and the point of every case is that a payload this
	version does not recognise is refused rather than tolerated.
]]

local TestKit = require("./TestKit")
local Config = require("../src/shared/Config")
local Net = require("../src/shared/Net")

local T = TestKit.new("Net")
Net.configure(Config)

T("a well-formed intent passes and comes back normalised", function()
	local ok, intent = Net.validateIntent({ action = "activate", slot = 2 })
	assert(ok, "a known action and an in-range slot is the whole contract")
	assert(intent.action == "activate" and intent.slot == 2, "and it is returned as a plain table")
end)

T("a payload that is not a table is refused", function()
	assert(not Net.validateIntent(nil), "nil")
	assert(not Net.validateIntent("activate 2"), "a string")
	assert(not Net.validateIntent(7), "a number")
end)

T("an unknown action is refused", function()
	local ok, reason = Net.validateIntent({ action = "giveMeEverything", slot = 1 })
	assert(not ok, "an action outside the list is not an intent")
	assert(reason:find("giveMeEverything"), "and the log names it, got " .. tostring(reason))
end)

T("a slot outside the range is refused at both ends", function()
	assert(not Net.validateIntent({ action = "activate", slot = 0 }), "zero")
	assert(not Net.validateIntent({ action = "activate", slot = -1 }), "negative")
	assert(
		not Net.validateIntent({ action = "activate", slot = Config.MAX_EQUIPPED + 1 }),
		"past the end"
	)
	assert(
		Net.validateIntent({ action = "activate", slot = Config.MAX_EQUIPPED }),
		"and the last legal one passes"
	)
end)

T("a non-numeric slot is refused", function()
	assert(not Net.validateIntent({ action = "activate", slot = "2" }), "a string slot")
	assert(not Net.validateIntent({ action = "activate", slot = nil }), "no slot at all")
end)

T("an extra field is refused, which is how a future exploit is kept from becoming one", function()
	local ok, reason = Net.validateIntent({ action = "activate", slot = 1, damage = 9999 })
	assert(not ok, "the client does not get to add fields")
	assert(reason:find("damage"), "and the field is named, got " .. tostring(reason))
end)

return T.report()
