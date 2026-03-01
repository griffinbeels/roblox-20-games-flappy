--[[
	PlayerController.luau
	
	Controls player avatar physics, gravity, jump, and forward movement.
	Uses the player's Roblox avatar instead of a separate object.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)
local JumpInput = require(script.Parent.JumpInput)
local Workspace = game:GetService("Workspace")

local PlayerController = {}
PlayerController.__index = PlayerController

local localPlayer = Players.LocalPlayer
local character = nil
local humanoidRootPart = nil
local humanoid = nil
local bodyPosition = nil
local bodyGyro = nil
local currentVelocity = Vector3.new(0, 0, 0)
local updateConnection = nil
local jumpConnection = nil
local SpeedManager = nil
local lastJumpTime = 0 -- Track when last jump occurred
local isResetting = false -- Flag to prevent double initialization during reset
local isInputEnabled = true -- Flag to control whether player input is accepted
local inputGuardCallback = nil -- Optional callback; if it returns true, mouse/touch jump is blocked
local skipNextCharacterAdded = false -- Set by GameController to skip handler during managed respawns
local armPoseConnections = {} -- Connections that maintain the flying arm pose
local renderStepConnection = nil -- Connection for RenderStepped arm pose maintenance
local cachedMotor6Ds = nil -- Cache of Motor6D references for the current character

local function getActiveGravity()
	return tonumber(RuntimeTuning.getActiveGravity()) or tonumber(PlayerConfig.GRAVITY) or 250
end

local function getActiveJumpForce()
	local baseJumpForce = tonumber(PlayerConfig.JUMP_FORCE) or 60
	local jumpPowerMultiplier = tonumber(RuntimeTuning.getActiveJumpPowerMultiplier()) or 1.0
	return baseJumpForce * jumpPowerMultiplier
end

--[[
	Returns a CFrame oriented for the superman flying pose at the given position.
	Character is horizontal with head pointing +X (travel direction), belly facing down.
	Optional tilt parameter adds pitch based on vertical velocity.
]]
local function getFlyingCFrame(pos, tiltRadians)
	tiltRadians = tiltRadians or 0
	return CFrame.lookAt(pos, pos + Vector3.new(1, 0, 0)) * CFrame.Angles(math.rad(-90) + tiltRadians, 0, 0)
end

local function getReadyX()
	return PlayerConfig.START_POSITION.X + (PlayerConfig.READY_X_OFFSET or 0)
end

--[[
	Helper to find a Motor6D by name anywhere in the character.
]]
local function findMotor6D(name)
	if not character then return nil end
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("Motor6D") and desc.Name == name then
			return desc
		end
	end
	return nil
end

--[[
	Caches Motor6D references for the current character to avoid repeated searches.
]]
local function cacheMotor6Ds()
	cachedMotor6Ds = {
		rightShoulder = findMotor6D("RightShoulder") or findMotor6D("Right Shoulder"),
		leftShoulder = findMotor6D("LeftShoulder") or findMotor6D("Left Shoulder"),
		rightElbow = findMotor6D("RightElbow"),
		leftElbow = findMotor6D("LeftElbow"),
		rightWrist = findMotor6D("RightWrist"),
		leftWrist = findMotor6D("LeftWrist"),
		rightHip = findMotor6D("RightHip") or findMotor6D("Right Hip"),
		leftHip = findMotor6D("LeftHip") or findMotor6D("Left Hip"),
		rightKnee = findMotor6D("RightKnee"),
		leftKnee = findMotor6D("LeftKnee"),
		rightAnkle = findMotor6D("RightAnkle"),
		leftAnkle = findMotor6D("LeftAnkle"),
	}
end

-- Wind flap oscillation parameters
local FLAP_SPEED = 8         -- How fast limbs oscillate (radians/sec)
local ARM_FLAP_ANGLE = 15    -- Max degrees arms sway side-to-side
local ELBOW_FLAP_ANGLE = 10  -- Max degrees elbows bend in wind
local LEG_FLAP_ANGLE = 12    -- Max degrees legs sway
local KNEE_FLAP_ANGLE = 8    -- Max degrees knees bend in wind

--[[
	Sets joint transforms for the flying pose with wind oscillation.
	Called every frame from RenderStepped to override the animation system.
	Arms are raised above head, legs trail behind, and all limbs flap in the wind.
]]
local function setArmTransforms()
	if not cachedMotor6Ds then return end

	local t = tick()
	-- Arms and legs use opposite phases (when arm is up, leg is down)
	local armWave = math.sin(t * FLAP_SPEED)
	local elbowWave = math.sin(t * FLAP_SPEED + 0.3)
	local legWave = armWave                              -- Same direction as arms (but belly-down flips visual)
	local kneeWave = math.sin(t * FLAP_SPEED + 0.3)     -- Match elbow phase

	local armOsc = math.rad(ARM_FLAP_ANGLE) * armWave
	local elbowOsc = math.rad(ELBOW_FLAP_ANGLE) * elbowWave
	local legOsc = math.rad(LEG_FLAP_ANGLE) * legWave
	local kneeOsc = math.rad(KNEE_FLAP_ANGLE) * kneeWave

	-- Arms raised above head with up/down oscillation
	if cachedMotor6Ds.rightShoulder and cachedMotor6Ds.rightShoulder.Parent then
		cachedMotor6Ds.rightShoulder.Transform = CFrame.Angles(armOsc, 0, math.rad(-180))
	end
	if cachedMotor6Ds.leftShoulder and cachedMotor6Ds.leftShoulder.Parent then
		cachedMotor6Ds.leftShoulder.Transform = CFrame.Angles(armOsc, 0, math.rad(180))
	end

	-- Elbows flex slightly in wind
	if cachedMotor6Ds.rightElbow and cachedMotor6Ds.rightElbow.Parent then
		cachedMotor6Ds.rightElbow.Transform = CFrame.Angles(elbowOsc, 0, 0)
	end
	if cachedMotor6Ds.leftElbow and cachedMotor6Ds.leftElbow.Parent then
		cachedMotor6Ds.leftElbow.Transform = CFrame.Angles(-elbowOsc, 0, 0)
	end

	-- Wrists stay straight
	if cachedMotor6Ds.rightWrist and cachedMotor6Ds.rightWrist.Parent then
		cachedMotor6Ds.rightWrist.Transform = CFrame.new()
	end
	if cachedMotor6Ds.leftWrist and cachedMotor6Ds.leftWrist.Parent then
		cachedMotor6Ds.leftWrist.Transform = CFrame.new()
	end

	-- Legs trail behind with up/down oscillation
	if cachedMotor6Ds.rightHip and cachedMotor6Ds.rightHip.Parent then
		cachedMotor6Ds.rightHip.Transform = CFrame.Angles(legOsc, 0, 0)
	end
	if cachedMotor6Ds.leftHip and cachedMotor6Ds.leftHip.Parent then
		cachedMotor6Ds.leftHip.Transform = CFrame.Angles(legOsc, 0, 0)
	end

	-- Knees bend slightly in wind
	if cachedMotor6Ds.rightKnee and cachedMotor6Ds.rightKnee.Parent then
		cachedMotor6Ds.rightKnee.Transform = CFrame.Angles(kneeOsc, 0, 0)
	end
	if cachedMotor6Ds.leftKnee and cachedMotor6Ds.leftKnee.Parent then
		cachedMotor6Ds.leftKnee.Transform = CFrame.Angles(kneeOsc, 0, 0)
	end

	-- Ankles stay neutral
	if cachedMotor6Ds.rightAnkle and cachedMotor6Ds.rightAnkle.Parent then
		cachedMotor6Ds.rightAnkle.Transform = CFrame.new()
	end
	if cachedMotor6Ds.leftAnkle and cachedMotor6Ds.leftAnkle.Parent then
		cachedMotor6Ds.leftAnkle.Transform = CFrame.new()
	end
end

--[[
	Stops default animations, destroys the Animator to prevent the animation system
	from overwriting joint transforms, and poses the character in the superman flying
	pose: arms stretched straight above the head.

	Also starts a RenderStepped loop to maintain the pose, since RenderStepped runs
	after the animation system evaluates transforms.
]]
local function applyFlyingPose()
	if not character then return end

	-- Stop the Animate script so it doesn't override our pose
	local animate = character:FindFirstChild("Animate")
	if animate then
		animate.Disabled = true
	end

	-- Stop all playing animation tracks and destroy the Animator
	-- The Animator is what actually writes to Motor6D.Transform each frame,
	-- so destroying it is the only reliable way to stop overrides.
	if humanoid then
		for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
			track:Stop(0)
		end
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			animator:Destroy()
		end
	end

	-- Cache Motor6D references
	cacheMotor6Ds()

	-- Apply the arm pose immediately
	setArmTransforms()

	-- Start a RenderStepped binding to maintain the pose.
	-- RenderStepped fires during the render phase, AFTER any remaining animation
	-- evaluation, so our transforms take final priority.
	if not renderStepConnection then
		renderStepConnection = RunService.RenderStepped:Connect(function()
			setArmTransforms()
		end)
	end
end

--[[
	Initializes the PlayerController.
	Sets up character references and disables default movement.
]]
function PlayerController.init()
	-- Wait for character to spawn and fully load
	character = localPlayer.Character
	if not character or not character.Parent then
		character = localPlayer.CharacterAdded:Wait()
	end
	
	-- Wait for essential parts (with longer timeout for slow loading)
	humanoidRootPart = character:WaitForChild("HumanoidRootPart", 10)
	humanoid = character:WaitForChild("Humanoid", 10)
	
	if not humanoidRootPart or not humanoid then
		warn("PlayerController: Failed to get character parts - retrying...")
		-- Retry once more
		task.wait(0.5)
		humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
		humanoid = character:WaitForChild("Humanoid", 5)
		
		if not humanoidRootPart or not humanoid then
			warn("PlayerController: Failed to get character parts after retry")
			return
		end
	end
	
	-- Wait a frame for character to stabilize
	task.wait()
	
	-- Disable default character movement states immediately
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	
	-- Disable default movement
	humanoid.PlatformStand = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	
	-- Prevent character from being destroyed on collision
	-- Make character parts non-collidable with pipes (we handle collisions manually)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part ~= humanoidRootPart then
			part.CanCollide = false
		end
	end
	humanoidRootPart.CanCollide = false
	
	-- Clean up any existing physics objects
	if bodyPosition then bodyPosition:Destroy() end
	if bodyGyro then bodyGyro:Destroy() end
	
	-- Use BodyPosition for movement that respects collisions
	bodyPosition = Instance.new("BodyPosition")
	bodyPosition.MaxForce = Vector3.new(0, 0, 0) -- Start disabled
	bodyPosition.Position = humanoidRootPart.Position
	bodyPosition.P = 10000
	bodyPosition.D = 1000
	bodyPosition.Parent = humanoidRootPart
	
	-- Use BodyGyro to keep character in superman flying pose
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
	bodyGyro.CFrame = getFlyingCFrame(humanoidRootPart.Position)
	bodyGyro.P = 3000
	bodyGyro.D = 500
	bodyGyro.Parent = humanoidRootPart

	-- Reset to starting position immediately
	PlayerController.reset()

	-- Apply the flying arm pose
	applyFlyingPose()
	
	-- Set up input for jumping (only if not already connected)
	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end
	jumpConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if not JumpInput.isJump(input) then return end
		-- For mouse/touch, check the external UI guard (e.g. leaderboard hover)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if inputGuardCallback and inputGuardCallback() then return end
		end
		PlayerController.jump()
	end)

	-- Listen for character respawns (in case character gets destroyed)
	localPlayer.CharacterAdded:Connect(function(newCharacter)
		-- Skip when GameController is managing the respawn (setReadyPosition handles everything)
		if skipNextCharacterAdded then
			skipNextCharacterAdded = false
			return
		end
		-- Skip if we're already resetting (to avoid double initialization)
		if isResetting then
			return
		end
		
		-- Character respawned, reinitialize
		-- Clear render step connection so applyFlyingPose creates a fresh one
		if renderStepConnection then
			renderStepConnection:Disconnect()
			renderStepConnection = nil
		end
		cachedMotor6Ds = nil

		character = newCharacter
		humanoidRootPart = character:WaitForChild("HumanoidRootPart")
		humanoid = character:WaitForChild("Humanoid")
		
		-- Wait for character to stabilize
		task.wait(0.2)
		
		-- Re-setup everything
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid.PlatformStand = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		
		-- Recreate physics objects
		if bodyPosition then bodyPosition:Destroy() end
		if bodyGyro then bodyGyro:Destroy() end
		
		bodyPosition = Instance.new("BodyPosition")
		bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		bodyPosition.Position = humanoidRootPart.Position
		bodyPosition.P = 10000
		bodyPosition.D = 1000
		bodyPosition.Parent = humanoidRootPart
		
		bodyGyro = Instance.new("BodyGyro")
		bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
		bodyGyro.CFrame = getFlyingCFrame(humanoidRootPart.Position)
		bodyGyro.P = 3000
		bodyGyro.D = 500
		bodyGyro.Parent = humanoidRootPart

		-- Prevent collisions but DON'T change transparency
		-- HumanoidRootPart should remain invisible
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part ~= humanoidRootPart then
				part.CanCollide = false
			end
		end
		humanoidRootPart.CanCollide = false

		-- Apply flying arm pose
		applyFlyingPose()

		-- Reset position
		isResetting = true
		local startPos = PlayerConfig.START_POSITION
		humanoidRootPart.CFrame = getFlyingCFrame(startPos)
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
		humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
		currentVelocity = Vector3.new(0, 0, 0)
		lastJumpTime = 0
		
		if bodyPosition then
			bodyPosition.Position = startPos
			bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		end
		
		if bodyGyro then
			bodyGyro.CFrame = getFlyingCFrame(startPos)
		end

		isResetting = false
	end)
end

--[[
	Gets the player's current position.
	@return Vector3 - Current position
]]
function PlayerController.getPosition()
	if humanoidRootPart then
		return humanoidRootPart.Position
	end
	return PlayerConfig.START_POSITION
end

--[[
	Applies jump force to the player.
	Flappy Bird style: instant upward impulse, like hitting a ping pong ball.
	The player FEELS like they're preventing themselves from falling,
	like bouncing a ping pong ball on a paddle and keeping it in the air.
	No cooldown - player can jump continuously.
]]
function PlayerController.jump()
	-- Check if input is enabled (disabled during game over)
	if not isInputEnabled then
		return
	end

	if not humanoidRootPart then
		return
	end

	-- Apply instant upward force (like hitting a ping pong ball)
	-- Reset Y velocity completely and apply jump force for consistent feel
	local jumpForce = getActiveJumpForce()
	currentVelocity = Vector3.new(currentVelocity.X, jumpForce, 0)
	lastJumpTime = tick()

	-- Apply directly to HumanoidRootPart for immediate response
	humanoidRootPart.Velocity = Vector3.new(humanoidRootPart.Velocity.X, jumpForce, 0)

	-- Play jump sound (optional - SoundManager may not be loaded yet)
	local success, SoundManager = pcall(function()
		return require(script.Parent.SoundManager)
	end)
	if success and SoundManager then
		SoundManager.playJump()
	end

	-- Spawn jump poof effect (optional - PoofManager may not be loaded yet)
	local poofOk, PoofManager = pcall(function()
		return require(script.Parent.PoofManager)
	end)
	if poofOk and PoofManager and PoofManager.onJump then
		PoofManager.onJump(humanoidRootPart.Position, currentVelocity)
	end
end

--[[
	Starts the update loop for physics and movement.
]]
function PlayerController.startUpdate()
	if updateConnection then
		updateConnection:Disconnect()
	end
	
	updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not humanoidRootPart or not bodyPosition then
			return
		end
		
		local currentPos = humanoidRootPart.Position
		
		-- Raycast downward to check for floor collision
		-- Account for character size (HumanoidRootPart is at center, character is ~4 studs tall)
		local characterHeight = 4 -- Approximate character height in studs
		local rayOrigin = currentPos
		local rayDirection = Vector3.new(0, -characterHeight/2 - 0.5, 0) -- Cast down from center to bottom
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
		raycastParams.FilterDescendantsInstances = {character} -- Don't hit character parts
		
		local raycastResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		local isOnGround = raycastResult ~= nil
		local floorY = nil
		if isOnGround then
			floorY = raycastResult.Position.Y + characterHeight/2 -- Position character so feet are on floor
		end
		
		-- Apply gravity to velocity (constant downward pull)
		-- This creates the "falling" feeling that player must prevent with jumps
		-- Like a ping pong ball - it falls, you tap to keep it up!
		currentVelocity = currentVelocity - Vector3.new(0, getActiveGravity() * deltaTime, 0)
		
		-- If on ground, stop downward velocity (but jump can still work)
		if isOnGround and currentVelocity.Y < 0 then
			currentVelocity = Vector3.new(currentVelocity.X, 0, 0)
		end
		
		-- Get forward speed (from SpeedManager if available, otherwise base speed)
		local forwardSpeed = PlayerConfig.BASE_FORWARD_SPEED
		if SpeedManager then
			forwardSpeed = SpeedManager.getCurrentSpeed()
		end
		
		-- Apply forward movement to velocity (X axis)
		currentVelocity = Vector3.new(forwardSpeed, currentVelocity.Y, 0)
		
		-- Calculate target position
		local targetPos = currentPos + (currentVelocity * deltaTime)
		
		-- Handle floor collision
		if isOnGround and floorY then
			-- If we're on or would go below the floor, keep character at floor level
			if targetPos.Y < floorY then
				targetPos = Vector3.new(targetPos.X, floorY, targetPos.Z)
				currentVelocity = Vector3.new(currentVelocity.X, math.max(0, currentVelocity.Y), 0)
			end
			
			-- If player touches ground, this will be detected by CollisionDetector
			-- and trigger game over in GameController
		end
		
		-- Clamp Y position within boundaries
		if targetPos.Y < WorldConfig.BOUNDARIES.MIN_Y then
			targetPos = Vector3.new(targetPos.X, WorldConfig.BOUNDARIES.MIN_Y, targetPos.Z)
			currentVelocity = Vector3.new(currentVelocity.X, math.max(0, currentVelocity.Y), 0)
		elseif targetPos.Y > WorldConfig.BOUNDARIES.MAX_Y then
			targetPos = Vector3.new(targetPos.X, WorldConfig.BOUNDARIES.MAX_Y, targetPos.Z)
			currentVelocity = Vector3.new(currentVelocity.X, math.min(0, currentVelocity.Y), 0)
		end
		
		-- Apply velocity directly - this allows jump to work properly
		-- The jump feels like preventing a fall - each tap gives upward boost
		-- Like bouncing a ping pong ball - you tap to keep it up!
		-- Always use direct velocity for responsive feel
		humanoidRootPart.Velocity = currentVelocity
		
		-- Disable BodyPosition completely - we want free movement for jump to feel right
		-- Only use it as absolute last resort to prevent clipping
		if isOnGround and floorY and currentPos.Y <= floorY + 0.05 and currentVelocity.Y <= -5 then
			-- Only activate when extremely close to floor AND falling fast to prevent clipping
			bodyPosition.MaxForce = Vector3.new(0, 500, 0) -- Very low force, only Y axis
			bodyPosition.Position = Vector3.new(targetPos.X, math.max(targetPos.Y, floorY), targetPos.Z)
		else
			-- Disable BodyPosition when in air so jump works freely
			bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		end
		
		-- Orient character along trajectory based on TILT_MODE
		if humanoidRootPart and PlayerConfig.TILT_MODE ~= "NONE" then
			local tilt = math.atan2(currentVelocity.Y * PlayerConfig.TILT_SHARPNESS, currentVelocity.X)
			if PlayerConfig.TILT_MODE == "DIRECT" then
				humanoidRootPart.CFrame = getFlyingCFrame(humanoidRootPart.Position, tilt)
				if bodyGyro then
					bodyGyro.CFrame = humanoidRootPart.CFrame
				end
			elseif PlayerConfig.TILT_MODE == "DAMPED" then
				if bodyGyro then
					bodyGyro.CFrame = getFlyingCFrame(humanoidRootPart.Position, tilt)
					bodyGyro.P = PlayerConfig.TILT_DAMPED_P
					bodyGyro.D = PlayerConfig.TILT_DAMPED_D
					bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
				end
			end
		elseif humanoidRootPart and bodyGyro then
			bodyGyro.CFrame = getFlyingCFrame(humanoidRootPart.Position)
			bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
		end

		-- Arm pose is maintained by RenderStepped (see applyFlyingPose)
	end)
