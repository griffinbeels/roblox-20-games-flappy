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
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CameraConfig = require(ReplicatedStorage.Shared.CameraConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)
local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)
local JumpInput = require(script.Parent.JumpInput)

-- Hub/Lobby modules - loaded immediately (don't affect player/camera)
local GameState = require(script.Parent.GameState)
local ScoreManager = require(script.Parent.ScoreManager)
local ScoreUI = require(script.Parent.ScoreUI)
local GameOverUI = require(script.Parent.GameOverUI)
local StartButton = require(script.Parent.StartButton)
local ReadyUI = require(script.Parent.ReadyUI)
local LeaderboardUI = require(script.Parent.LeaderboardUI)
local SoundManager = require(script.Parent.SoundManager)
local OptionsUI = require(script.Parent.OptionsUI)
local DebugCameraUI = require(script.Parent.DebugCameraUI)
local Analytics = require(script.Parent.Analytics)
local AnalyticsConfig = require(ReplicatedStorage.Shared.AnalyticsConfig)
local CurrencyManager = require(script.Parent.CurrencyManager)
local CurrencyUI = require(script.Parent.CurrencyUI)
local ShopManager = require(script.Parent.ShopManager)
local ShopUI = require(script.Parent.ShopUI)
local MissionManager = require(script.Parent.MissionManager)
local MissionsUI = require(script.Parent.MissionsUI)
local PrestigeManager = require(script.Parent.PrestigeManager)
local PrestigeUI = require(script.Parent.PrestigeUI)

-- Game modules - lazy loaded to avoid affecting hub
local PlayerController = nil
local CameraController = nil
local SpeedManager = nil
local PipeManager = nil
local CollisionDetector = nil
local ParallaxBackground = nil
local EffectRegistry = nil
local BaconCollectible = nil

local GameController = {}
GameController.__index = GameController

local gameLoopConnection = nil
local startInputConnection = nil
local readyHoverConnection = nil
local respawnConnection = nil
local characterRemovingConnection = nil
local humanoidDiedConnection = nil
local debugProgressResetConnection = nil
local speedDebugLogToggleConnection = nil
local requestRespawnRemote = nil -- RemoteEvent to ask server for a new character
local isGameInitialized = false
local currentState = nil -- tracks actual state to prevent reentrant transitions
local isRespawning = false -- true while a manual respawn is in progress
local isGameOverDeath = false -- true when the game killed the humanoid (not a manual reset)
local PRESTIGE_ENABLED = PrestigeConfig.ENABLED == true
local desiredSpeedDebugLogEnabled = false

local function buildRuntimeMissionPayload(score)
	local tuning = RuntimeTuning.getActiveTuning()
	return {
		score = score,
		speedCapMultiplier = tuning.speedCapMultiplier,
		gravity = tuning.gravity,
		jumpPowerMultiplier = tuning.jumpPowerMultiplier,
	}
end

--[[
	Hides ALL game UI screens.
	Single source of truth — add any new UI screens here.
	Safe to call multiple times; each .hide() is a no-op if already hidden.
]]
local function hideAllGameUI()
	GameOverUI.hide()
	ReadyUI.hide()
	ReadyUI.hideShopButton()
	ReadyUI.hideMissionsButton()
	ReadyUI.hidePrestigeButton()
	ScoreUI.hide()
	ShopUI.hide()
	MissionsUI.hide()
	PrestigeUI.hide()
end

local function handleDebugProgressReset(payload)
	local mode = if type(payload) == "table" then tostring(payload.mode or "all") else tostring(payload or "all")
	local errors = if type(payload) == "table" and type(payload.errors) == "table" then payload.errors else {}

	CurrencyManager.resetPending()
	CurrencyManager.setLifetimeBalance(0)
	CurrencyManager.requestBalance()

	ScoreManager.reset()
	if ScoreManager.debugForcePersonalBest then
		ScoreManager.debugForcePersonalBest(0)
	end
	ScoreManager.requestPersonalBest()

	if mode == "all" and ShopManager.requestData then
		local ok, reason = ShopManager.requestData()
		if not ok then
			warn("[DebugReset] Failed to refresh shop state: " .. tostring(reason))
		end
	end

	MissionManager.requestState()
	if PRESTIGE_ENABLED then
		PrestigeManager.requestState()
	end

	if currentState ~= "playing" and ShopManager.needsRefresh and ShopManager.needsRefresh() then
		ShopManager.applyAllEquipped()
	end

	if #errors > 0 then
		warn("[DebugReset] Reset completed with issues: " .. table.concat(errors, " | "))
	else
		warn("[DebugReset] Reset completed (" .. mode .. ").")
	end
end

local function handleSpeedDebugLogToggle(payload)
	local nextEnabled = nil

	if type(payload) == "table" then
		local action = string.lower(tostring(payload.action or "toggle"))
		if action == "set" then
			nextEnabled = (payload.enabled == true)
		end
	elseif type(payload) == "boolean" then
		nextEnabled = payload
	end

	if nextEnabled == nil then
		if SpeedManager and SpeedManager.toggleDebugSpeedLog then
			nextEnabled = SpeedManager.toggleDebugSpeedLog()
		else
			nextEnabled = not desiredSpeedDebugLogEnabled
		end
	else
		if SpeedManager and SpeedManager.setDebugSpeedLogEnabled then
			nextEnabled = SpeedManager.setDebugSpeedLogEnabled(nextEnabled)
		end
	end

	desiredSpeedDebugLogEnabled = (nextEnabled == true)

	-- If the game systems are not initialized yet, acknowledge the pending state.
	if not SpeedManager then
		warn(string.format("[SpeedDebug] Console speed log will be %s when SpeedManager initializes.", desiredSpeedDebugLogEnabled and "ENABLED" or "DISABLED"))
	end
end

--[[
	Disconnects ALL active gameplay connections.
	Called at the top of every state transition to guarantee a clean slate.
	Safe to call multiple times — each disconnect is guarded.
]]
local function disconnectAll()
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
end

--[[
	Stops ALL running game systems (physics, pipes, speed, camera, etc.).
	Single source of truth — add any new game systems here.
	Safe to call multiple times; each .stop() is a no-op if already stopped.
	MUST NOT yield — all calls are synchronous.
]]
local function stopAllGameSystems()
	if PlayerController then PlayerController.stopUpdate() end
	if PlayerController then PlayerController.disableInput() end
	if CameraController then CameraController.stop() end
	if PipeManager then PipeManager.stop() end
	if SpeedManager then SpeedManager.stop() end
	if ParallaxBackground then ParallaxBackground.stop() end
	if EffectRegistry then EffectRegistry.stopAll() end
	if BaconCollectible then BaconCollectible.stop() end
	ScoreUI.stop()
end

--[[
	Full emergency lockdown — invalidate state, disconnect inputs, hide UI, stop systems.
	Called when the character is removed (respawn) to immediately prevent all interaction.
	MUST NOT yield — everything here is synchronous.
]]
local function enterRespawnLockdown()
	if currentState == "playing" then
		MissionManager.reportEvent("run_abandoned")
		if PRESTIGE_ENABLED then
			PrestigeManager.reportRunAbandoned()
		end
	end

	currentState = nil
	isRespawning = true
	-- Disconnect Humanoid.Died so it can't re-fire on the dying character
	if humanoidDiedConnection then
		humanoidDiedConnection:Disconnect()
		humanoidDiedConnection = nil
	end
	disconnectAll()
	hideAllGameUI()
	stopAllGameSystems()
end

--[[
	Fires the RequestRespawn remote to ask the server for a new character.
	Called after manual resets and Play Again. Safe to call if remote isn't found yet.
]]
local function fireRequestRespawn()
	-- Tell PlayerController to skip its CharacterAdded handler so it doesn't
	-- fight with setReadyPosition() (which handles all positioning)
	if PlayerController then
		PlayerController.skipNextCharacterAdded()
	end

	if not requestRespawnRemote then
		local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
		if remoteFolder then
			requestRespawnRemote = remoteFolder:FindFirstChild("RequestRespawn")
		end
	end
	if requestRespawnRemote then
		requestRespawnRemote:FireServer()
	end
end

--[[
	Connects the current Humanoid's .Died event to trigger immediate lockdown.
	This fires the instant the player presses "Reset Character" (R),
	unlike CharacterRemoving which fires seconds later after the death animation.
]]
local function connectHumanoidDied(humanoidInstance)
	if humanoidDiedConnection then
		humanoidDiedConnection:Disconnect()
		humanoidDiedConnection = nil
	end
	if not humanoidInstance then return end

	humanoidDiedConnection = humanoidInstance.Died:Connect(function()
		if not isGameInitialized then return end
		if currentState == "menu" then return end
		if isRespawning then return end
		if isGameOverDeath then return end -- game killed the humanoid, not a manual reset
		enterRespawnLockdown()
		fireRequestRespawn() -- ask server for a new character
	end)
end

--[[
	Cleans up any leftover game objects from previous runs.
]]
local function cleanupLeftoverObjects()
	-- Remove any leftover pipes, background layers, and floor layers
	for _, obj in ipairs(workspace:GetChildren()) do
		-- Check for pipes (old naming: "Pipe", new naming: "Pipe_top", "Pipe_bottom")
		local isPipe = obj.Name == "Pipe" or
			string.find(obj.Name, "Pipe_") == 1 or
			string.find(obj.Name, "PipeModel_") == 1 or
			string.find(obj.Name, "PipeHitbox_") == 1
		local isBackground = obj.Name == "BackgroundLayer1" or obj.Name == "BackgroundLayer2"
		local isFloor = obj.Name == "FloorLayer" or obj.Name == "FloorMeshTile" or obj.Name == "FloorCollider"
		local isBacon = obj.Name == "BaconCollectible"
		local isGhosts = obj.Name == "Ghosts"
		local isLeaderboard = obj.Name == GameConfig.LEADERBOARD.PART.NAME

		if isPipe or isBackground or isFloor or isBacon or isGhosts or isLeaderboard then
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
	-- Find the RequestRespawn remote (created by server before client runs)
	local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if remoteFolder then
		requestRespawnRemote = remoteFolder:FindFirstChild("RequestRespawn")
		local debugProgressResetRemote = remoteFolder:WaitForChild("DebugProgressReset", 10)
		if debugProgressResetRemote and not debugProgressResetConnection then
			debugProgressResetConnection = debugProgressResetRemote.OnClientEvent:Connect(handleDebugProgressReset)
		end
		local speedDebugLogToggleRemote = remoteFolder:WaitForChild("ToggleSpeedDebugLog", 10)
		if speedDebugLogToggleRemote and not speedDebugLogToggleConnection then
			speedDebugLogToggleConnection = speedDebugLogToggleRemote.OnClientEvent:Connect(handleSpeedDebugLogToggle)
		end
	end

	-- Clean up any leftover game objects first
	cleanupLeftoverObjects()

	-- Initialize ScoreManager and CurrencyManager early to fetch persisted data.
	-- Both use task.spawn internally to wait for server remotes without blocking,
	-- then auto-request their initial values once connected.
	ScoreManager.init()
	CurrencyManager.init()
	ShopManager.init()
	MissionManager.init()
	if PRESTIGE_ENABLED then
		PrestigeManager.init()
	end

	-- Initialize UI systems (but don't show them yet)
	ScoreUI.init()
	GameOverUI.init()
	LeaderboardUI.init()
	ReadyUI.init()
	ShopUI.init()
	MissionsUI.init()
	if PRESTIGE_ENABLED then
		PrestigeUI.init()
	end

	ReadyUI.setMissionsBadgeCount(MissionManager.getNonPrestigeRedeemableCount())
	if PRESTIGE_ENABLED then
		ReadyUI.setPrestigeBadgeCount(MissionManager.getPrestigeRedeemableCount())
	end
	MissionManager.onStateChanged(function(state)
		ReadyUI.setMissionsBadgeCount(MissionManager.getNonPrestigeRedeemableCount(state))
		if PRESTIGE_ENABLED then
			ReadyUI.setPrestigeBadgeCount(MissionManager.getPrestigeRedeemableCount(state))
		end
	end)

	-- Initialize CurrencyUI (shown during READY state only, above leaderboard)
	CurrencyUI.init()
	CurrencyUI.start()

	-- Initialize options menu (always visible across all game states)
	OptionsUI.init()

	-- Initialize debug camera panel (hidden until /debugcam chat command)
	DebugCameraUI.init()

	-- Initialize the start button (needed for returning to hub later)
	StartButton.init(function()
		-- This callback is called when player activates the start button from hub
		if ShopManager.waitUntilReady(3) then
			-- Pre-apply equipped loadout so systems initialize with saved visuals.
			ShopManager.applyAllEquipped()
		end
		GameController.initGameSystems()
		GameController.startReady()
	end)
	
	if SKIP_HUB_ON_JOIN then
		-- SKIP HUB: Go directly to the game
		-- Hide the start button since we're skipping the hub
		StartButton.hide()
		
		if ShopManager.waitUntilReady(3) then
			-- Pre-apply equipped loadout so systems initialize with saved visuals.
			ShopManager.applyAllEquipped()
		end

		-- Initialize game systems immediately
		GameController.initGameSystems()
		
		-- Go directly to the ready state ("Press SPACE to Start")
		GameController.startReady()
	else
		-- HUB MODE: Player spawns in hub and must find the start button
		GameState.setState(GameConfig.STATES.MENU)
		
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
	BaconCollectible = require(script.Parent.BaconCollectible)

	-- Initialize PlayerController (this will take over player movement)
	PlayerController.init()
	PlayerController.setInputGuard(function()
		return LeaderboardUI.isMouseOver()
			or ReadyUI.isShopButtonMouseOver()
			or ReadyUI.isMissionsButtonMouseOver()
			or ReadyUI.isPrestigeButtonMouseOver()
			or ShopUI.isOpen()
			or MissionsUI.isOpen()
			or PrestigeUI.isOpen()
	end)

	-- Initialize SpeedManager
	SpeedManager.reset()
	local currentSpeedDebugState = if SpeedManager.isDebugSpeedLogEnabled then SpeedManager.isDebugSpeedLogEnabled() else false
	if SpeedManager.setDebugSpeedLogEnabled and currentSpeedDebugState ~= desiredSpeedDebugLogEnabled then
		SpeedManager.setDebugSpeedLogEnabled(desiredSpeedDebugLogEnabled)
	end
	PlayerController.setSpeedManager(SpeedManager)
	
	-- Initialize CameraController (this will take over camera)
	CameraController.init(PlayerController)
	
	-- Initialize PipeManager
	PipeManager.init(PlayerController, SpeedManager)
	PipeManager.setSpeedManager(SpeedManager)
	
	-- Initialize CollisionDetector
	CollisionDetector.init(PlayerController, PipeManager)
	
	-- Initialize ParallaxBackground and wire into collision detection
	ParallaxBackground.init(PlayerController)
	CollisionDetector.setParallaxBackground(ParallaxBackground)

	-- Initialize effect registry and register all effects
	EffectRegistry = require(script.Parent.EffectRegistry)
	EffectRegistry.register("Trail", require(script.Parent.TrailManager))
	EffectRegistry.register("Ghost", require(script.Parent.GhostManager))
	EffectRegistry.register("Poof", require(script.Parent.PoofManager))
	EffectRegistry.initAll()

	-- Wire options menu ghost toggle to GhostManager
	OptionsUI.onOptionChanged("ShowGhosts", function(enabled)
		EffectRegistry.get("Ghost").setEnabled(enabled)
	end)

	-- Initialize BaconCollectible (physical bacon in pipe gaps)
	BaconCollectible.init(PlayerController)

	-- Wire fly-to-score animation target (score label position)
	BaconCollectible.setFlyTarget(function()
		return ScoreUI.getScoreLabelPosition()
	end)
	BaconCollectible.setGameSpeedScaleSource(function()
		if SpeedManager and SpeedManager.getCurrentMultiplier then
			return SpeedManager.getCurrentMultiplier()
		end
		return 1
	end)

	-- Spawn bacon when pipes spawn
	PipeManager.setOnPipeSpawned(function(pair)
		BaconCollectible.spawnAtGap(pair.xPosition, pair.gapY, pair.gapSize)
	end)

	-- Award currency immediately when bacon is collected
	BaconCollectible.setOnCollected(function()
		CurrencyManager.earnFromPipe()
	end)

	-- Increment score when fly animation completes (bacon reaches score UI)
	BaconCollectible.setOnAnimationComplete(function()
		if currentState ~= "playing" then return end
		ScoreManager.increment()
		MissionManager.reportEvent("score_progress", buildRuntimeMissionPayload(ScoreManager.getScore()))
	end)

	-- Wire shop button on ready screen → open shop modal
	ReadyUI.setOnShopClick(function()
		if MissionsUI.isOpen() then
			MissionsUI.hide()
		end
		if PrestigeUI.isOpen() then
			PrestigeUI.hide()
		end
		ShopUI.show()
	end)

	-- Wire missions button on ready screen -> open missions modal
	ReadyUI.setOnMissionsClick(function()
		if ShopUI.isOpen() then
			ShopUI.hide()
		end
		if PrestigeUI.isOpen() then
			PrestigeUI.hide()
		end
		MissionsUI.show()
	end)

	MissionsUI.setMissionActionRouter(function(mission)
		if PRESTIGE_ENABLED ~= true or type(mission) ~= "table" or mission.canRedeem ~= true then
			return nil
		end

		for _, reward in ipairs(mission.rewards or {}) do
			if type(reward) == "table" and reward.type == "prestige_level" then
				return {
					kind = "route",
					routeId = "prestige_ui",
				}
			end
		end

		return nil
	end)

	MissionsUI.setOnRouteRequest(function(routeId, _context)
		if routeId == "prestige_ui" and PRESTIGE_ENABLED == true then
			if ShopUI.isOpen() then
				ShopUI.hide()
			end
			PrestigeUI.show()
			return
		end
	end)

	-- Wire prestige button on ready screen -> open prestige modal
	if PRESTIGE_ENABLED then
		ReadyUI.setOnPrestigeClick(function()
			if ShopUI.isOpen() then
				ShopUI.hide()
			end
			if MissionsUI.isOpen() then
				MissionsUI.hide()
			end
			PrestigeUI.show()
		end)
	end

	local function applyShopRefreshIfNeeded()
		if currentState ~= "ready" then return end
		if not ShopManager.needsRefresh() then return end

		ShopManager.applyAllEquipped()

		-- Rebuild visual systems with new config
		ParallaxBackground.destroy()
		ParallaxBackground.init(PlayerController)
		CollisionDetector.setParallaxBackground(ParallaxBackground)
		ParallaxBackground.reset()
		ParallaxBackground.start()

		if BaconCollectible then BaconCollectible.clear() end
		PipeManager.clear()
		PipeManager.resolveStyles()
		PipeManager.preSpawnPipes()
		BaconCollectible.start()

		if EffectRegistry then EffectRegistry.resetAll() end
	end

	-- Wire shop close → apply equipped items + refresh game systems if dirty
	local function refreshReadyPipesForPrestigeTuning()
		if currentState ~= "ready" then return end
		if not PipeManager then return end

		if BaconCollectible then BaconCollectible.clear() end
		PipeManager.clear()
		PipeManager.preSpawnPipes()
		if BaconCollectible then BaconCollectible.start() end
	end

	ShopUI.setOnClose(function()
		applyShopRefreshIfNeeded()
	end)

	-- Ensure saved equipped loadout is applied as soon as initial shop data arrives.
	ShopManager.onReady(function()
		if ShopUI.isOpen() or MissionsUI.isOpen() or PrestigeUI.isOpen() then return end
		applyShopRefreshIfNeeded()
	end)

	if PRESTIGE_ENABLED then
		PrestigeManager.onStateChanged(function(state, context)
			local isReadyToPrestige = state and state.nextLevel and state.nextLevel.unlocked == true
			ReadyUI.setPrestigeReadyIndicator(isReadyToPrestige)

			if type(context) == "table" and (context.type == "tuning_applied" or context.type == "prestige_success") then
				refreshReadyPipesForPrestigeTuning()
			end
		end)
	end

	-- Handle manual respawn (player clicks "Reset Character" in Roblox menu).
	-- Two-phase approach:
	--   CharacterRemoving: INSTANT lockdown (no yields) — hides UI, stops systems
	--   CharacterAdded:    Waits for new character, then restarts the round
	-- This eliminates the gap where the player could interact with a dead character.
	if characterRemovingConnection then
		characterRemovingConnection:Disconnect()
	end
	characterRemovingConnection = Players.LocalPlayer.CharacterRemoving:Connect(function()
		if not isGameInitialized then return end
		if currentState == "menu" then return end
		if isRespawning then return end
		if isGameOverDeath then return end -- game killed the humanoid, not a manual reset

		-- Immediate synchronous lockdown — no yields allowed
		enterRespawnLockdown()
	end)

	if respawnConnection then
		respawnConnection:Disconnect()
	end
	respawnConnection = Players.LocalPlayer.CharacterAdded:Connect(function(newCharacter)
		if not isGameInitialized then return end
		if currentState == "menu" then return end

		-- Wait for the new character to fully load
		newCharacter:WaitForChild("HumanoidRootPart", 10)
		local newHumanoid = newCharacter:WaitForChild("Humanoid", 10)

		-- If this respawn was from a game over death (pipe collision),
		-- just set up the new character quietly — game over screen stays visible.
		-- Play Again will handle the restart.
		if isGameOverDeath then
			isGameOverDeath = false
			-- Connect Humanoid.Died for future manual resets on the new character
			connectHumanoidDied(newHumanoid)
			return
		end

		-- === Manual reset path ===

		-- Ensure lockdown is in place (Humanoid.Died should have done this,
		-- but handle the edge case where CharacterAdded fires without it)
		if not isRespawning then
			enterRespawnLockdown()
		end

		-- Reconnect Humanoid.Died AFTER lockdown so it doesn't get
		-- immediately disconnected by enterRespawnLockdown()
		connectHumanoidDied(newHumanoid)

		-- Give PlayerController's own CharacterAdded handler time to
		-- re-create physics objects on the new character
		task.wait(0.1)

		-- Clean up game data
		if BaconCollectible then BaconCollectible.clear() end
		if PipeManager then PipeManager.clear() end
		if SpeedManager then SpeedManager.reset() end
		ScoreManager.reset()

		-- Re-enable input (was disabled during lockdown)
		if PlayerController then PlayerController.enableInput() end

		isRespawning = false

		-- Restart the round from ready state
		GameController.startReady()
	end)

	-- Connect Humanoid.Died on the INITIAL character for instant reset detection.
	-- (CharacterAdded reconnects it for subsequent characters.)
	local initialChar = Players.LocalPlayer.Character
	if initialChar then
		local initialHumanoid = initialChar:FindFirstChild("Humanoid")
		if initialHumanoid then
			connectHumanoidDied(initialHumanoid)
		end
	end
end

--[[
	Enters the ready state where player floats and waits to press Space.
]]
function GameController.startReady()
	-- Prevent reentrant calls — only one READY state at a time
	if currentState == "ready" then return end

	-- Clean slate: disconnect everything from any previous state
	disconnectAll()

	isGameOverDeath = false
	currentState = "ready"
	GameState.setState(GameConfig.STATES.READY)

	-- Apply equipped shop items (ensures visuals match on first game and every round)
	ShopManager.applyAllEquipped()

	-- Position player in the air at ready position
	PlayerController.setReadyPosition()

	-- Start camera
	CameraController.reset()
	CameraController.start()

	-- Start background
	ParallaxBackground.reset()
	ParallaxBackground.start()

	-- Reset all effects (trail, ghost, etc.) for new round
	if EffectRegistry then EffectRegistry.resetAll() end

	-- Pre-spawn pipes so they're visible during ready state
	PipeManager.reset()
	PipeManager.preSpawnPipes()

	-- Start bacon collectible system (bacons already spawned via onPipeSpawned)
	BaconCollectible.start()

	-- Show ready UI
	ReadyUI.show()
	LeaderboardUI.show()
	ReadyUI.showShopButton()
	ReadyUI.showMissionsButton()
	if PRESTIGE_ENABLED then
		ReadyUI.showPrestigeButton()
		ReadyUI.setPrestigeReadyIndicator(PrestigeManager.isPrestigeReady())
		PrestigeUI.hide()
	else
		ReadyUI.hidePrestigeButton()
	end
	CurrencyUI.show()

	-- Start hover animation for player
	local hoverTime = 0
	readyHoverConnection = RunService.Heartbeat:Connect(function(deltaTime)
		hoverTime = hoverTime + deltaTime
		PlayerController.updateHover(hoverTime)
	end)

	-- Wait for jump input to start playing
	startInputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- Guard: only act if we're still in READY state
		if currentState ~= "ready" then return end
		-- Block input while a manual respawn is in progress
		if isRespawning then return end
		-- Block input while any ready-state modal is open
		if ShopUI.isOpen() or MissionsUI.isOpen() or PrestigeUI.isOpen() then return end

		-- Open shop or missions directly on pointer input over their buttons.
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if ReadyUI.isShopButtonMouseOver() then
				if MissionsUI.isOpen() then
					MissionsUI.hide()
				end
				if PrestigeUI.isOpen() then
					PrestigeUI.hide()
				end
				ShopUI.show()
				return
			end
			if ReadyUI.isMissionsButtonMouseOver() then
				if ShopUI.isOpen() then
					ShopUI.hide()
				end
				if PrestigeUI.isOpen() then
					PrestigeUI.hide()
				end
				MissionsUI.show()
				return
			end
			if PRESTIGE_ENABLED and ReadyUI.isPrestigeButtonMouseOver() then
				if ShopUI.isOpen() then
					ShopUI.hide()
				end
				if MissionsUI.isOpen() then
					MissionsUI.hide()
				end
				PrestigeUI.show()
				return
			end
		end

		if not JumpInput.isJump(input) then return end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			if UserInputService:GetFocusedTextBox() then return end
		elseif input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if gameProcessed
				or LeaderboardUI.isMouseOver()
				or ReadyUI.isShopButtonMouseOver()
				or ReadyUI.isMissionsButtonMouseOver()
				or ReadyUI.isPrestigeButtonMouseOver() then
				return
			end
		end

		-- Hide ready UI and start playing
		ReadyUI.hide()
		ReadyUI.hideShopButton()
		ReadyUI.hideMissionsButton()
		ReadyUI.hidePrestigeButton()
		ShopUI.hide()
		MissionsUI.hide()
		PrestigeUI.hide()
		GameController.startGame()

		-- Trigger the first jump immediately
		PlayerController.jump()
	end)
end

--[[
	Starts the actual game (after player presses Space from ready state).
]]
function GameController.startGame()
	-- Prevent reentrant calls
	if currentState == "playing" then return end

	-- Clean slate: disconnect everything from READY state
	disconnectAll()

	currentState = "playing"
	GameState.setState(GameConfig.STATES.PLAYING)
	MissionManager.reportEvent("run_started")
	if PRESTIGE_ENABLED then
		PrestigeManager.reportRunStarted()
	end
	ShopUI.hide()
	MissionsUI.hide()
	if PRESTIGE_ENABLED then
		PrestigeUI.hide()
	end

	-- Analytics: track game start + progression begin
	Analytics.logCustomEvent(AnalyticsConfig.EVENTS.GAME_START)
	Analytics.logProgressionStart(AnalyticsConfig.PROGRESSION.RUN)

	-- Transition camera to gameplay framing (player further left on screen)
	CameraController.setTargetScreenX(CameraConfig.PLAYER_SCREEN_X_PLAYING)

	-- Disable the hover hold - player will now be affected by gravity
	PlayerController.disableHover()

	-- Reset systems for new game (pipes are already pre-spawned in startReady)
	SpeedManager.reset()
	SpeedManager.start()
	ScoreManager.reset()
	CurrencyManager.resetPending()

	-- Start all update loops
	-- Pipes are already spawned, just start the update loop
	PlayerController.startUpdate()
	PipeManager.start()
	ScoreUI.start()
	ScoreUI.show()

	-- Start main game loop
	gameLoopConnection = RunService.Heartbeat:Connect(function(deltaTime)
		-- Guard: only run if we're still in PLAYING state
		if currentState ~= "playing" then return end

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
	-- Prevent reentrant calls (e.g. collision detected on two consecutive frames)
	if currentState == "gameOver" then return end

	-- Clean slate: disconnect game loop and any other connections
	disconnectAll()

	currentState = "gameOver"
	GameState.setState(GameConfig.STATES.GAME_OVER)
	ShopUI.hide()
	MissionsUI.hide()
	if PRESTIGE_ENABLED then
		PrestigeUI.hide()
	end

	-- Resolve any collected bacon whose fly animation has not finished yet.
	-- This keeps final score in sync with collected bacon even on death frames.
	local pendingBaconScore = 0
	if BaconCollectible and BaconCollectible.consumePendingAnimationCount then
		pendingBaconScore = BaconCollectible.consumePendingAnimationCount()
	end
	for _ = 1, pendingBaconScore do
		ScoreManager.increment(false)
	end

	-- Analytics: track game over + progression result
	local finalScore = ScoreManager.getScore()
	local runtimeTuning = RuntimeTuning.getActiveTuning()
	local currentSpeedMultiplier = SpeedManager and SpeedManager.getCurrentMultiplier and SpeedManager.getCurrentMultiplier() or nil
	local missionRunFinishedPayload = buildRuntimeMissionPayload(finalScore)
	if currentSpeedMultiplier ~= nil then
		missionRunFinishedPayload.maxSpeedMultiplierReached = currentSpeedMultiplier
	end
	MissionManager.reportEvent("run_finished", missionRunFinishedPayload)
	if PRESTIGE_ENABLED then
		PrestigeManager.reportRunFinished(finalScore, {
			maxSpeedMultiplierReached = currentSpeedMultiplier,
		})
	end
	local currentSpeed = SpeedManager and SpeedManager.getCurrentSpeed and SpeedManager.getCurrentSpeed() or nil
	local prestigeState = PrestigeManager.getState()
	local prestigeLevel = prestigeState and prestigeState.progression and prestigeState.progression.level or 0
	local speedCap = runtimeTuning.speedCapMultiplier
	local gravity = runtimeTuning.gravity
	local jumpPower = runtimeTuning.jumpPowerMultiplier

	Analytics.logCustomEvent(AnalyticsConfig.EVENTS.GAME_OVER, finalScore, {
		speed = currentSpeed,
		speedCap = speedCap,
		gravity = gravity,
		jumpPower = jumpPower,
		prestigeLevel = prestigeLevel,
	})
	if PRESTIGE_ENABLED then
		Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PRESTIGE_RUN_OUTCOME, finalScore, {
			score = finalScore,
			speedCap = speedCap,
			gravity = gravity,
			jumpPower = jumpPower,
			prestigeLevel = prestigeLevel,
		})
	end
	if finalScore > 0 then
		Analytics.logProgressionComplete(AnalyticsConfig.PROGRESSION.RUN, nil, finalScore)
	else
		Analytics.logProgressionFail(AnalyticsConfig.PROGRESSION.RUN, nil, finalScore)
	end

	-- Play death sound
	SoundManager.playDeath()

	-- Freeze the player completely (stops movement and holds in place)
	PlayerController.freeze()
	PlayerController.disableInput()

	-- Kill the humanoid for death effect (flag prevents respawn handlers from
	-- triggering lockdown — game over screen stays visible)
	isGameOverDeath = true
	local deathChar = Players.LocalPlayer.Character
	if deathChar then
		local deathHumanoid = deathChar:FindFirstChild("Humanoid")
		if deathHumanoid then
			deathHumanoid.Health = 0
		end
	end

	-- Stop the camera from moving
	CameraController.stop()

	-- Stop other systems
	PipeManager.stop()
	SpeedManager.stop()
	if ParallaxBackground then ParallaxBackground.stop() end
	ScoreUI.stop()
	ScoreUI.hide()

	-- Submit final score to server for persistence (saves if new high score)
	ScoreManager.submitFinalScore()

	-- Submit currency earned this run to server
	local baconEarned = CurrencyManager.getPendingEarned()
	local baconTotal = CurrencyManager.getDisplayBalance()
	CurrencyManager.submitEarnings()

	-- Show game over screen (personalBest is already tracked locally)
	GameOverUI.show(ScoreManager.getScore(), ScoreManager.getPersonalBest(), baconEarned, baconTotal)

	-- Wait before allowing restart
	task.wait(GameConfig.RESET_DELAY)

	-- If state changed while we were yielded (e.g. returnToLobby called), bail out
	if currentState ~= "gameOver" then return end

	-- Play Again handler (shared by Space key and button click)
	local function handlePlayAgain()
		-- Guard: only act if we're still in GAME_OVER state
		if currentState ~= "gameOver" then return end
		-- Block play-again while a manual respawn is in progress
		if isRespawning then return end

		Analytics.logCustomEvent(AnalyticsConfig.EVENTS.PLAY_AGAIN)

		-- Prevent re-triggering (disconnect Space key, etc.)
		disconnectAll()
		GameOverUI.hide()

		-- Clear game over death flag so CharacterAdded handler restarts normally
		isGameOverDeath = false

		-- Request a new character from the server.
		-- CharacterAdded handler will clean up and call startReady().
		fireRequestRespawn()
	end

	-- Wire up the UI button click
	GameOverUI.setOnPlayAgain(handlePlayAgain)

	-- Wire up keyboard/gamepad/touch input
	startInputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if currentState ~= "gameOver" then return end

		if not JumpInput.isJump(input) then return end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			if UserInputService:GetFocusedTextBox() then return end
		elseif input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if gameProcessed
				or LeaderboardUI.isMouseOver()
				or ReadyUI.isShopButtonMouseOver()
				or ReadyUI.isMissionsButtonMouseOver()
				or ReadyUI.isPrestigeButtonMouseOver() then
				return
			end
		end

		handlePlayAgain()
	end)
