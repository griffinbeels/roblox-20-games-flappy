--[[
	init.client.luau
	
	Main client entry point for Flappy Bird game.
]]

local GameController = require(script.GameController)

-- Initialize and start the game
GameController.init()
GameController.setupStartInput()