end

--[[
	Stops the update loop.
]]
function PlayerController.stopUpdate()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

--[[
	Sets the SpeedManager reference for progressive speed.
	@param speedMgr SpeedManager - The SpeedManager instance
]]
function PlayerController.setSpeedManager(speedMgr)
	SpeedManager = speedMgr
end

--[[
	Resets the player to starting position and velocity.
	Also ensures character exists and is properly set up.
]]
function PlayerController.reset()
	-- Prevent double initialization
	if isResetting then
		return
	end
	isResetting = true
	
	-- Wait for character if it doesn't exist
	if not character or not character.Parent then
		character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	end
	
	-- Wait for essential parts (short timeout)
	humanoidRootPart = character:WaitForChild("HumanoidRootPart", 1)
	humanoid = character:WaitForChild("Humanoid", 1)
	
	if not humanoidRootPart or not humanoid then
		isResetting = false
		return
	end
	
	-- Re-setup physics objects if they don't exist
	if not bodyPosition or not bodyPosition.Parent then
		if bodyPosition then bodyPosition:Destroy() end
		bodyPosition = Instance.new("BodyPosition")
		bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		bodyPosition.Position = humanoidRootPart.Position
		bodyPosition.P = 10000
		bodyPosition.D = 1000
		bodyPosition.Parent = humanoidRootPart
	end
	
	if not bodyGyro or not bodyGyro.Parent then
		if bodyGyro then bodyGyro:Destroy() end
		bodyGyro = Instance.new("BodyGyro")
		bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
		bodyGyro.P = 3000
		bodyGyro.D = 500
		bodyGyro.Parent = humanoidRootPart
	end
	
	-- Re-disable movement states
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid.PlatformStand = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	
	-- Prevent collisions but DON'T change transparency
	-- HumanoidRootPart should remain invisible (Transparency = 1 by default)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part ~= humanoidRootPart then
			part.CanCollide = false
		end
	end
	if humanoidRootPart then
		humanoidRootPart.CanCollide = false
		-- Don't change HumanoidRootPart transparency - it should stay invisible
	end
	
	-- Reset to start position using CFrame for immediate teleport
	local startPos = PlayerConfig.START_POSITION
	humanoidRootPart.CFrame = getFlyingCFrame(startPos)
	humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
	currentVelocity = Vector3.new(0, 0, 0)
	lastJumpTime = 0

	if bodyPosition then
		bodyPosition.Position = startPos
		bodyPosition.MaxForce = Vector3.new(0, 0, 0) -- Disable
	end
	
	if bodyGyro then
		bodyGyro.CFrame = getFlyingCFrame(startPos)
	end

	-- Apply flying pose
	applyFlyingPose()

	-- Reset flag
	isResetting = false
