--[[
	PipeManager.luau
	
	Creates, recycles, and manages pipe PAIRS with dynamic gap sizes.
	Each spawn creates a TOP pipe and BOTTOM pipe at the same X position.
	The player must fly through the gap between them.
	
	SPAWNING LOGIC:
	- Pre-spawns pipe pairs at fixed X positions ahead of the player
	- Each pair has a randomized gap position (Y) and gap size
	- Gap size can decrease over time for difficulty progression
	- Pipes are recycled when they go off-screen behind the player
	
	CONFIGURATION:
	- Gap size: minimum gap, maximum gap, and how it changes with distance
	- Gap position: randomized within playable area
	- Spacing between pipe pairs: randomized within range
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Pipe = require(script.Parent.Pipe)
local PipeType = require(ReplicatedStorage.Shared.PipeType)

local PipeManager = {}
PipeManager.__index = PipeManager

-- State
local activePipePairs = {} -- Each entry is {topPipe, bottomPipe, scored}
local pipePool = {top = {}, bottom = {}}
local updateConnection = nil
local nextSpawnX = 0
local currentPipeType = nil
local SpeedManager = nil
local PlayerController = nil
local onPipePassedCallback = nil
local totalDistanceTraveled = 0

-- Configuration (uses Constants for easy adjustment, can be overridden at runtime)
local config = {
	-- PIPE VISIBILITY SETTINGS
	-- Adjust these to ensure pipes spawn/despawn off-screen
	-- The camera shows roughly 60-80 studs of horizontal view
	
	-- How many pipe pairs to pre-spawn ahead of player
	-- Higher = more pipes in the world at once, smoother experience
	preSpawnCount = 6,
	
	-- Distance ahead of player to spawn new pipes (must be off-screen right)
	-- Should be larger than half the camera view width
	spawnAheadDistance = 120,
	
	-- Distance behind player to despawn pipes (must be off-screen left)
	-- Should be larger than half the camera view width
	despawnBehindDistance = 80,
	
	-- Spacing between pipe pairs (studs) - from Constants
	minSpacing = Constants.PIPE.SPACING_MIN,
	maxSpacing = Constants.PIPE.SPACING_MAX,
	
	-- First pipe pair distance from player start - from Constants
	minFirstPipeDistance = Constants.PIPE.FIRST_PIPE_MIN,
	maxFirstPipeDistance = Constants.PIPE.FIRST_PIPE_MAX,
	
	-- Gap configuration (the space player flies through) - from Constants
	minGapSize = Constants.PIPE.GAP_MIN,
	maxGapSize = Constants.PIPE.GAP_MAX,
	
	-- Gap position bounds (Y position where the gap center can be) - from Constants
	minGapY = Constants.PIPE.GAP_Y_MIN,
	maxGapY = Constants.PIPE.GAP_Y_MAX,
	
	-- Difficulty progression: gap shrinks as player travels - from Constants
	gapShrinkRate = Constants.PIPE.GAP_SHRINK_RATE,
}

-- Playable area height (from Constants)
local PLAY_AREA_HEIGHT = Constants.BOUNDARIES.MAX_Y - Constants.BOUNDARIES.MIN_Y -- 30 studs

--[[
	Initializes the PipeManager.
	@param playerCtrl PlayerController - The PlayerController instance
	@param speedMgr SpeedManager - The SpeedManager instance (optional)
]]
function PipeManager.init(playerCtrl, speedMgr)
	PlayerController = playerCtrl
	SpeedManager = speedMgr
	currentPipeType = PipeType.getDefault()
	nextSpawnX = 0
	totalDistanceTraveled = 0
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
	Updates configuration at runtime.
	@param newConfig table - Partial config table to merge
]]
function PipeManager.setConfig(newConfig)
	for key, value in pairs(newConfig) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
end

--[[
	Gets current configuration.
	@return table - Current config
]]
function PipeManager.getConfig()
	return config
end

--[[
	Calculates the current gap size based on distance traveled.
	Gap starts large and shrinks over time for increasing difficulty.
	@return number - Current gap size in studs
]]
local function getCurrentGapSize()
	local baseGap = config.maxGapSize
	local shrinkAmount = totalDistanceTraveled * config.gapShrinkRate
	local currentGap = baseGap - shrinkAmount
	
	-- Clamp to minimum gap size
	return math.max(config.minGapSize, currentGap)
end

--[[
	Generates a random gap Y position within bounds.
	@param gapSize number - Size of the gap
	@return number - Y position for the center of the gap
]]
local function getRandomGapY(gapSize)
	-- Ensure the gap fits within the playable area
	local halfGap = gapSize / 2
	local minY = Constants.BOUNDARIES.MIN_Y + halfGap + 2 -- Leave room for bottom pipe
	local maxY = Constants.BOUNDARIES.MAX_Y - halfGap - 2 -- Leave room for top pipe
	
	-- Also respect configured bounds
	minY = math.max(minY, config.minGapY)
	maxY = math.min(maxY, config.maxGapY)
	
	-- Random position within valid range
	return minY + math.random() * (maxY - minY)
end

--[[
	Calculates a randomized spacing between pipe pairs.
	@return number - Spacing in studs
]]
local function getRandomSpacing()
	local baseSpacing = config.minSpacing + math.random() * (config.maxSpacing - config.minSpacing)
	
	-- Slightly increase spacing at higher speeds for fairness
	if SpeedManager then
		local speedMultiplier = SpeedManager.getCurrentMultiplier()
		baseSpacing = baseSpacing * (1 + (speedMultiplier - 1) * 0.2)
	end
	
	return baseSpacing
end

