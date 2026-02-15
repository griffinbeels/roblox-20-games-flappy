--[[
	PipeManager.luau

	Creates, recycles, and manages pipe PAIRS with dynamic gap sizes.
	Each spawn creates a TOP pipe and BOTTOM pipe at the same X position.
	The player must fly through the gap between them.

	All pipe configuration and spawn logic lives in PipeConfig.luau.
	This module handles lifecycle: spawning, pooling, scoring, and recycling.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PipeConfig = require(ReplicatedStorage.Shared.PipeConfig)
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
local totalDistanceTraveled = 0
local previousGapY = nil

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

	-- Resolve all styles from PipeConfig.STYLES
	resolvedStyles = {}
	local styles = PipeConfig.STYLES
	if not styles or #styles == 0 then
		styles = {
			{ COLOR = Color3.fromRGB(0, 200, 0), MATERIAL = Enum.Material.SmoothPlastic },
		}
	end

	for i, styleDef in ipairs(styles) do
		local resolved = {
			color = styleDef.COLOR,
			material = styleDef.MATERIAL,
			modelTemplate = nil,
		}

		local assetId = styleDef.MODEL_ASSET_ID
		if assetId and assetId ~= "" then
			local templatesFolder = ReplicatedStorage:FindFirstChild("PipeTemplates")
			if templatesFolder then
				local template = templatesFolder:FindFirstChild(tostring(assetId))
				if template then
					resolved.modelTemplate = template
				else
					warn("[PipeManager] No template found in PipeTemplates for asset ID: " .. tostring(assetId))
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
	@return number - The spacing to use before the next pipe pair
]]
local function spawnPipePair(xPosition, speedMultiplier)
	-- Resolve speed
	local spd = speedMultiplier
	if not spd and SpeedManager then
		spd = SpeedManager.getCurrentMultiplier()
	end

	-- Make spawn decisions via PipeConfig
	local gapSize = PipeConfig.getGapSize(totalDistanceTraveled)
	local gapY = PipeConfig.getGapY(gapSize, previousGapY)
	local spacing = PipeConfig.getSpacing(spd)
	local styleIndex = PipeConfig.getStyleIndex(#resolvedStyles)

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
	})

	return spacing
end

--[[
	Pre-spawns pipe pairs ahead of the player for the ready state.
]]
function PipeManager.preSpawnPipes()
	if not PlayerController then return end

	local playerPos = PlayerController.getPosition()
	if not playerPos then return end

	local playerX = playerPos.X

	-- Randomize first pipe pair distance
	local firstPipeDistance = PipeConfig.FIRST_PIPE_MIN +
		math.random() * (PipeConfig.FIRST_PIPE_MAX - PipeConfig.FIRST_PIPE_MIN)

	nextSpawnX = playerX + firstPipeDistance

	-- Pre-spawn with speed-estimated spacing
	local baseSpeed = PlayerConfig.BASE_FORWARD_SPEED
	local increaseRate = GameConfig.SPEED.INCREASE_RATE
	local maxMultiplier = GameConfig.SPEED.MAX_MULTIPLIER

	for i = 1, PipeConfig.PRE_SPAWN_COUNT do
		local distFromStart = nextSpawnX - playerX
		local estimatedTime = distFromStart / baseSpeed
		local estimatedMultiplier = math.min(1 + increaseRate * estimatedTime, maxMultiplier)

		local spacing = spawnPipePair(nextSpawnX, estimatedMultiplier)
		nextSpawnX = nextSpawnX + spacing
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
		if not PlayerController then return end

		local playerPos = PlayerController.getPosition()
		if not playerPos then return end

		local playerX = playerPos.X
		totalDistanceTraveled = playerX

		-- Spawn new pipe pairs ahead of player
		local spawnThreshold = playerX + PipeConfig.SPAWN_AHEAD_DISTANCE
		while nextSpawnX < spawnThreshold do
			local spacing = spawnPipePair(nextSpawnX)
			nextSpawnX = nextSpawnX + spacing
		end

		-- Check scoring and recycle old pipes
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
			if pipeX < playerX - PipeConfig.DESPAWN_BEHIND_DISTANCE then
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
end

--[[
	Clears all active pipes and resets state.
]]
function PipeManager.clear()
	PipeManager.stop()

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
	resolvedStyles = {}
end

return PipeManager