end

--[[
	Sets the player to the ready position (floating in the air).
]]
function PlayerController.setReadyPosition()
	-- Use the module-level character ref (kept current by our CharacterAdded handler).
	-- Only re-acquire from LocalPlayer if the cached ref is stale.
	if not character or not character.Parent then
		character = localPlayer.Character
	end
	if not character or not character.Parent then
		-- Character truly doesn't exist yet — wait with a timeout
		local waitThread = task.delay(10, function() end) -- safety net
		character = localPlayer.CharacterAdded:Wait()
		task.cancel(waitThread)
	end

	-- Refresh part references from the (possibly new) character
	humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 5)
	humanoid = character:FindFirstChild("Humanoid")
		or character:WaitForChild("Humanoid", 5)

	if not humanoidRootPart or not humanoid then
		warn("PlayerController.setReadyPosition: Timeout waiting for character parts")
		return
	end

	-- Wait a frame for character to fully initialize
	task.wait()
	
	-- Clean up any existing physics objects first
	local existingBP = humanoidRootPart:FindFirstChild("BodyPosition")
	local existingBG = humanoidRootPart:FindFirstChild("BodyGyro")
	if existingBP then existingBP:Destroy() end
	if existingBG then existingBG:Destroy() end
	
	-- Create fresh physics objects
	bodyPosition = Instance.new("BodyPosition")
	bodyPosition.Name = "BodyPosition"
	bodyPosition.P = 50000
	bodyPosition.D = 5000
	bodyPosition.MaxForce = Vector3.new(0, 0, 0) -- Start disabled
	bodyPosition.Parent = humanoidRootPart
	
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.Name = "BodyGyro"
	bodyGyro.P = 3000
	bodyGyro.D = 500
	bodyGyro.MaxTorque = Vector3.new(0, 0, 0) -- Start disabled
	bodyGyro.Parent = humanoidRootPart
	
	-- Position player in the air at the ready position (START_POSITION + hover offset)
	local readyPos = Vector3.new(
		getReadyX(),
		PlayerConfig.START_POSITION.Y + PlayerConfig.HOVER_Y_OFFSET,
		PlayerConfig.START_POSITION.Z
	)
	
	-- Disable humanoid movement during ready state
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.PlatformStand = true -- This prevents humanoid from applying forces
	
	-- Disable ALL humanoid states that could interfere (must match init() list
	-- plus Running states — GettingUp/Landed can force the character upright)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, false)

	-- Make character parts non-collidable (we handle collisions manually)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end

	-- Set position in superman flying pose
	humanoidRootPart.CFrame = getFlyingCFrame(readyPos)
	humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
	humanoidRootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	humanoidRootPart.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	currentVelocity = Vector3.new(0, 0, 0)
	
	-- Set up BodyPosition with very high force to hold player in place
	bodyPosition.Position = readyPos
	bodyPosition.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bodyPosition.P = 50000
	bodyPosition.D = 5000

	-- Set up BodyGyro to maintain flying pose
	bodyGyro.CFrame = getFlyingCFrame(readyPos)
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)

	-- Clean up stale renderStepConnection from previous character so
	-- applyFlyingPose() creates a fresh one bound to the new Motor6Ds.
	-- (When skipNextCharacterAdded was used, the normal cleanup in
	-- PlayerController.CharacterAdded was skipped.)
	if renderStepConnection then
		renderStepConnection:Disconnect()
		renderStepConnection = nil
	end
	cachedMotor6Ds = nil

	-- Apply flying arm pose
	applyFlyingPose()
