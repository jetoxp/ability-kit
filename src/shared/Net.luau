--[[
	Net.luau — the wire between the two sides, described once.

	One remote up and one remote down. The up remote carries exactly one shape:

	    { action = "activate", slot = 3 }

	and nothing else. No cost, no target, no direction, no damage. Every one of those is decided on
	the server from a definition the client cannot see. A client that sends a cost is not a client
	this kit is written for, and the validator below is what says so rather than a comment hoping.

	The names live here so the two sides cannot drift, and the shape check is a pure function so it
	can be tested without an engine — which is the only reason a client's payload gets validated
	before it reaches anything that matters.
]]

local Net = {}

Net.FOLDER = "AbilityKitNet"
Net.INTENT = "Intent" -- client -> server
Net.STATE = "State" -- server -> client

-- The only action there is. An ability is activated; it is never "used with 40 damage".
Net.ACTIONS = { "activate" }

Net.MAX_SLOT = nil -- set from Config.MAX_EQUIPPED by Net.configure

function Net.configure(config)
	Net.MAX_SLOT = config.MAX_EQUIPPED
end

--[[
	Checks a client's payload and returns (ok, value): on success `value` is the normalised intent,
	and on failure it is the reason string that goes to the log. Two different things in one slot,
	which is a shape worth naming rather than leaving to be inferred.

	This is the whole of the client-facing trust boundary, and it is deliberately dull: an action
	from a known list, and a slot within range. Anything else is refused, including a payload that
	carries an extra field — the only way to keep a future field from becoming a future exploit is
	to reject what this version does not know.

	The reason is for the log. It is never sent back: a client that can read why it was refused is a
	client being taught how to ask.
]]
function Net.validateIntent(payload)
	if type(payload) ~= "table" then
		return false, "intent is not a table"
	end

	if type(payload.action) ~= "string" then
		return false, "intent has no action"
	end

	local known = false
	for _, action in ipairs(Net.ACTIONS) do
		if payload.action == action then
			known = true
			break
		end
	end
	if not known then
		return false, string.format("unknown action '%s'", tostring(payload.action))
	end

	-- An integer, not merely a number. `1.5` would pass a range check and then find no ability, which
	-- is a silent no-op where a refusal belongs: the boundary is cheaper to tighten than to explain.
	if type(payload.slot) ~= "number" or payload.slot ~= payload.slot then
		return false, "slot must be a number"
	end
	if payload.slot ~= math.floor(payload.slot) then
		return false, string.format("slot %s is not a slot", tostring(payload.slot))
	end
	if payload.slot < 1 or (Net.MAX_SLOT ~= nil and payload.slot > Net.MAX_SLOT) then
		return false, string.format("slot %s is out of range", tostring(payload.slot))
	end

	-- No extra fields. Stated as a rule rather than assumed, because "it only reads slot" stops
	-- being true the moment somebody adds a convenient field to the client's payload.
	for name in pairs(payload) do
		if name ~= "action" and name ~= "slot" then
			return false, string.format("intent carries unexpected field '%s'", tostring(name))
		end
	end

	return true, { action = payload.action, slot = payload.slot }
end

return Net
