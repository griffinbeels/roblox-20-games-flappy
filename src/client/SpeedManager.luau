--[[
	SpeedManager.luau
	
	Handles progressive speed increase over time (like Jetpack Joyride).
	Tracks current speed multiplier and provides methods to get current speed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local SpeedManager = {}
SpeedManager.__index = SpeedManager

local speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
local gameStartTime = 0
local isRunning = false

--[[
	Starts the speed progression (call when game starts).
]]
function SpeedManager.start()
	speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
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
	
]]
function SpeedManager.update()
	if not isRunning then
		return
	end
	
	local timeElapsed = tick() - gameStartTime
	speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER + (timeElapsed * GameConfig.SPEED.INCREASE_RATE)
	
	-- Optional: Cap at max multiplier
	if GameConfig.SPEED.MAX_MULTIPLIER and speedMultiplier > GameConfig.SPEED.MAX_MULTIPLIER then
		speedMultiplier = GameConfig.SPEED.MAX_MULTIPLIER
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
	return PlayerConfig.BASE_FORWARD_SPEED * speedMultiplier
end

--[[
	Resets the speed to initial value.
]]
function SpeedManager.reset()
	speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
	gameStartTime = 0
	isRunning = false
end

return SpeedManager
