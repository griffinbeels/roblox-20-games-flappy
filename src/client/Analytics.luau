--[[
	Analytics.luau (client)

	Thin client-side facade for analytics. Fires structured payloads to the server
	via RemoteEvent; the server forwards them to Roblox AnalyticsService.

	Usage:
	  local Analytics = require(script.Parent.Analytics)
	  Analytics.logCustomEvent("GameStart")
	  Analytics.logCustomEvent("GameOver", 12, { speed = 1.5 })
	  Analytics.logProgressionStart("FlappyRun")
	  Analytics.logProgressionComplete("FlappyRun", nil, 12)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Analytics = {}

local remote = nil -- cached RemoteEvent

local function getRemote()
	if remote then return remote end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		remote = remotes:FindFirstChild("AnalyticsRemote")
	end
	return remote
end

local function fire(payload)
	local r = getRemote()
	if r then
		r:FireServer(payload)
	end
end

--[[
	Log a custom event.
	@param eventName  string — event name (use AnalyticsConfig.EVENTS constants)
	@param value      number? — optional numeric value
	@param fields     table? — optional custom fields dictionary
]]
function Analytics.logCustomEvent(eventName, value, fields)
	fire({
		type = "custom",
		name = eventName,
		value = value,
		fields = fields,
	})
end

--[[
	Log the start of a progression attempt (e.g. a game run).
]]
function Analytics.logProgressionStart(name, level)
	fire({
		type = "progression_start",
		name = name,
		level = level,
	})
end

--[[
	Log the successful completion of a progression attempt.
	@param value  number? — score or other metric
]]
function Analytics.logProgressionComplete(name, level, value)
	fire({
		type = "progression_complete",
		name = name,
		level = level,
		value = value,
	})
end

--[[
	Log a failed progression attempt.
	@param value  number? — score or other metric
]]
function Analytics.logProgressionFail(name, level, value)
	fire({
		type = "progression_fail",
		name = name,
		level = level,
		value = value,
	})
end

--[[
	Log a funnel step event.
]]
function Analytics.logFunnelStep(funnelName, step, sessionId)
	fire({
		type = "funnel_step",
		name = funnelName,
		step = step,
		sessionId = sessionId,
	})
end

--[[
	Log an economy event.
]]
function Analytics.logEconomyEvent(flowType, currency, balance, itemName)
	fire({
		type = "economy",
		flowType = flowType,
		currency = currency,
		balance = balance,
		itemName = itemName,
	})
end

return Analytics