end

--[[
	Updates the hover animation during ready state.
	@param time number - Current time for animation
]]
function PlayerController.updateHover(time)
	if not humanoidRootPart or not bodyPosition then
		return
	end
	
	-- Ensure velocity stays zero during hover
	humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
	
	-- Gentle bobbing animation
	local baseY = PlayerConfig.START_POSITION.Y + PlayerConfig.HOVER_Y_OFFSET
	local hoverOffset = math.sin(time * PlayerConfig.HOVER_SPEED) * PlayerConfig.HOVER_AMPLITUDE
	local hoverPos = Vector3.new(
		getReadyX(),
		baseY + hoverOffset,
		PlayerConfig.START_POSITION.Z
	)
	
	-- Update BodyPosition target
	bodyPosition.Position = hoverPos
	
	-- Directly set CFrame for the flying pose (high lerp factor ensures
	-- immediate correction if anything knocks the character upright)
	local targetCFrame = getFlyingCFrame(hoverPos)
	humanoidRootPart.CFrame = humanoidRootPart.CFrame:Lerp(targetCFrame, 0.8)
end

--[[
	Disables the hover hold so player is affected by gravity.
]]
function PlayerController.disableHover()
	-- Disable BodyPosition hold so gravity takes over
	if bodyPosition then
		bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		bodyPosition.P = 10000 -- Reset to normal values
		bodyPosition.D = 1000
	end
	
	-- Restore BodyGyro to gameplay rotation control (all axes for flying pose)
	if bodyGyro then
		bodyGyro.MaxTorque = Vector3.new(40000, 40000, 40000)
	end
	
	-- Re-enable humanoid for gameplay (but with custom controls)
	if humanoid then
		humanoid.PlatformStand = false
		-- Keep movement disabled - we control it manually
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		-- Enable freefall so gravity works
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
	end
	
	-- Reset velocity for fresh start
	currentVelocity = Vector3.new(0, 0, 0)
	if humanoidRootPart then
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	end
end

