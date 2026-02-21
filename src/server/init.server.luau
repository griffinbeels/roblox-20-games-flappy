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

-- ToggleDebugCamera: server fires this to the chatting player to toggle the debug camera panel
local toggleDebugCamera = remotes:FindFirstChild("ToggleDebugCamera")
if not toggleDebugCamera then
	toggleDebugCamera = Instance.new("RemoteEvent")
	toggleDebugCamera.Name = "ToggleDebugCamera"
	toggleDebugCamera.Parent = remotes
end

-- Wire /debugcam chat listener for a single player
local function wireDebugCamChat(player)
	player.Chatted:Connect(function(message)
		if string.lower(message) == "/debugcam" then
			toggleDebugCamera:FireClient(player)
		end
	end)
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
-- Also wire /debugcam chat listener
Players.PlayerAdded:Connect(function(player)
	player:LoadCharacter()
	wireDebugCamChat(player)
end)

-- Clean up cooldown tracking on leave
Players.PlayerRemoving:Connect(function(player)
	lastRespawnTime[player] = nil
end)

-- Handle players already in the game (Studio fast-start)
for _, player in ipairs(Players:GetPlayers()) do
	wireDebugCamChat(player)
	if not player.Character then
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

local LeaderboardService = nil
local CurrencyService = nil
local ShopService = nil
local MissionService = nil

local leaderboardRequireOk, leaderboardModule = pcall(function()
	return require(script.LeaderboardService)
end)
if leaderboardRequireOk and leaderboardModule then
	LeaderboardService = leaderboardModule
	local leaderboardInitOk, leaderboardErr = pcall(function()
		LeaderboardService.init()
	end)
	if not leaderboardInitOk then
		warn("Failed to initialize LeaderboardService:", leaderboardErr)
		LeaderboardService = nil
	end
else
	warn("Failed to require LeaderboardService:", leaderboardModule)
end

-- Initialize GhostService for multiplayer ghost relay
local ghostSuccess, ghostErr = pcall(function()
	local GhostService = require(script.GhostService)
	GhostService.init()
end)

if not ghostSuccess then
	warn("Failed to initialize GhostService:", ghostErr)
end

-- Initialize AnalyticsService for event tracking
local analyticsOk, analyticsErr = pcall(function()
	local AnalyticsServiceMod = require(script.AnalyticsService)
	AnalyticsServiceMod.init()
end)
if not analyticsOk then
	warn("Failed to initialize AnalyticsService:", analyticsErr)
end

-- Initialize CurrencyService for Bacon currency persistence
local currencyRequireOk, currencyModule = pcall(function()
	return require(script.CurrencyService)
end)
if currencyRequireOk and currencyModule then
	CurrencyService = currencyModule
	local currencyInitOk, currencyErr = pcall(function()
		CurrencyService.init()
	end)
	if not currencyInitOk then
		warn("Failed to initialize CurrencyService:", currencyErr)
		CurrencyService = nil
	end
else
	warn("Failed to require CurrencyService:", currencyModule)
end

-- Initialize ShopService for cosmetic shop persistence
local shopRequireOk, shopModule = pcall(function()
	return require(script.ShopService)
end)
if shopRequireOk and shopModule then
	ShopService = shopModule
	local shopInitOk, shopErr = pcall(function()
		ShopService.init()
	end)
	if not shopInitOk then
		warn("Failed to initialize ShopService:", shopErr)
		ShopService = nil
	end
else
	warn("Failed to require ShopService:", shopModule)
end

-- Initialize MissionService for missions/challenges progression
local missionRequireOk, missionModule = pcall(function()
	return require(script.MissionService)
end)
if missionRequireOk and missionModule then
	MissionService = missionModule
	local missionInitOk, missionErr = pcall(function()
		MissionService.init({
			currencyService = CurrencyService,
			shopService = ShopService,
		})
	end)
	if not missionInitOk then
		warn("Failed to initialize MissionService:", missionErr)
		MissionService = nil
	end
else
	warn("Failed to require MissionService:", missionModule)
end

-- Wire mission event reporters from trusted server services.
if MissionService then
	if LeaderboardService and LeaderboardService.setMissionReporter then
		LeaderboardService.setMissionReporter(function(player, eventName, payload)
			MissionService.reportServerEvent(player, eventName, payload)
		end)
	end

	if CurrencyService and CurrencyService.setMissionReporter then
		CurrencyService.setMissionReporter(function(player, eventName, payload)
			MissionService.reportServerEvent(player, eventName, payload)
		end)
	end

	if ShopService and ShopService.setMissionReporter then
		ShopService.setMissionReporter(function(player, eventName, payload)
			MissionService.reportServerEvent(player, eventName, payload)
		end)
	end
end
