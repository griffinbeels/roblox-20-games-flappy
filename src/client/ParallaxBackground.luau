--[[
	ParallaxBackground.luau
	
	Creates a large background that follows the player and fills the camera view.
	The background is sized to always cover the entire side-scrolling viewport.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local ParallaxBackground = {}
ParallaxBackground.__index = ParallaxBackground

local layers = {}
local updateConnection = nil
local SpeedManager = nil
local PlayerController = nil

-- Background sizing constants
-- These ensure the background always covers the entire camera view
local BACKGROUND_WIDTH = 600 -- Very wide to prevent edges from showing
local BACKGROUND_HEIGHT = 300 -- Tall enough to cover from ground to sky
local BACKGROUND_Z = -50 -- Behind the player (player is at Z=0)

--[[
	Initializes the ParallaxBackground.
	@param playerCtrl PlayerController - The PlayerController instance
	@param speedMgr SpeedManager - The SpeedManager instance
]]
function ParallaxBackground.init(playerCtrl, speedMgr)
	PlayerController = playerCtrl
	SpeedManager = speedMgr
	
	-- Get initial player position for setup
	local initialX = 0
	if PlayerController then
		local pos = PlayerController.getPosition()
		if pos then
			initialX = pos.X
		end
	end
	
	-- Create main background layer (sky)
	-- This is a single large part that follows the player
	local skyLayer = Instance.new("Part")
	skyLayer.Name = "BackgroundLayer1"
	skyLayer.Size = Vector3.new(BACKGROUND_WIDTH, BACKGROUND_HEIGHT, 1)
	-- Center vertically on the camera's look-at point
	skyLayer.Position = Vector3.new(initialX, Constants.CAMERA.LOOK_AT_Y, BACKGROUND_Z)
	skyLayer.Color = Color3.fromRGB(135, 206, 235) -- Sky blue
	skyLayer.Material = Enum.Material.SmoothPlastic
	skyLayer.Anchored = true
	skyLayer.CanCollide = false
	skyLayer.CastShadow = false
	skyLayer.Parent = workspace
	
	table.insert(layers, {part = skyLayer, followPlayer = true})
end

--[[
	Starts the background following the player.
]]
function ParallaxBackground.start()
	if updateConnection then
		updateConnection:Disconnect()
	end
	
	updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not PlayerController then
			return
		end
		
		local playerPos = PlayerController.getPosition()
		if not playerPos then
			return
		end
		
		-- Update each layer to follow the player
		for _, layer in ipairs(layers) do
			if layer.part and layer.followPlayer then
				-- Keep background centered on player's X position
				-- The background is wide enough that it will always fill the view
				layer.part.Position = Vector3.new(
					playerPos.X,
					Constants.CAMERA.LOOK_AT_Y,
					BACKGROUND_Z
				)
			end
		end
	end)
end

--[[
	Stops the parallax scrolling.
]]
function ParallaxBackground.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Resets the background position to center on player.
]]
function ParallaxBackground.reset()
	if PlayerController then
		local playerPos = PlayerController.getPosition()
		if playerPos then
			for _, layer in ipairs(layers) do
				if layer.part then
					layer.part.Position = Vector3.new(
						playerPos.X,
						Constants.CAMERA.LOOK_AT_Y,
						BACKGROUND_Z
					)
				end
			end
		end
	end
end

--[[
	Cleans up the ParallaxBackground.
]]
function ParallaxBackground.destroy()
	ParallaxBackground.stop()
	
	for _, layer in ipairs(layers) do
		if layer.part then
			layer.part:Destroy()
		end
	end
	layers = {}
end

return ParallaxBackground
