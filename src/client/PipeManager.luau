--[[
	PipeManager.luau

	Creates, recycles, and manages pipe PAIRS with dynamic gap sizes.
	Each spawn creates a TOP pipe and BOTTOM pipe at the same X position.
	The player must fly through the gap between them.

	All pipe configuration and spawn logic lives in PipeConfig.luau.
	This module handles lifecycle: spawning, pooling, scoring, and recycling.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PipeConfig = require(ReplicatedStorage.Shared.PipeConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)
local Pipe = require(script.Parent.Pipe)

local PipeManager = {}
PipeManager.__index = PipeManager

-- State
local activePipePairs = {} -- Each entry is {top, bottom, scored, xPosition, styleIndex}
local pipePools = {}       -- Keyed by "styleIndex_orientation", e.g. "1_top"
local updateConnection = nil
local nextSpawnX = 0
local SpeedManager = nil
local PlayerController = nil
local onPipePassedCallback = nil
local onPipeSpawnedCallback = nil
local totalDistanceTraveled = 0
local previousGapY = nil
local localPlayer = Players.LocalPlayer
local gapIndicatorGui = nil
local gapIndicatorLabel = nil

local GAP_INDICATOR_VERTICAL_PADDING_RATIO = 0.02
local GAP_INDICATOR_SIZE_RATIO = 0.06
local GAP_INDICATOR_PLAYER_X_OFFSET_RATIO = 0.045
local GAP_INDICATOR_MIN_SIZE = 24
local GAP_INDICATOR_MAX_SIZE = 64
local GAP_INDICATOR_MIN_X_OFFSET = 14
local GAP_INDICATOR_MIN_VERTICAL_PADDING = 8

--[[
	Resolved styles table — built at init time.
	Each entry mirrors the PipeConfig.STYLES entry but with a `modelTemplate`
	field pointing to the loaded Model (or nil for Part-based styles).
]]
local resolvedStyles = {}

--[[
	Returns the pool key for a given style index and orientation.
]]
local function poolKey(styleIndex, orientation)
	return styleIndex .. "_" .. orientation
end

local function getInternalSpeedMultiplierCap()
	local configCap = tonumber(GameConfig.SPEED.INTERNAL_MULTIPLIER_CAP)
		or tonumber(GameConfig.SPEED.MAX_MULTIPLIER)
	local initialMultiplier = tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1
	return math.max(initialMultiplier, configCap or initialMultiplier)
end

local function getSelectedSpeedRampMultiplier()
	local runtimeRamp = nil
	if RuntimeTuning.getActiveSpeedRampMultiplier then
		runtimeRamp = tonumber(RuntimeTuning.getActiveSpeedRampMultiplier())
	else
		runtimeRamp = tonumber(RuntimeTuning.getActiveSpeedCapMultiplier())
	end

	local defaultRamp = tonumber(GameConfig.SPEED.RAMP_RATE_MULTIPLIER_DEFAULT)
		or tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER)
		or 1.0
	return math.max(0, runtimeRamp or defaultRamp)
end

local function hideGapIndicator()
	if gapIndicatorLabel then
		gapIndicatorLabel.Visible = false
	end
end

local function destroyGapIndicator()
	if gapIndicatorGui then
		gapIndicatorGui:Destroy()
	end
	gapIndicatorGui = nil
	gapIndicatorLabel = nil
end

local function ensureGapIndicator()
	if gapIndicatorGui and gapIndicatorLabel and gapIndicatorGui.Parent then
		return
	end

	if not localPlayer then
		return
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5)
	if not playerGui then
		return
	end

	destroyGapIndicator()

	gapIndicatorGui = Instance.new("ScreenGui")
	gapIndicatorGui.Name = "GapIndicatorUI"
	gapIndicatorGui.ResetOnSpawn = false
	gapIndicatorGui.IgnoreGuiInset = true
	gapIndicatorGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gapIndicatorGui.Parent = playerGui

	gapIndicatorLabel = Instance.new("TextLabel")
	gapIndicatorLabel.Name = "GapIndicatorArrow"
	gapIndicatorLabel.Size = UDim2.fromOffset(GAP_INDICATOR_MIN_SIZE, GAP_INDICATOR_MIN_SIZE)
	gapIndicatorLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	gapIndicatorLabel.BackgroundTransparency = 1
	gapIndicatorLabel.Text = ">"
	gapIndicatorLabel.TextColor3 = Color3.fromRGB(255, 0, 0)
	gapIndicatorLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	gapIndicatorLabel.TextStrokeTransparency = 0.35
	gapIndicatorLabel.TextScaled = true
	gapIndicatorLabel.Font = Enum.Font.GothamBlack
	gapIndicatorLabel.Visible = false
	gapIndicatorLabel.ZIndex = 50
	gapIndicatorLabel.Parent = gapIndicatorGui
