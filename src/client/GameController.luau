--[[
	GameController.luau
	
	Orchestrates all systems: PlayerController, CameraController, SpeedManager,
	PipeManager, CollisionDetector, ScoreManager.
	Creates main game loop and handles state transitions.
	
	ARCHITECTURE NOTE:
	- Hub/Lobby modules are loaded immediately (StartButton, UI, ScoreManager)
	- Game modules are lazy-loaded only when the game starts
	- This ensures hub area has default Roblox behavior until game begins
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

-- Hub/Lobby modules - loaded immediately (don't affect player/camera)
local GameState = require(script.Parent.GameState)
local ScoreManager = require(script.Parent.ScoreManager)
local ScoreUI = require(script.Parent.ScoreUI)
local GameOverUI = require(script.Parent.GameOverUI)
local StartButton = require(script.Parent.StartButton)
local ReadyUI = require(script.Parent.ReadyUI)
local SoundManager = require(script.Parent.SoundManager)

-- Game modules - lazy loaded to avoid affecting hub
local PlayerController = nil
local CameraController = nil
local SpeedManager = nil
local PipeManager = nil
local CollisionDetector = nil
local ParallaxBackground = nil

local GameController = {}
GameController.__index = GameController

local gameLoopConnection = nil
local startInputConnection = nil
local readyHoverConnection = nil
local isGameInitialized = false

--[[
	Cleans up any leftover game objects from previous runs.
]]
local function cleanupLeftoverObjects()
	-- Remove any leftover pipes and background layers
	for _, obj in ipairs(workspace:GetChildren()) do
		-- Check for pipes (old naming: "Pipe", new naming: "Pipe_top", "Pipe_bottom")
		local isPipe = obj.Name == "Pipe" or 
			string.find(obj.Name, "Pipe_") == 1
		local isBackground = obj.Name == "BackgroundLayer1" or obj.Name == "BackgroundLayer2"
		
		if isPipe or isBackground then
			obj:Destroy()
		end
	end
	
	-- Remove any leftover physics objects from player (in case of Studio restart)
	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character
	if character then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local oldBp = hrp:FindFirstChild("BodyPosition")
			local oldBg = hrp:FindFirstChild("BodyGyro")
			if oldBp then oldBp:Destroy() end
			if oldBg then oldBg:Destroy() end
		end
		
		-- Also restore humanoid settings in case they were modified
		local humanoid = character:FindFirstChild("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid.JumpPower = 50
			humanoid.PlatformStand = false
		end
	end
end

--[[
	Ensures default Roblox camera and player controls are active.
	Called on startup to guarantee hub area works normally.
	This is the ONLY place where default behavior should be set for the hub.
]]
local function ensureDefaultRobloxBehavior()
	local localPlayer = Players.LocalPlayer
	local camera = workspace.CurrentCamera
	
	-- Ensure camera is in default mode FIRST
	camera.CameraType = Enum.CameraType.Custom
	
	-- Wait for character if needed (with timeout)
	local character = localPlayer.Character
	if not character then
		character = localPlayer.CharacterAdded:Wait()
	end
	
	if not character then
		warn("GameController: Could not get character for default behavior setup")
		return
	end
	
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 5)
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	
	-- Remove any physics objects that might interfere with movement
	if humanoidRootPart then
		local bodyPosition = humanoidRootPart:FindFirstChild("BodyPosition")
		local bodyGyro = humanoidRootPart:FindFirstChild("BodyGyro")
		local bodyVelocity = humanoidRootPart:FindFirstChild("BodyVelocity")
		local bodyForce = humanoidRootPart:FindFirstChild("BodyForce")
		
		if bodyPosition then bodyPosition:Destroy() end
		if bodyGyro then bodyGyro:Destroy() end
		if bodyVelocity then bodyVelocity:Destroy() end
		if bodyForce then bodyForce:Destroy() end
		
		-- Reset velocity
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
		humanoidRootPart.RotVelocity = Vector3.new(0, 0, 0)
	end
	
	if humanoid then
		-- Set camera subject to humanoid (default Roblox behavior)
		camera.CameraSubject = humanoid
		
		-- Ensure default movement settings
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		
		-- Ensure ALL humanoid states are enabled for normal movement
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		
		-- Re-enable collision on character parts
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = true
			end
		end
	end
end

--[[
	Initializes the game.
	
	SKIP_HUB MODE (default): Player goes directly to "Press SPACE to Start"
	HUB MODE: Player spawns in hub area and must interact with start button
	
	Set SKIP_HUB_ON_JOIN to false if you want players to explore the hub first.
]]

-- CONFIGURATION: Set to false to enable hub area on first join
local SKIP_HUB_ON_JOIN = true

function GameController.init()
	-- Clean up any leftover game objects first
	cleanupLeftoverObjects()
	
	-- Initialize ScoreManager early to fetch personal best
	ScoreManager.init()
	ScoreManager.requestPersonalBest()
	
	-- Initialize UI systems (but don't show them yet)
	ScoreUI.init()
	GameOverUI.init()
	ReadyUI.init()
	
	-- Initialize the start button (needed for returning to hub later)
	StartButton.init(function()
		-- This callback is called when player activates the start button from hub
		GameController.initGameSystems()
		GameController.startReady()
	end)
	
	if SKIP_HUB_ON_JOIN then
		-- SKIP HUB: Go directly to the game
		-- Hide the start button since we're skipping the hub
		StartButton.hide()
		
		-- Initialize game systems immediately
		GameController.initGameSystems()
		
		-- Go directly to the ready state ("Press SPACE to Start")
		GameController.startReady()
	else
		-- HUB MODE: Player spawns in hub and must find the start button
		GameState.setState(Constants.GAME.STATES.MENU)
		
		-- Ensure default Roblox behavior for hub area
		ensureDefaultRobloxBehavior()
		
		-- Also run cleanup again after a brief delay to catch late-loading issues
		task.delay(0.5, function()
			cleanupLeftoverObjects()
			ensureDefaultRobloxBehavior()
		end)
	end
end

--[[
	Initializes all game systems when the game actually starts.
	This is called when the player interacts with the start button.
	
	Game modules are lazy-loaded here to avoid affecting hub area.
]]
function GameController.initGameSystems()
	if isGameInitialized then
		return
	end
	isGameInitialized = true
	
	-- LAZY LOAD: Require game modules only when needed
	-- This ensures hub area is never affected by game module loading
	PlayerController = require(script.Parent.PlayerController)
	CameraController = require(script.Parent.CameraController)
	SpeedManager = require(script.Parent.SpeedManager)
	PipeManager = require(script.Parent.PipeManager)
	CollisionDetector = require(script.Parent.CollisionDetector)
	ParallaxBackground = require(script.Parent.ParallaxBackground)
	
	-- Initialize PlayerController (this will take over player movement)
	PlayerController.init()
	
	-- Initialize SpeedManager
	SpeedManager.reset()
	PlayerController.setSpeedManager(SpeedManager)
	
	-- Initialize CameraController (this will take over camera)
	CameraController.init(PlayerController)
	
	-- Initialize PipeManager
	PipeManager.init(PlayerController, SpeedManager)
	PipeManager.setSpeedManager(SpeedManager)
	
	-- Initialize CollisionDetector
	CollisionDetector.init(PlayerController, PipeManager)
	
	-- Initialize ParallaxBackground
	ParallaxBackground.init(PlayerController, SpeedManager)
	
	-- Set up pipe passed callback
	PipeManager.setOnPipePassed(function(pipe)
		ScoreManager.increment()
	end)
end

--[[
	Enters the ready state where player floats and waits to press Space.
]]
function GameController.startReady()
	GameState.setState(Constants.GAME.STATES.READY)
	
	-- Position player in the air at ready position
	PlayerController.setReadyPosition()
	
	-- Start camera
	CameraController.reset()
	CameraController.start()
	
	-- Start background
	ParallaxBackground.reset()
	ParallaxBackground.start()
	
	-- Pre-spawn pipes so they're visible during ready state
	PipeManager.reset()
	PipeManager.preSpawnPipes()
	
	-- Show ready UI
	ReadyUI.show()
	
	-- Start hover animation for player
	local hoverTime = 0
	readyHoverConnection = RunService.Heartbeat:Connect(function(deltaTime)
		hoverTime = hoverTime + deltaTime
		PlayerController.updateHover(hoverTime)
	end)
	
	-- Wait for Space press to start playing
	if startInputConnection then
		startInputConnection:Disconnect()
		startInputConnection = nil
	end
	
	startInputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.Space or input.UserInputType == Enum.UserInputType.Touch then
			if startInputConnection then
				startInputConnection:Disconnect()
				startInputConnection = nil
			end
			
			-- Stop hover animation
			if readyHoverConnection then
				readyHoverConnection:Disconnect()
				readyHoverConnection = nil
			end
			
			-- Hide ready UI and start playing
			ReadyUI.hide()
			GameController.startGame()
			
			-- Trigger the first jump immediately
			PlayerController.jump()
		end
	end)
end

--[[
	Starts the actual game (after player presses Space from ready state).
]]
function GameController.startGame()
	GameState.setState(Constants.GAME.STATES.PLAYING)
	
	-- Disable the hover hold - player will now be affected by gravity
	PlayerController.disableHover()
	
	-- Reset systems for new game (pipes are already pre-spawned in startReady)
	SpeedManager.reset()
	SpeedManager.start()
	ScoreManager.reset()
	
	-- Start all update loops
	-- Pipes are already spawned, just start the update loop
	PlayerController.startUpdate()
	PipeManager.start()
	ScoreUI.start()
	ScoreUI.show()
	
	-- Start main game loop
	gameLoopConnection = RunService.Heartbeat:Connect(function(deltaTime)
		-- Update speed progression
		SpeedManager.update(deltaTime)
		
		-- Check for collisions
		if CollisionDetector.checkCollision() then
			GameController.gameOver()
		end
	end)
end

--[[
	Handles game over.
]]
function GameController.gameOver()
	GameState.setState(Constants.GAME.STATES.GAME_OVER)
	
	-- Play death sound
	SoundManager.playDeath()
	
	-- Stop all systems
	if gameLoopConnection then
		gameLoopConnection:Disconnect()
		gameLoopConnection = nil
	end
	
	if readyHoverConnection then
		readyHoverConnection:Disconnect()
		readyHoverConnection = nil
	end
	
	-- Freeze the player completely (stops movement and holds in place)
	PlayerController.freeze()
	PlayerController.disableInput()
	
	-- Stop the camera from moving
	CameraController.stop()
	
	-- Stop other systems
	PipeManager.stop()
	SpeedManager.stop()
	ScoreUI.hide()
	
	-- Request updated personal best
	ScoreManager.requestPersonalBest()
	
	-- Show game over screen
	GameOverUI.show(ScoreManager.getScore(), ScoreManager.getPersonalBest())
	
	-- Wait before allowing restart
	task.wait(Constants.GAME.RESET_DELAY)
	
	-- Set up input for game over options
	-- E = Play Again, R = Return to Hub
	startInputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		
		if input.KeyCode == Enum.KeyCode.E then
			-- Play Again
			if startInputConnection then
				startInputConnection:Disconnect()
				startInputConnection = nil
			end
			GameOverUI.hide()
			
			-- Re-enable player input
			PlayerController.enableInput()
			
			-- Clear old pipes before restarting
			PipeManager.clear()
			
			-- Go back to ready state (player floats, press Space to start)
			GameController.startReady()
			
		elseif input.KeyCode == Enum.KeyCode.R then
			-- Return to Hub
			if startInputConnection then
				startInputConnection:Disconnect()
				startInputConnection = nil
			end
			GameOverUI.hide()
			
			-- Re-enable player input
			PlayerController.enableInput()
			
			-- Return to the hub/lobby area
			GameController.returnToLobby()
		end
	end)
end

--[[
	Returns player to lobby/menu state.
	Restores default Roblox behavior for hub area.
]]
function GameController.returnToLobby()
	GameState.setState(Constants.GAME.STATES.MENU)
	
	-- Stop all game systems
	if gameLoopConnection then
		gameLoopConnection:Disconnect()
		gameLoopConnection = nil
	end
	
	if startInputConnection then
		startInputConnection:Disconnect()
		startInputConnection = nil
	end
	
	if readyHoverConnection then
		readyHoverConnection:Disconnect()
		readyHoverConnection = nil
	end
	
	-- Stop game modules (only if they were loaded)
	if PlayerController then PlayerController.stopUpdate() end
	if CameraController then CameraController.stop() end
	if PipeManager then PipeManager.stop() end
	if ParallaxBackground then ParallaxBackground.stop() end
	if SpeedManager then SpeedManager.stop() end
	ScoreUI.stop()
	ScoreUI.hide()
	GameOverUI.hide()
	ReadyUI.hide()
	
	-- Clear pipes
	if PipeManager then PipeManager.clear() end
	
	-- Restore normal player movement
	if PlayerController then PlayerController.restoreNormalMovement() end
	
	-- Restore normal camera
	if CameraController then CameraController.restoreNormalCamera() end
	
	-- Ensure default Roblox behavior is restored
	ensureDefaultRobloxBehavior()
	
	-- Show start button again
	StartButton.show()
	
	-- Reset game initialized flag so game can be re-entered
	isGameInitialized = false
end

--[[
	Resets the game to menu state.
]]
function GameController.reset()
	GameState.setState(Constants.GAME.STATES.MENU)
	
	-- Stop all systems
	if gameLoopConnection then
		gameLoopConnection:Disconnect()
		gameLoopConnection = nil
	end
	
	if startInputConnection then
		startInputConnection:Disconnect()
		startInputConnection = nil
	end
	
	if readyHoverConnection then
		readyHoverConnection:Disconnect()
		readyHoverConnection = nil
	end
	
	-- Stop game modules (only if loaded)
	if PlayerController then PlayerController.stopUpdate() end
	if CameraController then CameraController.stop() end
	if PipeManager then PipeManager.stop() end
	if ParallaxBackground then ParallaxBackground.stop() end
	if SpeedManager then SpeedManager.stop() end
	ScoreUI.stop()
	
	-- Reset all systems (only if loaded)
	if PlayerController then PlayerController.reset() end
	if SpeedManager then SpeedManager.reset() end
	if PipeManager then PipeManager.clear() end
	ScoreManager.reset()
	if CameraController then CameraController.reset() end
	if ParallaxBackground then ParallaxBackground.reset() end
end

--[[
	Sets up initial input to start the game.
	Note: This is now handled by the StartButton, but kept for compatibility.
]]
function GameController.setupStartInput()
	-- Start button now handles this - no keyboard input needed for initial start
	-- The player must interact with the physical button in the world
end

--[[
	Cleans up the GameController.
]]
function GameController.destroy()
	GameController.reset()
	ScoreUI.destroy()
	GameOverUI.destroy()
	ReadyUI.destroy()
	StartButton.destroy()
	
	-- Destroy game modules (only if loaded)
	if ParallaxBackground then ParallaxBackground.destroy() end
	if PlayerController then PlayerController.destroy() end
	if CameraController then CameraController.destroy() end
	
	if readyHoverConnection then
		readyHoverConnection:Disconnect()
		readyHoverConnection = nil
	end
end

return GameController
