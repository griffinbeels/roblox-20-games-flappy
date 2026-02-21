--[[
	CameraController.luau

	Manages side-scrolling camera that follows player horizontally.
	Camera stays at fixed Y and Z offset for side view.

	The X offset is computed dynamically from a target screen fraction
	(e.g. 0.20 = player at 20% from the left edge) using the camera's
	field of view and viewport aspect ratio.  This means the player
	appears at the same screen position on all devices/resolutions.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CameraConfig = require(ReplicatedStorage.Shared.CameraConfig)

local CameraController = {}
CameraController.__index = CameraController

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera
local updateConnection = nil
local viewportConnection = nil
local PlayerController = nil

-- Screen-fraction lerp state
local currentScreenX = CameraConfig.PLAYER_SCREEN_X_READY
local targetScreenX = CameraConfig.PLAYER_SCREEN_X_READY
local transitionSpeed = 0 -- 0 = no transition in progress

--[[
	Returns the adaptive Z offset based on viewport height.
	On smaller screens the camera moves closer so the player appears larger.
]]
local function getAdaptiveOffsetZ()
	if not CameraConfig.ADAPTIVE_CAMERA then
		return CameraConfig.OFFSET_Z
	end
	local viewportHeight = camera.ViewportSize.Y
	local scale = math.clamp(
		viewportHeight / CameraConfig.REFERENCE_VIEWPORT_HEIGHT,
		CameraConfig.MIN_OFFSET_Z / CameraConfig.OFFSET_Z,
		1.0
	)
	return CameraConfig.OFFSET_Z * scale
end

--[[
	Computes the camera X offset so the player appears at the given
	screen fraction (0 = left edge, 0.5 = center, 1 = right edge).

	Math:
	  The camera is at Z = offsetZ looking at Z = 0.
	  Horizontal half-width visible at the player plane:
	    halfWidth = offsetZ * tan(hFov/2)
	  where hFov is derived from the vertical FOV + aspect ratio:
	    tan(hFov/2) = tan(vFov/2) * (viewportWidth / viewportHeight)

	  The player is at world X = playerX.
	  The camera looks at X = playerX + offsetX.
	  The player's screen displacement from center = -offsetX.
	  For screen fraction f:
	    -offsetX / halfWidth = (f - 0.5) * 2
	    offsetX = (0.5 - f) * 2 * halfWidth
]]
local function getOffsetXForScreenFraction(screenFraction)
	local offsetZ = getAdaptiveOffsetZ()
	local vFovRad = math.rad(camera.FieldOfView) -- vertical FOV in radians
	local aspect = camera.ViewportSize.X / math.max(camera.ViewportSize.Y, 1)
	local halfWidth = offsetZ * math.tan(vFovRad / 2) * aspect
	return (0.5 - screenFraction) * 2 * halfWidth
end

--[[
	Builds a CFrame for the camera at the given player X position,
	using the current screen-fraction-derived offset.
]]
local function buildCameraCFrame(playerX)
	local offsetX = getOffsetXForScreenFraction(currentScreenX)
	local offsetZ = getAdaptiveOffsetZ()
	local cameraPos = Vector3.new(
		playerX + offsetX,
		CameraConfig.FIXED_Y,
		offsetZ
	)
	local lookAtPos = Vector3.new(
		playerX + offsetX,
		CameraConfig.LOOK_AT_Y,
		0
	)
	return CFrame.lookAt(cameraPos, lookAtPos)
end

--[[
	Initializes the CameraController.
	@param playerCtrl PlayerController - The PlayerController instance
]]
function CameraController.init(playerCtrl)
	PlayerController = playerCtrl

	-- Set camera to scriptable mode (fully script-controlled)
	camera.CameraType = Enum.CameraType.Scriptable

	-- Disable camera movement from mouse/input to prevent interference
	camera.CameraSubject = nil

	-- Start at the ready fraction
	currentScreenX = CameraConfig.PLAYER_SCREEN_X_READY
	targetScreenX = CameraConfig.PLAYER_SCREEN_X_READY
	transitionSpeed = 0

	-- Re-frame camera when viewport changes (e.g. device rotation)
	if viewportConnection then
		viewportConnection:Disconnect()
	end
	viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		if updateConnection and PlayerController then
			local playerPos = PlayerController.getPosition()
			if playerPos then
				camera.CFrame = buildCameraCFrame(playerPos.X)
			end
		end
	end)
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
			camera.CFrame = buildCameraCFrame(initialPos.X)
		end
	end

	updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not PlayerController then
			return
		end

		local playerPos = PlayerController.getPosition()
		if not playerPos then
			return
		end

		-- Smoothly lerp the screen fraction toward the target
		if currentScreenX ~= targetScreenX and transitionSpeed > 0 then
			local diff = targetScreenX - currentScreenX
			local step = transitionSpeed * deltaTime
			if math.abs(diff) <= step then
				currentScreenX = targetScreenX
			else
				currentScreenX = currentScreenX + (diff > 0 and step or -step)
			end
		end

		camera.CFrame = buildCameraCFrame(playerPos.X)
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
	Sets the target screen fraction and begins a smooth transition.
	@param fraction number - Target screen X fraction (0 = left, 0.5 = center)
]]
function CameraController.setTargetScreenX(fraction)
	targetScreenX = fraction
	local duration = CameraConfig.TRANSITION_DURATION
	if duration > 0 then
		transitionSpeed = math.abs(targetScreenX - currentScreenX) / duration
	else
		currentScreenX = fraction
		transitionSpeed = 0
	end
end

--[[
	Resets the camera position (snaps to ready fraction, no transition).
]]
function CameraController.reset()
	-- Snap to ready fraction immediately
	currentScreenX = CameraConfig.PLAYER_SCREEN_X_READY
	targetScreenX = CameraConfig.PLAYER_SCREEN_X_READY
	transitionSpeed = 0

	-- Ensure camera is in scriptable mode
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil

	if PlayerController then
		local playerPos = PlayerController.getPosition()
		if playerPos then
			camera.CFrame = buildCameraCFrame(playerPos.X)
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
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
end

return CameraController