--[[
	Disables player input (jumping).
	Used during game over screen.
]]
function PlayerController.disableInput()
	isInputEnabled = false
end

--[[
	Enables player input (jumping).
	Used when restarting from game over.
]]
function PlayerController.enableInput()
	isInputEnabled = true
end

--[[
	Sets an external guard callback for mouse/touch jump input.
	If the callback returns true, the jump is blocked.
	Used by GameController to block jumps when the mouse is over UI (e.g. leaderboard).
]]
function PlayerController.setInputGuard(guardFn)
	inputGuardCallback = guardFn
end

--[[
	Tells PlayerController to skip its next CharacterAdded handler.
	Used by GameController during managed respawns so setReadyPosition()
	isn't overwritten by the handler resetting to START_POSITION.
]]
function PlayerController.skipNextCharacterAdded()
	skipNextCharacterAdded = true
end

--[[
	Freezes the player in place completely.
	Used on game over to stop all movement.
]]
function PlayerController.freeze()
	-- Stop the update loop
	PlayerController.stopUpdate()
	
	-- Zero all velocities
	currentVelocity = Vector3.new(0, 0, 0)
	
	if humanoidRootPart then
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
		humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
		humanoidRootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		humanoidRootPart.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		
		-- Use BodyPosition with max force to hold player in place
		if bodyPosition then
			bodyPosition.Position = humanoidRootPart.Position
			bodyPosition.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			bodyPosition.P = 100000
			bodyPosition.D = 10000
		end
		
		-- Lock rotation
		if bodyGyro then
			bodyGyro.CFrame = humanoidRootPart.CFrame
			bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		end
	end
	
	-- Disable humanoid physics
	if humanoid then
		humanoid.PlatformStand = true
	end
