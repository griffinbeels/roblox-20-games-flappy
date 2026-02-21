--[[
	DebugCameraUI.luau

	Debug panel for tuning CameraConfig values in real-time.
	Toggled via /debugcam chat command (server fires ToggleDebugCamera remote).
	Left side of screen, semi-transparent dark background.

	Uses UIScale to adapt to any viewport size automatically.
	All pixel sizes are designed for a reference height of 800px;
	UIScale shrinks/grows the entire panel proportionally.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CameraConfig = require(ReplicatedStorage.Shared.CameraConfig)

local DebugCameraUI = {}

local localPlayer = Players.LocalPlayer
local screenGui = nil
local panel = nil
local visible = false
local updateConnection = nil
local toggleConnection = nil

-- Store original defaults so Reset can restore them
local DEFAULTS = {
	OFFSET_X = CameraConfig.OFFSET_X,
	FIXED_Y = CameraConfig.FIXED_Y,
	OFFSET_Z = CameraConfig.OFFSET_Z,
	LOOK_AT_Y = CameraConfig.LOOK_AT_Y,
	ADAPTIVE_CAMERA = CameraConfig.ADAPTIVE_CAMERA,
	REFERENCE_VIEWPORT_HEIGHT = CameraConfig.REFERENCE_VIEWPORT_HEIGHT,
	MIN_OFFSET_Z = CameraConfig.MIN_OFFSET_Z,
}

-- Slider definitions: { key, label, min, max, step }
local SLIDER_DEFS = {
	{ key = "OFFSET_X", label = "Offset X", min = -20, max = 40, step = 1 },
	{ key = "FIXED_Y", label = "Fixed Y", min = 0, max = 60, step = 1 },
	{ key = "OFFSET_Z", label = "Offset Z", min = 10, max = 100, step = 1 },
	{ key = "LOOK_AT_Y", label = "Look-At Y", min = 0, max = 60, step = 1 },
	{ key = "REFERENCE_VIEWPORT_HEIGHT", label = "Ref Viewport H", min = 200, max = 1200, step = 10 },
	{ key = "MIN_OFFSET_Z", label = "Min Offset Z", min = 10, max = 50, step = 1 },
}

-- References for live-updating readout labels
local readoutLabels = {} -- { adaptiveZ = TextLabel, viewport = TextLabel }
local sliderValueLabels = {} -- { [key] = TextLabel }
local sliderThumbs = {} -- { [key] = TextButton }
local sliderTracks = {} -- { [key] = Frame }
local adaptiveToggleBtn = nil

-- Panel layout constants (designed at 800px viewport height)
local PANEL_WIDTH = 220
local ROW_HEIGHT = 40
local SLIDER_HEIGHT = 6
local THUMB_SIZE = 14
local PADDING = 8

-- UIScale: viewport-adaptive scaling
local UI_REFERENCE_HEIGHT = 800
local UI_MIN_SCALE = 0.45
local UI_MAX_SCALE = 1.2
local uiScaleInstance = nil
local viewportScaleConnection = nil

--[[
	Computes and applies UIScale based on current viewport height.
]]
local function updateUIScale()
	if not uiScaleInstance then return end
	local viewportHeight = workspace.CurrentCamera.ViewportSize.Y
	local scale = math.clamp(viewportHeight / UI_REFERENCE_HEIGHT, UI_MIN_SCALE, UI_MAX_SCALE)
	uiScaleInstance.Scale = scale
end

--[[
	Snaps a raw value to the nearest step.
]]
local function snapToStep(value, step)
	return math.round(value / step) * step
end

--[[
	Returns the normalized alpha (0..1) for a value in [min, max].
]]
local function valueToAlpha(value, min, max)
	return math.clamp((value - min) / (max - min), 0, 1)
end

--[[
	Returns the value for a normalized alpha in [min, max], snapped to step.
]]
local function alphaToValue(alpha, min, max, step)
	local raw = min + alpha * (max - min)
	return snapToStep(math.clamp(raw, min, max), step)
end

--[[
	Updates a slider thumb position and value label to reflect the current CameraConfig value.
]]
local function refreshSlider(def)
	local thumb = sliderThumbs[def.key]
	local track = sliderTracks[def.key]
	local label = sliderValueLabels[def.key]
	if not (thumb and track and label) then return end

	local value = CameraConfig[def.key]
	local alpha = valueToAlpha(value, def.min, def.max)

	-- Position thumb within track
	local trackWidth = track.AbsoluteSize.X
	local thumbOffset = alpha * (trackWidth - THUMB_SIZE)
	thumb.Position = UDim2.new(0, thumbOffset, 0.5, -THUMB_SIZE / 2)

	-- Update value label
	if def.step >= 1 then
		label.Text = tostring(math.round(value))
	else
		label.Text = string.format("%.1f", value)
	end
end

--[[
	Handles slider interaction (click or drag) for a given slider definition.
]]
local function handleSliderInput(def, inputX)
	local track = sliderTracks[def.key]
	if not track then return end

	local trackLeft = track.AbsolutePosition.X
	local trackWidth = track.AbsoluteSize.X
	local alpha = math.clamp((inputX - trackLeft) / trackWidth, 0, 1)
	local newValue = alphaToValue(alpha, def.min, def.max, def.step)

	CameraConfig[def.key] = newValue
	refreshSlider(def)
end

--[[
	Creates a single slider row and returns the row frame.
]]
local function createSliderRow(parent, def, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = def.key .. "Row"
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	-- Label (left)
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -50, 0, 16)
	nameLabel.Position = UDim2.new(0, PADDING, 0, 2)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = def.label
	nameLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	nameLabel.TextSize = 13
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	-- Value display (right)
	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(0, 44, 0, 16)
	valueLabel.Position = UDim2.new(1, -44 - PADDING, 0, 2)
	valueLabel.BackgroundTransparency = 1
	valueLabel.TextColor3 = Color3.fromRGB(255, 255, 100)
	valueLabel.TextSize = 13
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = row
	sliderValueLabels[def.key] = valueLabel

	-- Slider track
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, -PADDING * 2, 0, SLIDER_HEIGHT)
	track.Position = UDim2.new(0, PADDING, 0, 22)
	track.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	track.BorderSizePixel = 0
	track.Parent = row
	sliderTracks[def.key] = track

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 3)
	trackCorner.Parent = track

	-- Thumb (draggable button)
	local thumb = Instance.new("TextButton")
	thumb.Name = "Thumb"
	thumb.Size = UDim2.new(0, THUMB_SIZE, 0, THUMB_SIZE)
	thumb.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	thumb.BorderSizePixel = 0
	thumb.Text = ""
	thumb.AutoButtonColor = false
	thumb.ZIndex = 2
	thumb.Parent = track
	sliderThumbs[def.key] = thumb

	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(0.5, 0)
	thumbCorner.Parent = thumb

	-- Drag logic
	local dragging = false

	thumb.MouseButton1Down:Connect(function()
		dragging = true
	end)

	-- Click-to-set on the track background
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			handleSliderInput(def, input.Position.X)
		end
	end)

	-- Global mouse move/release for smooth dragging
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			handleSliderInput(def, input.Position.X)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	-- Set initial position
	refreshSlider(def)

	return row
