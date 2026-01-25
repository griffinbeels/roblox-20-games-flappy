--[[
	CameraController.luau
	
	Manages side-scrolling camera that follows player horizontally.
	Camera stays at fixed Y and Z offset for side view.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local CameraController = {}
CameraController.__index = CameraController

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera
local updateConnection = nil
local PlayerController = nil

--[[
	Initializes the CameraController.
	@param playerCtrl PlayerController - The PlayerController instance
]]
function CameraController.init(playerCtrl)
	PlayerController = playerCtrl
	
	-- Set camera to scriptable mode (fully script-controlled)
	camera.CameraType = Enum.CameraType.Scriptable
	
	-- Disable camera movement from mouse/input to prevent interference
	-- CameraSubject should be nil to prevent automatic following
	camera.CameraSubject = nil
end

--[[
	Starts the camera update loop.
]]
function CameraController.start()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	
	-- Set initial camera position immediately
	if PlayerController then
		local initialPos = PlayerController.getPosition()
		if initialPos then
			-- Camera position: follow player X, fixed Y and Z offset
			local cameraPos = Vector3.new(
				initialPos.X + Constants.CAMERA.OFFSET_X,
				Constants.CAMERA.FIXED_Y,
				Constants.CAMERA.OFFSET_Z
			)
			-- Look at fixed Y position (never changes - no tilting when player jumps)
			local lookAtPos = Vector3.new(
				initialPos.X + Constants.CAMERA.OFFSET_X,
				Constants.CAMERA.LOOK_AT_Y,
				0
			)
			camera.CFrame = CFrame.lookAt(cameraPos, lookAtPos)
		end
	end
	
	updateConnection = RunService.Heartbeat:Connect(function()
		if not PlayerController then
			return
		end
		
		local playerPos = PlayerController.getPosition()
		
		-- Only update camera if player position is valid
		if not playerPos then
			return
		end
		
		-- Camera position: follow player X only, fixed Y height and Z offset for side view
		local cameraPos = Vector3.new(
			playerPos.X + Constants.CAMERA.OFFSET_X,
			Constants.CAMERA.FIXED_Y,
			Constants.CAMERA.OFFSET_Z
		)
		
		-- Look at fixed Y position (camera never tilts up/down when player jumps)
		-- This creates a true side-scrolling view
		local lookAtPos = Vector3.new(
			playerPos.X + Constants.CAMERA.OFFSET_X,
			Constants.CAMERA.LOOK_AT_Y,
			0
		)
		camera.CFrame = CFrame.lookAt(cameraPos, lookAtPos)
	end)
end

--[[
	Stops the camera update loop.
]]
function CameraController.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Resets the camera position.
]]
function CameraController.reset()
	-- Ensure camera is in scriptable mode
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
	
	if PlayerController then
		local playerPos = PlayerController.getPosition()
		if playerPos then
			-- Camera position: follow player X, fixed Y and Z offset
			local cameraPos = Vector3.new(
				playerPos.X + Constants.CAMERA.OFFSET_X,
				Constants.CAMERA.FIXED_Y,
				Constants.CAMERA.OFFSET_Z
			)
			-- Look at fixed Y position (never changes - true side-scrolling)
			local lookAtPos = Vector3.new(
				playerPos.X + Constants.CAMERA.OFFSET_X,
				Constants.CAMERA.LOOK_AT_Y,
				0
			)
			camera.CFrame = CFrame.lookAt(cameraPos, lookAtPos)
		end
	end
end

--[[
	Restores normal camera (for returning to lobby).
	Re-enables default Roblox camera controls.
]]
function CameraController.restoreNormalCamera()
	CameraController.stop()
	
	-- Restore default camera mode
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = localPlayer.Character and localPlayer.Character:FindFirstChild("Humanoid")
end

--[[
	Cleans up the CameraController.
]]
function CameraController.destroy()
	CameraController.stop()
end

return CameraController