end

--[[
	Restores normal player movement (for returning to lobby).
	Re-enables default Roblox character controls.
]]
function PlayerController.restoreNormalMovement()
	PlayerController.stopUpdate()

	-- Stop the flying pose RenderStepped loop
	if renderStepConnection then
		renderStepConnection:Disconnect()
		renderStepConnection = nil
	end
	cachedMotor6Ds = nil

	-- Re-enable the Animate script so normal animations resume
	if character then
		local animate = character:FindFirstChild("Animate")
		if animate then
			animate.Disabled = false
		end
	end

	-- Remove physics objects
	if bodyPosition then
		bodyPosition:Destroy()
		bodyPosition = nil
	end
	
	if bodyGyro then
		bodyGyro:Destroy()
		bodyGyro = nil
	end
	
	-- Re-enable normal humanoid movement
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.PlatformStand = false
		humanoid.WalkSpeed = 16 -- Default walk speed
		humanoid.JumpPower = 50 -- Default jump power
	end
	
	-- Re-enable collisions
	if character then
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = true
			end
		end
	end
end

--[[
	Returns the player's current vertical velocity.
	Used by GhostManager to send tilt data to other players.
]]
function PlayerController.getVelocityY()
	return currentVelocity.Y
end

--[[
	Cleans up the PlayerController.
]]
function PlayerController.destroy()
	PlayerController.stopUpdate()

	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end

	if renderStepConnection then
		renderStepConnection:Disconnect()
		renderStepConnection = nil
	end

	cachedMotor6Ds = nil

	if bodyPosition then
		bodyPosition:Destroy()
		bodyPosition = nil
	end

	if bodyGyro then
		bodyGyro:Destroy()
		bodyGyro = nil
	end
end

return PlayerController
