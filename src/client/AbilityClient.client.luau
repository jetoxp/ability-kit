--[[
	AbilityClient.client.luau — the client's whole job, for now.

	Two things and no more: turn a keypress into an intent, and keep the last snapshot the server
	sent. Every decision — is it ready, can you afford it, who does it hit — belongs to the server,
	and this file has no way to make any of them.

	There is no UI yet. Drawing the bars and the cooldown sweeps is phase 7, and this file exists so
	that phase has something to draw from.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local kit = ReplicatedStorage:WaitForChild("AbilityKit")
local Config = require(kit.Config)
local Net = require(kit.Net)
local ClientState = require(script.Parent.ClientState)

local netFolder = ReplicatedStorage:WaitForChild(Net.FOLDER)
local intentRemote = netFolder:WaitForChild(Net.INTENT)
local stateRemote = netFolder:WaitForChild(Net.STATE)

ClientState.changed = Instance.new("BindableEvent")

stateRemote.OnClientEvent:Connect(function(state)
	ClientState.set(state)
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
