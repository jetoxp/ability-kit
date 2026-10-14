--[[
	AbilityClient.client.luau — the client's whole job, for now.

	Three things and no more: turn a keypress into an intent, keep the last two snapshots the server
	sent, and hand them to the HUD once a frame. Every decision — is it ready, can you afford it, who
	does it hit — belongs to the server, and this file has no way to make any of them.

	The HUD is split in two on purpose. `HudPresenter` turns the snapshots into a description of the
	screen and has a suite; `HudRenderer` writes instances from that description and decides nothing.
	This file is only the wire between the two and the clock they are not allowed to read.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local kit = ReplicatedStorage:WaitForChild("AbilityKit")
local Config = require(kit.Config)
local Net = require(kit.Net)

-- THE ORDER IS THE POINT. `ClientState.changed` is created here, and the HUD is required after it:
-- phase 5 left a note that a module requiring ClientState earlier in the load order sees `nil`, and
-- the HUD is the consumer that note was written for. Requiring the HUD first would work today and
-- would be the kind of order that breaks on the day somebody moves a line.
local player = Players.LocalPlayer
local ClientState = require(script.Parent.ClientState)
ClientState.changed = Instance.new("BindableEvent")

local HudPresenter = require(script.Parent.HudPresenter)
local HudRenderer = require(script.Parent.HudRenderer)

-- Names come from the catalog, not from the snapshot: the snapshot carries state, and the
-- definitions are already replicated because `src/shared` maps into ReplicatedStorage. See D4.
local Catalog = require(kit.abilities)

local netFolder = ReplicatedStorage:WaitForChild(Net.FOLDER)
local intentRemote = netFolder:WaitForChild(Net.INTENT)
local stateRemote = netFolder:WaitForChild(Net.STATE)

--[[
	The state handler, wrapped, and for the same reason the server's heartbeat is: **a callback that
	throws is disconnected.** A single error in here — in the state itself, or in anything listening to
	`changed`, which fires from inside this callback — kills the connection on the first snapshot and
	the client then receives nothing for the rest of the session, silently. The failure looks exactly
	like a server that stopped talking.

	That is not a hypothetical: it is what happened, and it took a listener on the same remote from
	outside the script to prove the server was talking the whole time. The error is logged loudly
	because the alternative is a client that has stopped listening and does not say so.
]]
stateRemote.OnClientEvent:Connect(function(state)
	ClientState.received += 1
	local ok, err = pcall(function()
		ClientState.set(state)
	end)
	if not ok then
		warn(string.format("[ability-kit] the state handler failed: %s", tostring(err)))
	end
end)

-- The slots are the keybinds. One, two, three, four — and nothing more clever than that, because
-- a client that decides what "clever" means is a client inventing mechanics.
local slotKeys = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- While a text box has focus the key belongs to the text box. Checking this is not optional:
	-- without it, typing "1" in chat fires an ability.
	if gameProcessed then
		return
	end

	local slot = table.find(slotKeys, input.KeyCode)
	if slot == nil or slot > Config.MAX_EQUIPPED then
		return
	end

	-- The intent is the whole message: an action and a slot. No cost, no target, no direction.
	intentRemote:FireServer({ action = "activate", slot = slot })
end)

--[[
	The HUD, once a frame.

	The clock lives HERE and nowhere else: the presenter is told how long ago the latest snapshot
	arrived, and the renderer is told nothing. That is what keeps the arithmetic testable and the
	drawing dumb, and it is why `os.clock` appears exactly once in the client.
]]
local hud = HudRenderer.new(player:WaitForChild("PlayerGui"))
local arrivedAt = os.clock()

ClientState.changed.Event:Connect(function()
	arrivedAt = os.clock()
end)

RunService.RenderStepped:Connect(function()
	if ClientState.latest == nil then
		return
	end
	local description = HudPresenter.draw(
		ClientState.previous,
		ClientState.latest,
		os.clock() - arrivedAt,
		Config.TICK_RATE,
		Catalog
	)
	hud:render(description)
end)
