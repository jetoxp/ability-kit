--[[
	ClientState.luau — the last snapshot the server sent, and nothing else.

	It exists as a module rather than a variable inside the client script so that the UI of phase 7
	can read it without being wired into the input handling. The client has no other state, and
	deliberately no logic: it does not check a cooldown locally, does not know a cost, and cannot
	decide that an ability is ready. It asks, and it waits.
]]

local ClientState = {}

--[[
	Initialisation order, for whoever reads this in phase 6/7.

	This module is required and its fields assigned in two different places: `latest` is written by
	`set`, and `changed` is created by the client script — which requires this module and sets it on
	the next line. So a consumer that requires this module BEFORE the client script runs sees
	`changed == nil`. Guard on it (`if ClientState.changed ~= nil`), or require this from the client
	script and nowhere earlier.

	Both fields being nil until something writes them is deliberate: a module that invents a default
	state is a module that reports a state the server never sent.
]]
ClientState.latest = nil
ClientState.changed = nil -- a BindableEvent, created by the client script, for whatever draws this

function ClientState.set(state)
	ClientState.latest = state
	if ClientState.changed ~= nil then
		ClientState.changed:Fire(state)
	end
end

return ClientState