end

--[[
	Returns player to lobby/menu state.
	Restores default Roblox behavior for hub area.
]]
function GameController.returnToLobby()
	if currentState == "playing" then
		MissionManager.reportEvent("run_abandoned")
		if PRESTIGE_ENABLED then
			PrestigeManager.reportRunAbandoned()
		end
	end

	Analytics.logCustomEvent(AnalyticsConfig.EVENTS.RETURN_TO_LOBBY)
	disconnectAll()
	currentState = "menu"
	GameState.setState(GameConfig.STATES.MENU)
	
	-- Stop game modules (only if they were loaded)
	if PlayerController then PlayerController.stopUpdate() end
	if CameraController then CameraController.stop() end
	if PipeManager then PipeManager.stop() end
	if ParallaxBackground then ParallaxBackground.stop() end
	if EffectRegistry then EffectRegistry.stopAll() end
	if SpeedManager then SpeedManager.stop() end
	ScoreUI.stop()
	hideAllGameUI()

	-- Clear pipes and bacons
	if BaconCollectible then BaconCollectible.clear() end
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
	disconnectAll()
	currentState = "menu"
	GameState.setState(GameConfig.STATES.MENU)
	
	-- Stop game modules (only if loaded)
	if PlayerController then PlayerController.stopUpdate() end
	if CameraController then CameraController.stop() end
	if PipeManager then PipeManager.stop() end
	if ParallaxBackground then ParallaxBackground.stop() end
	if EffectRegistry then EffectRegistry.stopAll() end
	if SpeedManager then SpeedManager.stop() end
	ScoreUI.stop()

	-- Reset all systems (only if loaded)
	if PlayerController then PlayerController.reset() end
	if SpeedManager then SpeedManager.reset() end
	if BaconCollectible then BaconCollectible.clear() end
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
	LeaderboardUI.destroy()
	CurrencyUI.destroy()
	ShopUI.destroy()
	MissionsUI.destroy()
	PrestigeUI.destroy()
	StartButton.destroy()
	OptionsUI.destroy()
	DebugCameraUI.destroy()

	-- Destroy effects via registry, then other game modules
	if EffectRegistry then EffectRegistry.destroyAll() end
	if BaconCollectible then BaconCollectible.destroy() end
	if ParallaxBackground then ParallaxBackground.destroy() end
	if PlayerController then PlayerController.destroy() end
	if CameraController then CameraController.destroy() end

	if readyHoverConnection then
		readyHoverConnection:Disconnect()
		readyHoverConnection = nil
	end

	if respawnConnection then
		respawnConnection:Disconnect()
		respawnConnection = nil
	end

	if characterRemovingConnection then
		characterRemovingConnection:Disconnect()
		characterRemovingConnection = nil
	end

	if humanoidDiedConnection then
		humanoidDiedConnection:Disconnect()
		humanoidDiedConnection = nil
	end

	if debugProgressResetConnection then
		debugProgressResetConnection:Disconnect()
		debugProgressResetConnection = nil
	end

	if speedDebugLogToggleConnection then
		speedDebugLogToggleConnection:Disconnect()
		speedDebugLogToggleConnection = nil
	end
end

return GameController