end

local function getNextUpcomingPipePair(playerX)
	for _, pair in ipairs(activePipePairs) do
		if pair.xPosition >= playerX then
			return pair
		end
	end
	return nil
end

local function updateGapIndicator(playerPos)
	ensureGapIndicator()
	if not gapIndicatorLabel then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		hideGapIndicator()
		return
	end

	local viewportSize = camera.ViewportSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		hideGapIndicator()
		return
	end

	if not playerPos then
		hideGapIndicator()
		return
	end

	local playerX = playerPos.X

	local nextPair = getNextUpcomingPipePair(playerX)
	if not nextPair or nextPair.gapY == nil then
		hideGapIndicator()
		return
	end

	local pipeHalfWidth = PipeConfig.WIDTH / 2
	local leftEdgeViewport = camera:WorldToViewportPoint(Vector3.new(nextPair.xPosition - pipeHalfWidth, nextPair.gapY, 0))
	local rightEdgeViewport = camera:WorldToViewportPoint(Vector3.new(nextPair.xPosition + pipeHalfWidth, nextPair.gapY, 0))

	-- Only show the indicator when the entire next pipe pair is still off the right side.
	if leftEdgeViewport.Z <= 0 or rightEdgeViewport.Z <= 0 or leftEdgeViewport.X <= viewportSize.X then
		hideGapIndicator()
		return
	end

	local gapCenterViewport = camera:WorldToViewportPoint(Vector3.new(camera.CFrame.Position.X, nextPair.gapY, 0))
	if gapCenterViewport.Z <= 0 then
		hideGapIndicator()
		return
	end

	local indicatorSize = math.clamp(
		math.floor(math.min(viewportSize.X, viewportSize.Y) * GAP_INDICATOR_SIZE_RATIO),
		GAP_INDICATOR_MIN_SIZE,
		GAP_INDICATOR_MAX_SIZE
	)
	local xOffset = math.max(GAP_INDICATOR_MIN_X_OFFSET, viewportSize.X * GAP_INDICATOR_PLAYER_X_OFFSET_RATIO)
	local verticalPadding = math.max(GAP_INDICATOR_MIN_VERTICAL_PADDING, viewportSize.Y * GAP_INDICATOR_VERTICAL_PADDING_RATIO)
	gapIndicatorLabel.Size = UDim2.fromOffset(indicatorSize, indicatorSize)

	local playerViewport = camera:WorldToViewportPoint(Vector3.new(playerPos.X, playerPos.Y, 0))
	if playerViewport.Z <= 0 then
		hideGapIndicator()
		return
	end

	local clampedX = math.clamp(
		playerViewport.X + xOffset,
		verticalPadding + (indicatorSize / 2),
		viewportSize.X - verticalPadding - (indicatorSize / 2)
	)
	local clampedY = math.clamp(
		gapCenterViewport.Y,
		verticalPadding + (indicatorSize / 2),
		viewportSize.Y - verticalPadding - (indicatorSize / 2)
	)
	gapIndicatorLabel.Position = UDim2.fromOffset(clampedX, clampedY)
	gapIndicatorLabel.Visible = true
