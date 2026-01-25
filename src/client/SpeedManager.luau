--[[
	SpeedManager.luau
	
	Handles progressive speed increase over time (like Jetpack Joyride).
	Tracks current speed multiplier and provides methods to get current speed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local SpeedManager = {}
SpeedManager.__index = SpeedManager

local speedMultiplier = Constants.SPEED.INITIAL_MULTIPLIER
local gameStartTime = 0
local isRunning = false

--[[
	Starts the speed progression (call when game starts).
]]
function SpeedManager.start()
	speedMultiplier = Constants.SPEED.INITIAL_MULTIPLIER
	gameStartTime = tick()
	isRunning = true
end

--[[
	Stops the speed progression (call when game ends).
]]
function SpeedManager.stop()
	isRunning = false
end

--[[
	Updates the speed multiplier based on elapsed time.
	Should be called every frame during gameplay.
	@param deltaTime number - Time since last frame
]]
function SpeedManager.update(deltaTime)
	if not isRunning then
		return
	end
	
	local timeElapsed = tick() - gameStartTime
	speedMultiplier = Constants.SPEED.INITIAL_MULTIPLIER + (timeElapsed * Constants.SPEED.INCREASE_RATE)
	
	-- Optional: Cap at max multiplier
	if Constants.SPEED.MAX_MULTIPLIER and speedMultiplier > Constants.SPEED.MAX_MULTIPLIER then
		speedMultiplier = Constants.SPEED.MAX_MULTIPLIER
	end
end

--[[
	Gets the current speed multiplier.
	@return number - Current speed multiplier
]]
function SpeedManager.getCurrentMultiplier()
	return speedMultiplier
end

--[[
	Gets the current forward speed (base speed * multiplier).
	@return number - Current forward speed in studs per second
]]
function SpeedManager.getCurrentSpeed()
	return Constants.PLAYER.BASE_FORWARD_SPEED * speedMultiplier
end

--[[
	Resets the speed to initial value.
]]
function SpeedManager.reset()
	speedMultiplier = Constants.SPEED.INITIAL_MULTIPLIER
	gameStartTime = 0
	isRunning = false
end

return SpeedManager
