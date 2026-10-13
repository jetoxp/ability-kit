--[[
	ClientState.luau — the last snapshot the server sent, and nothing else.

	It exists as a module rather than a variable inside the client script so that the UI of phase 7
	can read it without being wired into the input handling. The client has no other state, and
	deliberately no logic: it does not check a cooldown locally, does not know a cost, and cannot
	decide that an ability is ready. It asks, and it waits.
]]

local ClientState = {}

ClientState.latest = nil
ClientState.changed = nil -- a BindableEvent, created by the client, for whatever draws this

function ClientState.set(state)
	ClientState.latest = state
	if ClientState.changed ~= nil then
		ClientState.changed:Fire(state)
	end
end

return ClientState
