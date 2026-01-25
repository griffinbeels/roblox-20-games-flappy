--[[
	init.server.luau
	
	Main server entry point for Flappy Bird game.
]]

local success, err = pcall(function()
	local LeaderboardService = require(script.LeaderboardService)
	
	-- Initialize the leaderboard service
	LeaderboardService.init()
end)

if not success then
	warn("Failed to initialize LeaderboardService:", err)
	-- Game can still run without leaderboard in Studio
end