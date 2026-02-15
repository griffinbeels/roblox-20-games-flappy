--[[
	StartButton.luau
	
	Creates a physical start button in the world that players can interact with
	to begin the Flappy Bird game.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local StartButton = {}
StartButton.__index = StartButton

local buttonPart = nil
local textLabel = nil
local proximityPrompt = nil
local onStartCallback = nil

--[[
	Initializes the start button in the world.
	@param callback function - Function to call when button is activated
]]
function StartButton.init(callback)
	onStartCallback = callback
	
	-- Clean up any existing button first (in case of re-initialization)
	local existingButton = workspace:FindFirstChild("FlappyBirdStartButton")
	if existingButton then
		existingButton:Destroy()
	end
	
	-- Create the button part
	buttonPart = Instance.new("Part")
	buttonPart.Name = "FlappyBirdStartButton"
	buttonPart.Size = GameConfig.START_BUTTON.SIZE
	buttonPart.Position = GameConfig.START_BUTTON.POSITION
	buttonPart.Color = GameConfig.START_BUTTON.COLOR
	buttonPart.Material = Enum.Material.Neon
	buttonPart.Anchored = true
	buttonPart.CanCollide = false
	buttonPart.CanTouch = false
	buttonPart.CanQuery = false
	buttonPart.Parent = workspace
	
	-- Add a SurfaceGui for the text
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "ButtonGui"
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 50
	surfaceGui.Parent = buttonPart
	
	-- Create text label
	textLabel = Instance.new("TextLabel")
	textLabel.Name = "StartText"
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.Position = UDim2.new(0, 0, 0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = "FLAPPY BIRD\n\nPress E to Play"
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextScaled = true
	textLabel.Font = Enum.Font.GothamBold
	textLabel.Parent = surfaceGui
	
	-- Add text to back side too
	local surfaceGuiBack = Instance.new("SurfaceGui")
	surfaceGuiBack.Name = "ButtonGuiBack"
	surfaceGuiBack.Face = Enum.NormalId.Back
	surfaceGuiBack.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGuiBack.PixelsPerStud = 50
	surfaceGuiBack.Parent = buttonPart
	
	local textLabelBack = Instance.new("TextLabel")
	textLabelBack.Name = "StartTextBack"
	textLabelBack.Size = UDim2.new(1, 0, 1, 0)
	textLabelBack.Position = UDim2.new(0, 0, 0, 0)
	textLabelBack.BackgroundTransparency = 1
	textLabelBack.Text = "FLAPPY BIRD\n\nPress E to Play"
	textLabelBack.TextColor3 = Color3.new(1, 1, 1)
	textLabelBack.TextScaled = true
	textLabelBack.Font = Enum.Font.GothamBold
	textLabelBack.Parent = surfaceGuiBack
	
	-- Create ProximityPrompt for interaction
	proximityPrompt = Instance.new("ProximityPrompt")
	proximityPrompt.Name = "StartPrompt"
	proximityPrompt.ActionText = "Play Flappy Bird"
	proximityPrompt.ObjectText = "Arcade Machine"
	proximityPrompt.KeyboardKeyCode = Enum.KeyCode.E
	proximityPrompt.HoldDuration = 0 -- Instant activation
	proximityPrompt.MaxActivationDistance = GameConfig.START_BUTTON.INTERACT_DISTANCE
	proximityPrompt.RequiresLineOfSight = false
	proximityPrompt.Parent = buttonPart
	
	-- Connect to activation
	proximityPrompt.Triggered:Connect(function(player)
		if player == Players.LocalPlayer and onStartCallback then
			StartButton.hide()
			onStartCallback()
		end
	end)
end

--[[
	Shows the start button.
]]
function StartButton.show()
	if buttonPart then
		buttonPart.Transparency = 0
		
		-- Show all SurfaceGuis
		for _, child in ipairs(buttonPart:GetChildren()) do
			if child:IsA("SurfaceGui") then
				child.Enabled = true
			end
		end
		
		if proximityPrompt then
			proximityPrompt.Enabled = true
		end
	end
end

--[[
	Hides the start button completely (Part + SurfaceGuis).
	Ensures nothing from the hub area is visible in the game area.
]]
function StartButton.hide()
	if buttonPart then
		buttonPart.Transparency = 1
		
		-- Hide all SurfaceGuis (text labels)
		for _, child in ipairs(buttonPart:GetChildren()) do
			if child:IsA("SurfaceGui") then
				child.Enabled = false
			end
		end
		
		if proximityPrompt then
			proximityPrompt.Enabled = false
		end
	end
end

--[[
	Destroys the start button.
]]
function StartButton.destroy()
	if buttonPart then
		buttonPart:Destroy()
		buttonPart = nil
	end
end

return StartButton
