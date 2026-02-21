--[[
	AnalyticsService.luau (server)

	Server-side service that receives analytics events from clients via RemoteEvent
	and forwards them to Roblox AnalyticsService.

	Protocol: client sends a table with:
	  { type = "custom", name = "GameStart", value = nil, fields = { speed = 1.2 } }
	  { type = "progression_start", name = "FlappyRun", level = nil }
	  { type = "progression_complete", name = "FlappyRun", level = nil, value = 12 }
	  { type = "progression_fail", name = "FlappyRun", level = nil, value = 3 }
	  { type = "funnel_step", name = "Onboarding", step = 2, sessionId = "abc" }
	  { type = "economy", flowType = 1, currency = "Coins", balance = 50, itemName = "Trail" }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsServiceModule = {}

local robloxAnalytics = nil -- Roblox AnalyticsService (may not exist in Studio)
local lastEventTime = {} -- player -> tick, simple per-player rate-limit

local MIN_EVENT_INTERVAL = 0.05 -- seconds between events per player

local function handleEvent(player, payload)
	if typeof(payload) ~= "table" then return end
	if typeof(payload.type) ~= "string" then return end

	-- Rate-limit guard
	local now = tick()
	local last = lastEventTime[player]
	if last and (now - last) < MIN_EVENT_INTERVAL then
		return
	end
	lastEventTime[player] = now

	if not robloxAnalytics then return end

	local eventType = payload.type

	local ok, err = pcall(function()
		if eventType == "custom" then
			robloxAnalytics:LogCustomEvent(
				player,
				payload.name or "Unknown",
				payload.value,
				payload.fields
			)

		elseif eventType == "progression_start" then
			robloxAnalytics:LogProgressionEvent(
				player,
				"Begin",
				payload.name or "Unknown",
				payload.level,
				payload.value
			)

		elseif eventType == "progression_complete" then
			robloxAnalytics:LogProgressionEvent(
				player,
				"Complete",
				payload.name or "Unknown",
				payload.level,
				payload.value
			)

		elseif eventType == "progression_fail" then
			robloxAnalytics:LogProgressionEvent(
				player,
				"Fail",
				payload.name or "Unknown",
				payload.level,
				payload.value
			)

		elseif eventType == "funnel_step" then
			robloxAnalytics:LogFunnelStepEvent(
				player,
				payload.name or "Unknown",
				payload.sessionId,
				payload.step or 1
			)

		elseif eventType == "economy" then
			robloxAnalytics:LogEconomyEvent(
				player,
				payload.flowType or Enum.AnalyticsEconomyFlowType.Source,
				payload.currency or "Coins",
				payload.balance or 0,
				payload.itemName or ""
			)
		end
	end)

	if not ok then
		-- Expected to fail in Studio; suppress spam
		warn("[AnalyticsService] Event forwarding failed:", err)
	end
end

function AnalyticsServiceModule.init()
	-- Try to get Roblox AnalyticsService (not available in Studio)
	local ok, svc = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	if ok and svc then
		robloxAnalytics = svc
	else
		warn("[AnalyticsService] Roblox AnalyticsService not available (expected in Studio)")
	end

	-- Create RemoteEvent for client → server analytics
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local remote = remotes:FindFirstChild("AnalyticsRemote")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "AnalyticsRemote"
		remote.Parent = remotes
	end

	remote.OnServerEvent:Connect(handleEvent)

	-- Clean up rate-limit tracking on leave
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastEventTime[player] = nil
	end)
end

return AnalyticsServiceModule
