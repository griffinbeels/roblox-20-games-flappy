--[[
	OptionsUI.luau

	Small gear-icon menu in the top-right corner with toggle options.
	Always visible across all game states.
]]

local Players = game:GetService("Players")

local OptionsUI = {}

local localPlayer = Players.LocalPlayer
local screenGui = nil
local gearButton = nil
local panel = nil
local panelOpen = false

-- Option state and callbacks
local options = {
	ShowGhosts = true,
}
local callbacks = {} -- { [name] = { callback, ... } }
local toggleButtons = {} -- { [name] = TextButton }

local function fireCallbacks(name, value)
	if callbacks[name] then
		for _, cb in ipairs(callbacks[name]) do
			cb(value)
		end
	end
end

local function updateToggleVisual(name)
	local btn = toggleButtons[name]
	if not btn then return end
	local on = options[name]
	btn.Text = on and "ON" or "OFF"
	btn.TextColor3 = on and Color3.fromRGB(100, 255, 100) or Color3.fromRGB(255, 100, 100)
end

local function createToggleRow(parent, name, label, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = name .. "Row"
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -54, 1, 0)
	nameLabel.Position = UDim2.new(0, 8, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = label
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	local btn = Instance.new("TextButton")
	btn.Name = name .. "Toggle"
	btn.Size = UDim2.new(0, 40, 0, 24)
	btn.Position = UDim2.new(1, -48, 0.5, -12)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	btn.BorderSizePixel = 0
	btn.TextSize = 14
	btn.Font = Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = btn

	toggleButtons[name] = btn
	updateToggleVisual(name)

	btn.MouseButton1Click:Connect(function()
		options[name] = not options[name]
		updateToggleVisual(name)
		fireCallbacks(name, options[name])
	end)
end

function OptionsUI.init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "OptionsUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Gear button
	gearButton = Instance.new("TextButton")
	gearButton.Name = "GearButton"
	gearButton.Size = UDim2.new(0, 36, 0, 36)
	gearButton.Position = UDim2.new(1, -46, 0, 10)
	gearButton.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	gearButton.BackgroundTransparency = 0.3
	gearButton.BorderSizePixel = 0
	gearButton.Text = "\u{2699}"
	gearButton.TextColor3 = Color3.new(1, 1, 1)
	gearButton.TextSize = 22
	gearButton.Font = Enum.Font.GothamBold
	gearButton.AutoButtonColor = true
	gearButton.Parent = screenGui

	local gearCorner = Instance.new("UICorner")
	gearCorner.CornerRadius = UDim.new(0, 6)
	gearCorner.Parent = gearButton

	-- Dropdown panel
	panel = Instance.new("Frame")
	panel.Name = "OptionsPanel"
	panel.Size = UDim2.new(0, 180, 0, 48)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -10, 0, 52)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 6)
	panelCorner.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = panel

	-- Toggle rows
	createToggleRow(panel, "ShowGhosts", "Show Ghosts", 1)

	-- Gear button toggles panel
	gearButton.MouseButton1Click:Connect(function()
		panelOpen = not panelOpen
		panel.Visible = panelOpen
	end)
end

function OptionsUI.getOption(name)
	return options[name]
end

function OptionsUI.onOptionChanged(name, callback)
	if not callbacks[name] then
		callbacks[name] = {}
	end
	table.insert(callbacks[name], callback)
end

function OptionsUI.show()
	if screenGui then
		screenGui.Enabled = true
	end
end

function OptionsUI.hide()
	if screenGui then
		screenGui.Enabled = false
	end
end

function OptionsUI.destroy()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	toggleButtons = {}
	callbacks = {}
end

return OptionsUI