--[[
	Gets or creates a pipe from the pool.
	@param orientation string - "top" or "bottom"
	@param xPosition number - X position for the pipe
	@param height number - Height of the pipe
	@return Pipe - Pipe instance
]]
local function getPipeFromPool(orientation, xPosition, height)
	local pool = pipePool[orientation]
	
	-- Try to reuse from pool
	if #pool > 0 then
		local pipe = table.remove(pool)
		pipe:setPositionAndHeight(xPosition, height)
		pipe:resetScored()
		return pipe
	end
	
	-- Create new pipe
	return Pipe.new(currentPipeType, orientation, xPosition, height)
end

--[[
	Spawns a pipe pair (top + bottom) at the specified X position.
	@param xPosition number - X position to spawn at
]]
local function spawnPipePair(xPosition)
	local gapSize = getCurrentGapSize()
	local gapY = getRandomGapY(gapSize)
	
	-- Calculate pipe heights based on gap position
	-- Top pipe: from MAX_Y down to the top of the gap
	local topPipeHeight = Constants.BOUNDARIES.MAX_Y - (gapY + gapSize / 2)
	
	-- Bottom pipe: from MIN_Y up to the bottom of the gap
	local bottomPipeHeight = (gapY - gapSize / 2) - Constants.BOUNDARIES.MIN_Y
	
	-- Ensure minimum heights (at least 1 stud)
	topPipeHeight = math.max(1, topPipeHeight)
	bottomPipeHeight = math.max(1, bottomPipeHeight)
	
	-- Create the pipe pair
	local topPipe = getPipeFromPool("top", xPosition, topPipeHeight)
	local bottomPipe = getPipeFromPool("bottom", xPosition, bottomPipeHeight)
	
	-- Store as a pair (for scoring - only score once per pair)
	table.insert(activePipePairs, {
		top = topPipe,
		bottom = bottomPipe,
		scored = false,
		xPosition = xPosition,
	})
end

--[[
	Pre-spawns pipe pairs ahead of the player for the ready state.
	Creates multiple pipe pairs at randomized intervals.
]]
function PipeManager.preSpawnPipes()
	if not PlayerController then
		return
	end
	
	local playerPos = PlayerController.getPosition()
	if not playerPos then
		return
	end
	
	local playerX = playerPos.X
	
	-- Randomize first pipe pair distance
	local firstPipeDistance = config.minFirstPipeDistance + 
		math.random() * (config.maxFirstPipeDistance - config.minFirstPipeDistance)
	
	-- Set next spawn X to be ahead of the player
	nextSpawnX = playerX + firstPipeDistance
	
	-- Pre-spawn multiple pipe pairs with randomized spacing
	for i = 1, config.preSpawnCount do
		spawnPipePair(nextSpawnX)
		nextSpawnX = nextSpawnX + getRandomSpacing()
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
		if not PlayerController then
			return
		end
		
		local playerPos = PlayerController.getPosition()
		if not playerPos then
			return
		end
		
		local playerX = playerPos.X
		
		-- Track distance for difficulty progression
		totalDistanceTraveled = playerX
		
		-- Spawn new pipe pairs when player approaches the spawn threshold
		local spawnThreshold = playerX + config.spawnAheadDistance
		while nextSpawnX < spawnThreshold do
			spawnPipePair(nextSpawnX)
			nextSpawnX = nextSpawnX + getRandomSpacing()
		end
		
		-- Update active pipe pairs - check for scoring and despawning
		for i = #activePipePairs, 1, -1 do
			local pair = activePipePairs[i]
			local pipeX = pair.xPosition
			
			-- Check if pipe pair passed player (for scoring)
			-- Score when the pipe's X is behind the player's X
			if not pair.scored and pipeX < playerX - 2 then
				pair.scored = true
				if onPipePassedCallback then
					onPipePassedCallback(pair)
				end
			end
			
			-- Recycle pipe pair if it's far behind the player
			if pipeX < playerX - config.despawnBehindDistance then
				-- Return pipes to pool
				table.insert(pipePool.top, pair.top)
				table.insert(pipePool.bottom, pair.bottom)
				table.remove(activePipePairs, i)
				
				-- Limit pool size to prevent memory bloat
				if #pipePool.top > 6 then
					local oldPipe = table.remove(pipePool.top, 1)
					oldPipe:destroy()
				end
				if #pipePool.bottom > 6 then
					local oldPipe = table.remove(pipePool.bottom, 1)
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
	Clears all active pipes.
]]
function PipeManager.clear()
	PipeManager.stop()
	
	-- Destroy all active pipe pairs
	for _, pair in ipairs(activePipePairs) do
		if pair.top then pair.top:destroy() end
		if pair.bottom then pair.bottom:destroy() end
	end
	activePipePairs = {}
	
	-- Destroy all pooled pipes
	for _, pipe in ipairs(pipePool.top) do
		pipe:destroy()
	end
	for _, pipe in ipairs(pipePool.bottom) do
		pipe:destroy()
	end
	pipePool = {top = {}, bottom = {}}
	
	-- Reset state
	nextSpawnX = 0
	totalDistanceTraveled = 0
	
	-- Refresh pipe type
	currentPipeType = PipeType.getDefault()
end

--[[
	Resets the pipe system for a new game.
]]
function PipeManager.reset()
	PipeManager.clear()
end

--[[
	Gets all active pipes (for collision detection).
	Returns a flat list of all pipe parts.
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
	Sets the current pipe type.
	@param pipeType PipeType - The pipe type to use
]]
function PipeManager.setPipeType(pipeType)
	currentPipeType = pipeType
end

--[[
	Cleans up the PipeManager.
]]
function PipeManager.destroy()
	PipeManager.clear()
end

return PipeManager