end

--[[
	Initializes the PipeManager.
	@param playerCtrl PlayerController - The PlayerController instance
	@param speedMgr SpeedManager - The SpeedManager instance (optional)
]]
function PipeManager.init(playerCtrl, speedMgr)
	PlayerController = playerCtrl
	SpeedManager = speedMgr
	nextSpawnX = 0
	totalDistanceTraveled = 0
	previousGapY = nil
	ensureGapIndicator()
	hideGapIndicator()

	PipeManager.resolveStyles()
end

--[[
	Resolves all styles from PipeConfig.STYLES into the internal resolvedStyles table.
	Called by init() and can be called externally after PipeConfig.STYLES is swapped
	(e.g. by the shop) to hot-reload pipe visuals.
]]
function PipeManager.resolveStyles()
	resolvedStyles = {}
	local styles = PipeConfig.STYLES
	if not styles or #styles == 0 then
		styles = {
			{ type = "part" },
		}
	end

	for i, styleDef in ipairs(styles) do
		local styleType = styleDef.type or "part"

		-- Merge defaults with style overrides
		local defaults = PipeConfig.STYLE_DEFAULTS[styleType] or {}
		local resolved = { type = styleType }
		for key, value in pairs(defaults) do
			resolved[key] = value
		end
		for key, value in pairs(styleDef) do
			resolved[key] = value
		end

		-- Model type: load template from ReplicatedStorage.PipeTemplates
		if styleType == "model" and resolved.assetId then
			local templatesFolder = ReplicatedStorage:FindFirstChild("PipeTemplates")
			if templatesFolder then
				local template = templatesFolder:FindFirstChild(tostring(resolved.assetId))
				if template then
					resolved.modelTemplate = template
				else
					warn("[PipeManager] No template found in PipeTemplates for asset ID: " .. tostring(resolved.assetId))
				end
			else
				warn("[PipeManager] ReplicatedStorage.PipeTemplates folder not found")
			end
		end

		resolvedStyles[i] = resolved
	end
end

--[[
	Sets the SpeedManager reference.
	@param speedMgr SpeedManager - The SpeedManager instance
]]
function PipeManager.setSpeedManager(speedMgr)
	SpeedManager = speedMgr
end

--[[
	Sets the callback for when a pipe pair is passed.
	@param callback function - Callback function(pipePair)
]]
function PipeManager.setOnPipePassed(callback)
	onPipePassedCallback = callback
end

--[[
	Sets the callback for when a pipe pair is spawned.
	@param callback function - Callback function(pipePair)
]]
function PipeManager.setOnPipeSpawned(callback)
	onPipeSpawnedCallback = callback
end

--[[
	Gets or creates a pipe from the pool for a specific style.
	@param styleIndex number - Index into resolvedStyles
	@param orientation string - "top" or "bottom"
	@param xPosition number - X position for the pipe
	@param height number - Height of the pipe
	@return Pipe - Pipe instance
]]
local function getPipeFromPool(styleIndex, orientation, xPosition, height)
	local key = poolKey(styleIndex, orientation)
	local pool = pipePools[key]

	-- Try to reuse from pool
	if pool and #pool > 0 then
		local pipe = table.remove(pool)
		pipe:setPositionAndHeight(xPosition, height)
		pipe:resetScored()
		return pipe
	end

	-- Create new pipe with the resolved style
	local style = resolvedStyles[styleIndex]
	return Pipe.new(orientation, xPosition, height, style)
end