end

--[[
	Creates the ADAPTIVE_CAMERA toggle row.
]]
local function createToggleRow(parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = "AdaptiveCameraRow"
	row.Size = UDim2.new(1, 0, 0, 28)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -50, 1, 0)
	nameLabel.Position = UDim2.new(0, PADDING, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = "Adaptive Camera"
	nameLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	nameLabel.TextSize = 13
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	local btn = Instance.new("TextButton")
	btn.Name = "AdaptiveToggle"
	btn.Size = UDim2.new(0, 36, 0, 20)
	btn.Position = UDim2.new(1, -44, 0.5, -10)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	btn.BorderSizePixel = 0
	btn.TextSize = 13
	btn.Font = Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = btn

	adaptiveToggleBtn = btn

	local function updateVisual()
		local on = CameraConfig.ADAPTIVE_CAMERA
		btn.Text = on and "ON" or "OFF"
		btn.TextColor3 = on and Color3.fromRGB(100, 255, 100) or Color3.fromRGB(255, 100, 100)
	end

	updateVisual()

	btn.MouseButton1Click:Connect(function()
		CameraConfig.ADAPTIVE_CAMERA = not CameraConfig.ADAPTIVE_CAMERA
		updateVisual()
	end)

	return row
end

--[[
	Creates a read-only info row.
]]
local function createReadoutRow(parent, label, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = label .. "Readout"
	row.Size = UDim2.new(1, 0, 0, 18)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(0.5, 0, 1, 0)
	nameLabel.Position = UDim2.new(0, PADDING, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = label
	nameLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
	nameLabel.TextSize = 12
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(0.5, -PADDING, 1, 0)
	valueLabel.Position = UDim2.new(0.5, 0, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
	valueLabel.TextSize = 12
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = row

	return valueLabel
end

--[[
	Creates an action button (Reset Defaults, Print Values).
]]
local function createButton(parent, text, layoutOrder, callback)
	local btn = Instance.new("TextButton")
	btn.Name = text:gsub(" ", "")
	btn.Size = UDim2.new(1, -PADDING * 2, 0, 24)
	btn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(220, 220, 220)
	btn.TextSize = 13
	btn.Font = Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.LayoutOrder = layoutOrder
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	btn.MouseButton1Click:Connect(callback)
	return btn
end

--[[
	Resets all CameraConfig values to their original defaults.
]]
local function resetDefaults()
	for key, value in pairs(DEFAULTS) do
		CameraConfig[key] = value
	end

	-- Refresh all sliders
	for _, def in ipairs(SLIDER_DEFS) do
		refreshSlider(def)
	end

	-- Refresh toggle
	if adaptiveToggleBtn then
		local on = CameraConfig.ADAPTIVE_CAMERA
		adaptiveToggleBtn.Text = on and "ON" or "OFF"
		adaptiveToggleBtn.TextColor3 = on and Color3.fromRGB(100, 255, 100) or Color3.fromRGB(255, 100, 100)
	end
end

--[[
	Prints all current CameraConfig values to the dev console.
]]
local function printValues()
	print("=== CameraConfig Current Values ===")
	print("CameraConfig.OFFSET_X = " .. tostring(CameraConfig.OFFSET_X))
	print("CameraConfig.FIXED_Y = " .. tostring(CameraConfig.FIXED_Y))
	print("CameraConfig.OFFSET_Z = " .. tostring(CameraConfig.OFFSET_Z))
	print("CameraConfig.LOOK_AT_Y = " .. tostring(CameraConfig.LOOK_AT_Y))
	print("CameraConfig.ADAPTIVE_CAMERA = " .. tostring(CameraConfig.ADAPTIVE_CAMERA))
	print("CameraConfig.REFERENCE_VIEWPORT_HEIGHT = " .. tostring(CameraConfig.REFERENCE_VIEWPORT_HEIGHT))
	print("CameraConfig.MIN_OFFSET_Z = " .. tostring(CameraConfig.MIN_OFFSET_Z))
	print("===================================")
end

--[[
	Builds the entire debug panel UI.
]]
local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugCameraGui"
	screenGui.DisplayOrder = 20
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Main panel
	panel = Instance.new("Frame")
	panel.Name = "DebugPanel"
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, 0) -- height set by UIListLayout
	panel.Position = UDim2.new(0, 10, 0.5, 0)
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 8)
	panelCorner.Parent = panel

	-- UIScale: scales the entire panel to fit any viewport size
	uiScaleInstance = Instance.new("UIScale")
	uiScaleInstance.Parent = panel
	updateUIScale()

	-- Re-scale when viewport changes (device rotation, window resize)
	viewportScaleConnection = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateUIScale()
	end)

	-- Auto-size panel height
	panel.AutomaticSize = Enum.AutomaticSize.Y

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = panel

	local uiPadding = Instance.new("UIPadding")
	uiPadding.PaddingTop = UDim.new(0, PADDING)
	uiPadding.PaddingBottom = UDim.new(0, PADDING)
	uiPadding.PaddingLeft = UDim.new(0, 0)
	uiPadding.PaddingRight = UDim.new(0, 0)
	uiPadding.Parent = panel

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 22)
	title.BackgroundTransparency = 1
	title.Text = "Debug Camera"
	title.TextColor3 = Color3.fromRGB(255, 200, 80)
	title.TextSize = 15
	title.Font = Enum.Font.GothamBold
	title.LayoutOrder = 0
	title.Parent = panel

	-- Slider rows (layout orders 1-6)
	for i, def in ipairs(SLIDER_DEFS) do
		createSliderRow(panel, def, i)
	end

	-- Toggle row (layout order 7)
	createToggleRow(panel, 7)

	-- Separator
	local sep = Instance.new("Frame")
	sep.Name = "Separator"
	sep.Size = UDim2.new(1, -PADDING * 2, 0, 1)
	sep.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	sep.BorderSizePixel = 0
	sep.LayoutOrder = 8
	sep.Parent = panel

	-- Readouts (layout orders 9-10)
	readoutLabels.adaptiveZ = createReadoutRow(panel, "Adaptive Z", 9)
	readoutLabels.viewport = createReadoutRow(panel, "Viewport", 10)

	-- Separator
	local sep2 = Instance.new("Frame")
	sep2.Name = "Separator2"
	sep2.Size = UDim2.new(1, -PADDING * 2, 0, 1)
	sep2.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	sep2.BorderSizePixel = 0
	sep2.LayoutOrder = 11
	sep2.Parent = panel

	-- Buttons (layout orders 12-13)
	createButton(panel, "Reset Defaults", 12, resetDefaults)
	createButton(panel, "Print Values", 13, printValues)
