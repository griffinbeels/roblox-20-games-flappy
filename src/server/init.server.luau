--[[
	init.server.luau

	Main server entry point for Flappy Bird game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)

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

-- ToggleSpeedDebugLog: server fires this to toggle/force the client-side
-- once-per-second speed log in the output console (Studio playtesting).
local toggleSpeedDebugLog = remotes:FindFirstChild("ToggleSpeedDebugLog")
if not toggleSpeedDebugLog then
	toggleSpeedDebugLog = Instance.new("RemoteEvent")
	toggleSpeedDebugLog.Name = "ToggleSpeedDebugLog"
	toggleSpeedDebugLog.Parent = remotes
end

-- DebugProgressReset: server fires this after a debug reset so the client can
-- refresh cached shop/mission/prestige/currency/score state in the same session.
local debugProgressReset = remotes:FindFirstChild("DebugProgressReset")
if not debugProgressReset then
	debugProgressReset = Instance.new("RemoteEvent")
	debugProgressReset.Name = "DebugProgressReset"
	debugProgressReset.Parent = remotes
end

local DEBUG_COMMANDS_ENABLED = RunService:IsStudio()

local LeaderboardService = nil
local CurrencyService = nil
local ShopService = nil
local MissionService = nil
local PrestigeService = nil

local lastRespawnTime = {} -- per-player cooldown to prevent spam

local function normalizeChatCommand(message)
	if type(message) ~= "string" then
		return ""
	end

	local trimmed = string.gsub(message, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	return string.lower(trimmed)
end

local function debugResetService(serviceName, service, player)
	if not service or type(service.debugResetPlayer) ~= "function" then
		return false, serviceName .. " unavailable"
	end

	local ok, successOrErr, errMaybe = pcall(function()
		return service.debugResetPlayer(player)
	end)
	if not ok then
		return false, serviceName .. " reset errored: " .. tostring(successOrErr)
	end
	if successOrErr == false then
		return false, serviceName .. " reset failed: " .. tostring(errMaybe or "unknown")
	end

	return true, nil
end

local function respawnPlayerForReset(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	task.defer(function()
		if player.Parent == Players then
			player:LoadCharacter()
		end
	end)
end

local function resetPrestigeForPlayer(player)
	if DEBUG_COMMANDS_ENABLED ~= true then
		return
	end

	local errors = {}
	if PrestigeConfig.ENABLED == true then
		local ok, err = debugResetService("PrestigeService", PrestigeService, player)
		if not ok then
			table.insert(errors, err)
		end
	end

	debugProgressReset:FireClient(player, {
		mode = "prestige",
		success = #errors == 0,
		errors = errors,
	})
	respawnPlayerForReset(player)

	if #errors == 0 then
		print(string.format("[DebugReset] Reset prestige for %s (%d).", player.Name, player.UserId))
	else
		warn(string.format("[DebugReset] Prestige reset completed with issues for %s: %s", player.Name, table.concat(errors, " | ")))
	end
end

local function resetAllProgressForPlayer(player)
	if DEBUG_COMMANDS_ENABLED ~= true then
		return
	end

	local errors = {}

	local function runReset(serviceName, service)
		local ok, err = debugResetService(serviceName, service, player)
		if not ok then
			table.insert(errors, err)
		end
	end

	runReset("LeaderboardService", LeaderboardService)
	runReset("CurrencyService", CurrencyService)
	runReset("ShopService", ShopService)
	if PrestigeConfig.ENABLED == true then
		runReset("PrestigeService", PrestigeService)
	end
	runReset("MissionService", MissionService)

	debugProgressReset:FireClient(player, {
		mode = "all",
		success = #errors == 0,
		errors = errors,
	})
	respawnPlayerForReset(player)

	if #errors == 0 then
		print(string.format("[DebugReset] Reset ALL progress for %s (%d).", player.Name, player.UserId))
	else
		warn(string.format("[DebugReset] All-progress reset completed with issues for %s: %s", player.Name, table.concat(errors, " | ")))
	end
end

local function wireDebugChatCommands(player)
	player.Chatted:Connect(function(message)
		local cmd = normalizeChatCommand(message)
		if cmd == "" then
			return
		end

		if cmd == "/debugcam" then
			toggleDebugCamera:FireClient(player)
			return
		end

		if DEBUG_COMMANDS_ENABLED ~= true then
			return
		end

		if cmd == "/resetprestige" or cmd == "/prestigereset" or cmd == "/resetprogress prestige" then
			resetPrestigeForPlayer(player)
			return
		end

		if cmd == "/debugspeed" or cmd == "/speeddebug" or cmd == "/speedlog" then
			toggleSpeedDebugLog:FireClient(player, {
				action = "toggle",
			})
			return
		end

		if cmd == "/debugspeed on" or cmd == "/speeddebug on" or cmd == "/speedlog on" then
			toggleSpeedDebugLog:FireClient(player, {
				action = "set",
				enabled = true,
			})
			return
		end

		if cmd == "/debugspeed off" or cmd == "/speeddebug off" or cmd == "/speedlog off" then
			toggleSpeedDebugLog:FireClient(player, {
				action = "set",
				enabled = false,
			})
			return
		end

		if cmd == "/resetallprogress" or cmd == "/resetprogress" or cmd == "/resetall" or cmd == "/resetprogress all" then
			resetAllProgressForPlayer(player)
			return
		end
	end)
end

requestRespawn.OnServerEvent:Connect(function(player)
	local now = tick()
	if lastRespawnTime[player] and (now - lastRespawnTime[player]) < 0.5 then
		return -- cooldown
	end
	lastRespawnTime[player] = now
	player:LoadCharacter()
end)

-- Manually load character on join (since CharacterAutoLoads = false)
-- Also wire debug chat commands
Players.PlayerAdded:Connect(function(player)
	player:LoadCharacter()
	wireDebugChatCommands(player)
end)

-- Clean up cooldown tracking on leave
Players.PlayerRemoving:Connect(function(player)
	lastRespawnTime[player] = nil
end)

-- Handle players already in the game (Studio fast-start)
for _, player in ipairs(Players:GetPlayers()) do
	wireDebugChatCommands(player)
	if not player.Character then
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

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

if ShopService and ShopService.setDependencies and MissionService then
	ShopService.setDependencies({
		missionService = MissionService,
	})
end

-- Initialize PrestigeService for prestige progression + tuning (config gated)
if PrestigeConfig.ENABLED == true then
	local prestigeRequireOk, prestigeModule = pcall(function()
		return require(script.PrestigeService)
	end)
	if prestigeRequireOk and prestigeModule then
		PrestigeService = prestigeModule
		local prestigeInitOk, prestigeErr = pcall(function()
			PrestigeService.init()
		end)
		if not prestigeInitOk then
			warn("Failed to initialize PrestigeService:", prestigeErr)
			PrestigeService = nil
		end
	else
		warn("Failed to require PrestigeService:", prestigeModule)
	end
end

if MissionService and MissionService.setDependencies and PrestigeService then
	MissionService.setDependencies({
		prestigeService = PrestigeService,
	})
end

if PrestigeService and PrestigeService.setDependencies and MissionService then
	PrestigeService.setDependencies({
		missionService = MissionService,
	})
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
