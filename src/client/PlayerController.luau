--[[
	PlayerController.luau
	
	Controls player avatar physics, gravity, jump, and forward movement.
	Uses the player's Roblox avatar instead of a separate object.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
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
	
	-- Use BodyGyro to keep character facing forward (right direction)
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(0, 4000, 0)
	bodyGyro.CFrame = CFrame.new(humanoidRootPart.Position, humanoidRootPart.Position + Vector3.new(1, 0, 0))
	bodyGyro.P = 3000
	bodyGyro.D = 500
	bodyGyro.Parent = humanoidRootPart
	
	-- Reset to starting position immediately
	PlayerController.reset()
	
	-- Set up input for jumping (only if not already connected)
	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end
	jumpConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.Space or input.UserInputType == Enum.UserInputType.Touch then
			PlayerController.jump()
		end
	end)
	
	-- Listen for character respawns (in case character gets destroyed)
	localPlayer.CharacterAdded:Connect(function(newCharacter)
		-- Skip if we're already resetting (to avoid double initialization)
		if isResetting then
			return
		end
		
		-- Character respawned, reinitialize
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
		bodyGyro.MaxTorque = Vector3.new(0, 4000, 0)
		bodyGyro.CFrame = CFrame.new(humanoidRootPart.Position, humanoidRootPart.Position + Vector3.new(1, 0, 0))
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
		
		-- Reset position
		isResetting = true
		local startPos = Constants.PLAYER.START_POSITION
		local lookAtPos = startPos + Vector3.new(1, 0, 0) -- Face +X direction
		humanoidRootPart.CFrame = CFrame.lookAt(startPos, lookAtPos)
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
		humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
		currentVelocity = Vector3.new(0, 0, 0)
		lastJumpTime = 0
		
		if bodyPosition then
			bodyPosition.Position = startPos
			bodyPosition.MaxForce = Vector3.new(0, 0, 0)
		end
		
		if bodyGyro then
			bodyGyro.CFrame = CFrame.new(startPos, startPos + Vector3.new(1, 0, 0))
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
	return Constants.PLAYER.START_POSITION
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
	-- This gives immediate upward boost, preventing the fall
	-- The feeling is: "I'm falling, I need to tap to stay up!"
	-- Reset Y velocity completely and apply jump force for consistent feel
	currentVelocity = Vector3.new(currentVelocity.X, Constants.PLAYER.JUMP_FORCE, 0)
	lastJumpTime = tick() -- Track jump time
	
	-- Apply directly to HumanoidRootPart for immediate response
	-- This makes the jump feel instant and responsive - like preventing a fall
	humanoidRootPart.Velocity = Vector3.new(humanoidRootPart.Velocity.X, Constants.PLAYER.JUMP_FORCE, 0)
	
	-- Play jump sound (optional - SoundManager may not be loaded yet)
	local success, SoundManager = pcall(function()
		return require(script.Parent.SoundManager)
	end)
	if success and SoundManager then
		SoundManager.playJump()
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
		currentVelocity = currentVelocity - Vector3.new(0, Constants.PLAYER.GRAVITY * deltaTime, 0)
		
		-- If on ground, stop downward velocity (but jump can still work)
		if isOnGround and currentVelocity.Y < 0 then
			currentVelocity = Vector3.new(currentVelocity.X, 0, 0)
		end
		
		-- Get forward speed (from SpeedManager if available, otherwise base speed)
		local forwardSpeed = Constants.PLAYER.BASE_FORWARD_SPEED
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
		if targetPos.Y < Constants.BOUNDARIES.MIN_Y then
			targetPos = Vector3.new(targetPos.X, Constants.BOUNDARIES.MIN_Y, targetPos.Z)
			currentVelocity = Vector3.new(currentVelocity.X, math.max(0, currentVelocity.Y), 0)
		elseif targetPos.Y > Constants.BOUNDARIES.MAX_Y then
			targetPos = Vector3.new(targetPos.X, Constants.BOUNDARIES.MAX_Y, targetPos.Z)
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
		
		-- Keep character facing forward (right direction) with BodyGyro
		if bodyGyro and humanoidRootPart then
			local currentPos = humanoidRootPart.Position
			local forwardDirection = Vector3.new(1, 0, 0) -- Face right (forward direction)
			bodyGyro.CFrame = CFrame.new(currentPos, currentPos + forwardDirection)
		end
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
		bodyGyro.MaxTorque = Vector3.new(0, 4000, 0) -- Only Y-axis rotation
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
	local startPos = Constants.PLAYER.START_POSITION
	local lookAtPos = startPos + Vector3.new(1, 0, 0) -- Face +X direction
	humanoidRootPart.CFrame = CFrame.lookAt(startPos, lookAtPos)
	humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
	currentVelocity = Vector3.new(0, 0, 0)
	lastJumpTime = 0
	
	if bodyPosition then
		bodyPosition.Position = startPos
		bodyPosition.MaxForce = Vector3.new(0, 0, 0) -- Disable
	end
	
	if bodyGyro then
		bodyGyro.CFrame = CFrame.new(startPos, startPos + Vector3.new(1, 0, 0))
	end
	
	-- Reset flag
	isResetting = false
end

--[[
	Sets the player to the ready position (floating in the air).
]]
function PlayerController.setReadyPosition()
	-- Re-acquire character references - wait for character to fully load
	character = localPlayer.Character
	if not character or not character.Parent then
		character = localPlayer.CharacterAdded:Wait()
	end
	
	-- Wait for essential parts to load (with timeout)
	humanoidRootPart = character:WaitForChild("HumanoidRootPart", 10)
	humanoid = character:WaitForChild("Humanoid", 10)
	
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
	
	-- Position player in the air at the ready Y position
	local readyPos = Vector3.new(
		Constants.PLAYER.START_POSITION.X,
		Constants.READY.PLAYER_Y,
		Constants.PLAYER.START_POSITION.Z
	)
	
	-- Disable humanoid movement during ready state
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.PlatformStand = true -- This prevents humanoid from applying forces
	
	-- Disable humanoid states that could interfere
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, false)
	
	-- Make character parts non-collidable (we handle collisions manually)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
	
	-- Set position facing +X direction (the direction we move)
	-- Use CFrame.lookAt for reliable facing direction
	local lookAtPos = readyPos + Vector3.new(1, 0, 0) -- Look toward +X
	humanoidRootPart.CFrame = CFrame.lookAt(readyPos, lookAtPos)
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
	
	-- Set up BodyGyro to maintain facing direction
	bodyGyro.CFrame = CFrame.lookAt(readyPos, lookAtPos)
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
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
	local baseY = Constants.READY.PLAYER_Y
	local hoverOffset = math.sin(time * Constants.READY.HOVER_SPEED) * Constants.READY.HOVER_AMPLITUDE
	local hoverPos = Vector3.new(
		Constants.PLAYER.START_POSITION.X,
		baseY + hoverOffset,
		Constants.PLAYER.START_POSITION.Z
	)
	
	-- Update BodyPosition target
	bodyPosition.Position = hoverPos
	
	-- Also directly set CFrame for smooth following
	-- Use CFrame.lookAt to face +X direction
	local lookAtPos = hoverPos + Vector3.new(1, 0, 0)
	local targetCFrame = CFrame.lookAt(hoverPos, lookAtPos)
	humanoidRootPart.CFrame = humanoidRootPart.CFrame:Lerp(targetCFrame, 0.1)
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
	
	-- Restore BodyGyro to normal rotation control
	if bodyGyro then
		bodyGyro.MaxTorque = Vector3.new(0, 4000, 0) -- Only Y-axis rotation
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
	Cleans up the PlayerController.
]]
function PlayerController.destroy()
	PlayerController.stopUpdate()
	
	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end
	
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
