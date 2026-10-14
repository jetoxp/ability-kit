--[[
	HudRenderer.luau — writes instances from a description, and decides nothing.

	**Its signature is the enforcement.** `render(description)` receives one argument, and that argument
	contains no snapshot, no catalog and no clock — so there is nothing here to decide with. A renderer
	that cannot see what it is drawing *for* cannot quietly start drawing something else. Every branch in
	this file is "put this value in this property".

	It is the engine half of the HUD, which is why it has no suite: the numbers were tested on the other
	side of the seam, on plain tables.
]]

local HudRenderer = {}
HudRenderer.__index = HudRenderer

local PADDING = 6

local function fill(parent, colour)
	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = colour
	bar.BorderSizePixel = 0
	bar.Size = UDim2.fromScale(0, 1)
	bar.Parent = parent
	return bar
end

function HudRenderer.new(parent)
	local self = setmetatable({}, HudRenderer)

	local gui = Instance.new("ScreenGui")
	gui.Name = "AbilityKitHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = parent
	self.gui = gui

	local root = Instance.new("Frame")
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -16)
	root.Size = UDim2.fromOffset(420, 96)
	root.BackgroundTransparency = 1
	root.Parent = gui
	self.root = root

	local poolBox = Instance.new("Frame")
	poolBox.BackgroundTransparency = 1
	poolBox.Size = UDim2.new(1, 0, 0, 34)
	poolBox.Parent = root
	self.poolBox = poolBox

	local slotBox = Instance.new("Frame")
	slotBox.BackgroundTransparency = 1
	slotBox.Position = UDim2.fromOffset(0, 40)
	slotBox.Size = UDim2.new(1, 0, 0, 40)
	slotBox.Parent = root
	self.slotBox = slotBox

	local castBox = Instance.new("Frame")
	castBox.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	castBox.BorderSizePixel = 0
	castBox.Position = UDim2.fromOffset(0, 84)
	castBox.Size = UDim2.new(1, 0, 0, 8)
	castBox.Visible = false
	castBox.Parent = root
	self.castBox = castBox
	self.castFill = fill(castBox, Color3.fromRGB(240, 190, 80))

	self.pools = {}
	self.slots = {}
	return self
end

function HudRenderer:pool(name)
	local row = self.pools[name]
	if row ~= nil then
		return row
	end
	local box = Instance.new("Frame")
	box.Name = name
	box.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(0, #self.pools * 16)
	box.Size = UDim2.new(1, 0, 0, 12)
	box.Parent = self.poolBox
	row = { fill = fill(box, Color3.fromRGB(90, 150, 240)) }
	self.pools[name] = row
	return row
end

function HudRenderer:slot(index)
	local box = self.slots[index]
	if box ~= nil then
		return box
	end
	local width = 1 / 4
	local frame = Instance.new("Frame")
	frame.Name = "slot" .. tostring(index)
	frame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	frame.BorderSizePixel = 0
	frame.Position = UDim2.new((index - 1) * width, PADDING, 0, 0)
	frame.Size = UDim2.new(width, -PADDING * 2, 1, 0)
	frame.Parent = self.slotBox

	local overlay = Instance.new("Frame")
	overlay.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.AnchorPoint = Vector2.new(0, 1)
	overlay.Position = UDim2.fromScale(0, 1)
	overlay.Size = UDim2.fromScale(1, 0)
	overlay.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(235, 235, 240)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Position = UDim2.fromOffset(4, 2)
	label.Size = UDim2.new(1, -8, 1, -4)
	label.Text = ""
	label.Parent = frame

	box = { frame = frame, overlay = overlay, label = label }
	self.slots[index] = box
	return box
end

--[[
	One job per line: this value, in this property.

	The slot overlay's HEIGHT is the cooldown fraction and its text is the keybind plus the name. The
	cast bar's WIDTH is the progress. Nothing here compares, clamps or computes — those happened on the
	other side of the seam, where a suite can see them.
]]
function HudRenderer:render(description)
	for _, pool in ipairs(description.resources) do
		local row = self:pool(pool.name)
		row.fill.Size = UDim2.fromScale(pool.fraction, 1)
	end

	for index = 1, math.max(4, #description.slots) do
		local box = self:slot(index)
		local slot = description.slots[index]
		if slot ~= nil then
			box.frame.Visible = true
			box.overlay.Size = UDim2.fromScale(1, slot.fraction)
			box.label.Text = tostring(slot.slot) .. "  " .. (slot.name or slot.id or "")
			box.label.TextTransparency = slot.ready and 0 or 0.45
		else
			box.frame.Visible = false
		end
	end

	local cast = description.cast
	self.castBox.Visible = cast ~= nil
	if cast ~= nil then
		self.castFill.Size = UDim2.fromScale(cast.progress, 1)
	end
end

return HudRenderer