end

--[[
	Updates the read-only info readouts every frame.
]]
local function startReadoutUpdates()
	if updateConnection then
		updateConnection:Disconnect()
	end
	updateConnection = RunService.Heartbeat:Connect(function()
		if not visible then return end

		-- Adaptive Z
		local camera = workspace.CurrentCamera
		if readoutLabels.adaptiveZ then
			local adaptiveZ
			if not CameraConfig.ADAPTIVE_CAMERA then
				adaptiveZ = CameraConfig.OFFSET_Z
			else
				local viewportHeight = camera.ViewportSize.Y
				local scale = math.clamp(
					viewportHeight / CameraConfig.REFERENCE_VIEWPORT_HEIGHT,
					CameraConfig.MIN_OFFSET_Z / CameraConfig.OFFSET_Z,
					1.0
				)
				adaptiveZ = CameraConfig.OFFSET_Z * scale
			end
			readoutLabels.adaptiveZ.Text = string.format("%.1f", adaptiveZ)
		end

		-- Viewport
		if readoutLabels.viewport then
			local vs = camera.ViewportSize
			readoutLabels.viewport.Text = string.format("%d x %d", math.round(vs.X), math.round(vs.Y))
		end
	end)
end

--[[
	Toggles panel visibility.
]]
local function toggle()
	visible = not visible
	if panel then
		panel.Visible = visible
	end
	if visible then
		-- Refresh scale and all sliders to match current config
		updateUIScale()
		for _, def in ipairs(SLIDER_DEFS) do
			refreshSlider(def)
		end
		startReadoutUpdates()
	else
		if updateConnection then
			updateConnection:Disconnect()
			updateConnection = nil
		end
	end
end

--[[
	Initializes the debug camera UI.
	Listens for the ToggleDebugCamera remote from the server.
]]
function DebugCameraUI.init()
	buildUI()

	-- Listen for server toggle remote
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remotes then return end
		local remote = remotes:WaitForChild("ToggleDebugCamera", 10)
		if not remote then return end

		toggleConnection = remote.OnClientEvent:Connect(function()
			toggle()
		end)
	end)
end

--[[
	Cleans up the debug camera UI.
]]
function DebugCameraUI.destroy()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	if toggleConnection then
		toggleConnection:Disconnect()
		toggleConnection = nil
	end
	if viewportScaleConnection then
		viewportScaleConnection:Disconnect()
		viewportScaleConnection = nil
	end
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	panel = nil
	visible = false
	readoutLabels = {}
	sliderValueLabels = {}
	sliderThumbs = {}
	sliderTracks = {}
	adaptiveToggleBtn = nil
	uiScaleInstance = nil
end

return DebugCameraUI
