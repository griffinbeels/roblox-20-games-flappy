--[[
	init.server.luau

	Main server entry point for Flappy Bird game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Disable auto-respawn so the client controls when characters spawn.
-- This lets the game over screen stay visible until the player chooses to restart.
Players.CharacterAutoLoads = false
Players.RespawnTime = 0

-- Ensure Remotes folder exists
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
end

-- RequestRespawn: client fires this when it needs a new character
-- (Play Again from game over, or after a manual reset)
-- Reuse existing remote if one was saved in the place file to avoid duplicates
-- (FindFirstChild would give the client the stale one while the server listens on the new one)
local requestRespawn = remotes:FindFirstChild("RequestRespawn")
if not requestRespawn then
	requestRespawn = Instance.new("RemoteEvent")
	requestRespawn.Name = "RequestRespawn"
	requestRespawn.Parent = remotes
end

local lastRespawnTime = {} -- per-player cooldown to prevent spam

requestRespawn.OnServerEvent:Connect(function(player)
	local now = tick()
	if lastRespawnTime[player] and (now - lastRespawnTime[player]) < 0.5 then
		return -- cooldown
	end
	lastRespawnTime[player] = now
	player:LoadCharacter()
end)

-- Manually load character on join (since CharacterAutoLoads = false)
Players.PlayerAdded:Connect(function(player)
	player:LoadCharacter()
end)

-- Clean up cooldown tracking on leave
Players.PlayerRemoving:Connect(function(player)
	lastRespawnTime[player] = nil
end)

-- Handle players already in the game (Studio fast-start)
for _, player in ipairs(Players:GetPlayers()) do
	if not player.Character then
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

local success, err = pcall(function()
	local LeaderboardService = require(script.LeaderboardService)

	-- Initialize the leaderboard service
	LeaderboardService.init()
end)

if not success then
	warn("Failed to initialize LeaderboardService:", err)
	-- Game can still run without leaderboard in Studio
end

-- Initialize GhostService for multiplayer ghost relay
local ghostSuccess, ghostErr = pcall(function()
	local GhostService = require(script.GhostService)
	GhostService.init()
end)

if not ghostSuccess then
	warn("Failed to initialize GhostService:", ghostErr)
end