--[[
	Spawns a pipe pair (top + bottom) at the specified X position.
	Uses PipeConfig functions for all spawn decisions.
	@param xPosition number - X position to spawn at
	@param speedMultiplier number|nil - Speed override for spacing calculation
	@param speedCapMultiplier number|nil - Active speed cap (for cap-aware spacing tuning)
	@param forwardSpeed number|nil - Actual/estimated forward speed for gap-variance tuning
	@return number - The spacing to use before the next pipe pair
]]
local function spawnPipePair(xPosition, speedMultiplier, speedCapMultiplier, forwardSpeed)
	-- Resolve speed
	local spd = speedMultiplier
	if not spd and SpeedManager then
		spd = SpeedManager.getCurrentMultiplier()
	end
	local spdCap = tonumber(speedCapMultiplier)
	if not spdCap and SpeedManager and SpeedManager.getCurrentTargetMultiplierCap then
		spdCap = tonumber(SpeedManager.getCurrentTargetMultiplierCap())
	end
	spdCap = spdCap or getInternalSpeedMultiplierCap()
	local fwdSpd = tonumber(forwardSpeed)
	if not fwdSpd and SpeedManager and SpeedManager.getCurrentSpeed then
		fwdSpd = tonumber(SpeedManager.getCurrentSpeed())
	end
	if not fwdSpd then
		local baseForwardSpeed = tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0
		local safeMultiplier = tonumber(spd) or (tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1)
		fwdSpd = baseForwardSpeed * safeMultiplier
	end

	-- Spacing should scale with actual movement speed, not only the legacy
	-- multiplier. This keeps high-speed runs from becoming unfairly dense when
	-- extra speed pressure is applied outside the multiplier cap.
	local baseForwardSpeed = math.max(0.0001, tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0.0001)
	local spacingSpeedMultiplier = tonumber(spd) or (tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1)
	if fwdSpd then
		spacingSpeedMultiplier = math.max(spacingSpeedMultiplier, fwdSpd / baseForwardSpeed)
	end
	local spacingCapMultiplier = math.max(spdCap, spacingSpeedMultiplier)

	-- Make spawn decisions via PipeConfig
	local gapSize = PipeConfig.getGapSize(totalDistanceTraveled)
	local gapY, gapYDebug = PipeConfig.getGapY(gapSize, previousGapY, {
		forwardSpeed = fwdSpd,
		speedMultiplier = spd,
		speedCapMultiplier = spdCap,
	})
	local spacing, spacingDebug = PipeConfig.getSpacing(spacingSpeedMultiplier, {
		speedCapMultiplier = spacingCapMultiplier,
		forwardSpeed = fwdSpd,
	})
	local styleIndex = PipeConfig.getStyleIndex(#resolvedStyles)

	if SpeedManager and SpeedManager.recordDebugPipeSpacingSample then
		SpeedManager.recordDebugPipeSpacingSample(spacing, {
			spacingSpeedMultiplier = spacingSpeedMultiplier,
			speedCapMultiplier = spacingCapMultiplier,
			forwardSpeed = fwdSpd,
			gapXMin = spacingDebug and spacingDebug.minSpacing,
			gapXMax = spacingDebug and spacingDebug.maxSpacing,
			gapXEffectiveSpeed = spacingDebug and spacingDebug.effectiveSpeed,
			gapY = gapY,
			gapYMin = gapYDebug and gapYDebug.minY,
			gapYMax = gapYDebug and gapYDebug.maxY,
			gapYMaxDelta = gapYDebug and gapYDebug.maxDelta,
		})
	end

	previousGapY = gapY

	-- Calculate pipe heights
	local topHeight, bottomHeight = PipeConfig.getPipeHeights(gapY, gapSize)

	-- Create the pipe pair
	local topPipe = getPipeFromPool(styleIndex, "top", xPosition, topHeight)
	local bottomPipe = getPipeFromPool(styleIndex, "bottom", xPosition, bottomHeight)

	table.insert(activePipePairs, {
		top = topPipe,
		bottom = bottomPipe,
		scored = false,
		xPosition = xPosition,
		styleIndex = styleIndex,
		gapY = gapY,
		gapSize = gapSize,
	})

	if onPipeSpawnedCallback then
		onPipeSpawnedCallback(activePipePairs[#activePipePairs])
	end

	return spacing
end

--[[
	Pre-spawns pipe pairs ahead of the player for the ready state.
]]
function PipeManager.preSpawnPipes()
	if not PipeConfig.ENABLED then return end
	if not PlayerController then return end
	local playerPos = PlayerController.getPosition()
	if not playerPos then return end

	local playerX = playerPos.X

	-- Randomize first pipe pair distance
	local firstPipeDistance = PipeConfig.FIRST_PIPE_MIN +
		math.random() * (PipeConfig.FIRST_PIPE_MAX - PipeConfig.FIRST_PIPE_MIN)

	nextSpawnX = playerX + firstPipeDistance

	-- Pre-spawn using the same predicted run-speed timeline used at runtime
	-- (unified progression curve when enabled) so READY pipes match gameplay.
	local selectedRampMultiplier = getSelectedSpeedRampMultiplier()
	local predictedTargetMultiplierCap = getInternalSpeedMultiplierCap()
	if SpeedManager and SpeedManager.getTargetMultiplierCapForRampSetting then
		predictedTargetMultiplierCap = tonumber(SpeedManager.getTargetMultiplierCapForRampSetting(selectedRampMultiplier))
			or predictedTargetMultiplierCap
	end
	local initialMultiplier = tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1

	local function getPredictedRunSpeed(elapsedSeconds)
		if SpeedManager and SpeedManager.getPredictedSpeedAtElapsed then
			local predictedSpeed = SpeedManager.getPredictedSpeedAtElapsed(elapsedSeconds, selectedRampMultiplier, predictedTargetMultiplierCap)
			if tonumber(predictedSpeed) then
				return math.max(0.001, tonumber(predictedSpeed))
			end
		end

		local baseSpeed = tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0
		local increaseRate = (tonumber(GameConfig.SPEED.INCREASE_RATE) or 0) * selectedRampMultiplier
		local predictedMultiplier = math.min(initialMultiplier + (math.max(0, tonumber(elapsedSeconds) or 0) * increaseRate), predictedTargetMultiplierCap)
		return math.max(0.001, baseSpeed * predictedMultiplier)
	end

	local function getPredictedRunMultiplier(elapsedSeconds)
		if SpeedManager and SpeedManager.getPredictedMultiplierAtElapsed then
			local predictedMultiplier = SpeedManager.getPredictedMultiplierAtElapsed(elapsedSeconds, selectedRampMultiplier, predictedTargetMultiplierCap)
			if tonumber(predictedMultiplier) then
				return tonumber(predictedMultiplier)
			end
		end

		local increaseRate = (tonumber(GameConfig.SPEED.INCREASE_RATE) or 0) * selectedRampMultiplier
		return math.min(initialMultiplier + (math.max(0, tonumber(elapsedSeconds) or 0) * increaseRate), predictedTargetMultiplierCap)
	end

	local function estimateTravelTime(distanceStuds, startElapsedSeconds)
		local distance = math.max(0, tonumber(distanceStuds) or 0)
		if distance <= 0 then
			return 0
		end

		local startElapsed = math.max(0, tonumber(startElapsedSeconds) or 0)
		local startSpeed = getPredictedRunSpeed(startElapsed)
		local roughDt = distance / math.max(0.001, startSpeed)
		local midSpeed = getPredictedRunSpeed(startElapsed + (roughDt * 0.5))

		return distance / math.max(0.001, midSpeed)
	end

	local simulatedElapsed = estimateTravelTime(firstPipeDistance, 0)

	for i = 1, PipeConfig.PRE_SPAWN_COUNT do
		local estimatedMultiplier = getPredictedRunMultiplier(simulatedElapsed)
		local estimatedForwardSpeed = getPredictedRunSpeed(simulatedElapsed)
		local spacing = spawnPipePair(nextSpawnX, estimatedMultiplier, predictedTargetMultiplierCap, estimatedForwardSpeed)
		nextSpawnX = nextSpawnX + spacing
		simulatedElapsed = simulatedElapsed + estimateTravelTime(spacing, simulatedElapsed)
	end
end

--[[
	Starts the pipe spawning and update system.
]]
function PipeManager.start()
	if updateConnection then
		updateConnection:Disconnect()
	end

	updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not PipeConfig.ENABLED then
			hideGapIndicator()
			return
		end
		if not PlayerController then
			hideGapIndicator()
			return
		end

		local playerPos = PlayerController.getPosition()
		if not playerPos then
			hideGapIndicator()
			return
		end

		local playerX = playerPos.X
		totalDistanceTraveled = playerX

		-- Spawn new pipe pairs ahead of player (distance adapts to viewport)
		local spawnAhead = PipeConfig.getSpawnAheadDistance()
		local spawnThreshold = playerX + spawnAhead
		while nextSpawnX < spawnThreshold do
			local spacing = spawnPipePair(nextSpawnX)
			nextSpawnX = nextSpawnX + spacing
		end

		-- Check scoring and recycle old pipes
		local despawnBehind = PipeConfig.getDespawnBehindDistance()
		for i = #activePipePairs, 1, -1 do
			local pair = activePipePairs[i]
			local pipeX = pair.xPosition

			-- Score when pipe passes player
			if not pair.scored and pipeX < playerX - 2 then
				pair.scored = true
				if onPipePassedCallback then
					onPipePassedCallback(pair)
				end
			end

			-- Recycle pipes far behind player
			if pipeX < playerX - despawnBehind then
				local si = pair.styleIndex

				local topKey = poolKey(si, "top")
				local bottomKey = poolKey(si, "bottom")
				if not pipePools[topKey] then pipePools[topKey] = {} end
				if not pipePools[bottomKey] then pipePools[bottomKey] = {} end

				table.insert(pipePools[topKey], pair.top)
				table.insert(pipePools[bottomKey], pair.bottom)
				table.remove(activePipePairs, i)

				-- Limit pool size to prevent memory bloat
				if #pipePools[topKey] > PipeConfig.MAX_POOL_SIZE then
					local oldPipe = table.remove(pipePools[topKey], 1)
					oldPipe:destroy()
				end
				if #pipePools[bottomKey] > PipeConfig.MAX_POOL_SIZE then
					local oldPipe = table.remove(pipePools[bottomKey], 1)
					oldPipe:destroy()
				end
			end
		end

		updateGapIndicator(playerPos)
	end)
end

--[[
	Stops the pipe system.
]]
function PipeManager.stop()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	hideGapIndicator()
end

--[[
	Clears all active pipes and resets state.
]]
function PipeManager.clear()
	PipeManager.stop()
	hideGapIndicator()

	if SpeedManager and SpeedManager.clearDebugPipeSpacingSamples then
		SpeedManager.clearDebugPipeSpacingSamples()
	end

	for _, pair in ipairs(activePipePairs) do
		if pair.top then pair.top:destroy() end
		if pair.bottom then pair.bottom:destroy() end
	end
	activePipePairs = {}

	for _, pool in pairs(pipePools) do
		for _, pipe in ipairs(pool) do
			pipe:destroy()
		end
	end
	pipePools = {}

	nextSpawnX = 0
	totalDistanceTraveled = 0
	previousGapY = nil
end

--[[
	Resets the pipe system for a new game.
]]
function PipeManager.reset()
	PipeManager.clear()
end

--[[
	Gets all active pipes (for collision detection).
	@return table - Array of active pipes
]]
function PipeManager.getActivePipes()
	local allPipes = {}
	for _, pair in ipairs(activePipePairs) do
		if pair.top then table.insert(allPipes, pair.top) end
		if pair.bottom then table.insert(allPipes, pair.bottom) end
	end
	return allPipes
end

--[[
	Cleans up the PipeManager.
]]
function PipeManager.destroy()
	PipeManager.clear()
	destroyGapIndicator()
	resolvedStyles = {}
end

return PipeManager
