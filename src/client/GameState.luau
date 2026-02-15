--[[
	GameState.luau
	
	Simple state management for game states.
	Minimal implementation - just state storage with getter/setter.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local GameState = {}
GameState.__index = GameState

local currentState = GameConfig.STATES.MENU

--[[
	Gets the current game state.
	@return string - Current state ("menu", "playing", "gameOver")
]]
function GameState.getState()
	return currentState
end

--[[
	Sets the current game state.
	@param newState string - New state to set
]]
function GameState.setState(newState)
	currentState = newState
end

--[[
	Resets the game state to menu.
]]
function GameState.reset()
	currentState = GameConfig.STATES.MENU
end

return GameState
