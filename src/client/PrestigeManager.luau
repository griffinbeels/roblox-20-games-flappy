--[[
	PrestigeManager.luau

	Client facade for prestige state:
	- Requests and caches server prestige state
	- Mirrors server push updates
	- Forwards intent calls (set tuning, attempt prestige, run reports)
	- Keeps RuntimeTuning in sync with server-selected values
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)

local PrestigeManager = {}

local initialized = false
local isReady = false

local getStateRemote = nil
local stateUpdatedRemote = nil
local reportRunRemote = nil
local attemptPrestigeRemote = nil
local setTuningRemote = nil

local queuedRunEvents = {}
local cachedState = nil

local stateChangedCallbacks = {}
local prestigeSuccessCallbacks = {}

local function notifyPrestigeSuccess(levelTitle)
	local text = "New prestige unlocked!"
	if type(levelTitle) == "string" and levelTitle ~= "" then
		text = levelTitle .. " unlocked!"
	end

	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Prestige Up!",
			Text = text,
			Duration = 5,
		})
	end)
end

local function emitStateChanged(state, context)
	for _, callback in ipairs(stateChangedCallbacks) do
		task.spawn(callback, state, context)
	end
end

local function emitPrestigeSuccess(context)
	for _, callback in ipairs(prestigeSuccessCallbacks) do
		task.spawn(callback, context)
	end
end

local function applyState(newState, context)
	if type(newState) ~= "table" then
		return
	end

	cachedState = newState

	local tuning = newState.tuning
	if PrestigeConfig.RUNTIME_TUNING_ENABLED ~= false and type(tuning) == "table" then
		RuntimeTuning.setActiveTuning(tuning.selected, tuning.limits)
	end

	if type(context) == "table" and context.type == "prestige_success" then
		notifyPrestigeSuccess(context.title)
		emitPrestigeSuccess(context)
	end

	emitStateChanged(cachedState, context)
end

local function handlePayload(payload)
	if type(payload) ~= "table" then
		return
	end

	if payload.state then
		applyState(payload.state, payload.context)
	end
end

local function flushQueuedRunEvents()
	if not reportRunRemote then
		return
	end

	for _, eventData in ipairs(queuedRunEvents) do
		reportRunRemote:FireServer(eventData.eventName, eventData.payload)
	end
	table.clear(queuedRunEvents)
end

local function queueRunEvent(eventName, payload)
	if #queuedRunEvents >= 100 then
		table.remove(queuedRunEvents, 1)
	end
	table.insert(queuedRunEvents, {
		eventName = eventName,
		payload = payload,
	})
end

local function invokeRemote(remote, ...)
	if not remote then
		return false, { success = false, reasonCode = "NOT_READY", message = "Prestige service not ready." }
	end

	local ok, response = pcall(remote.InvokeServer, remote, ...)

	if not ok then
		return false, { success = false, reasonCode = "NETWORK_ERROR", message = "Network error while contacting prestige service." }
	end

	if type(response) == "table" and response.state then
		applyState(response.state, response.context)
	end

	return true, response
end

function PrestigeManager.init()
	if initialized then
		return
	end
	if PrestigeConfig.ENABLED ~= true then
		return
	end
	initialized = true

	task.spawn(function()
		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remoteFolder then
			warn("[PrestigeManager] Remotes folder not found - prestige disabled.")
			return
		end

		getStateRemote = remoteFolder:WaitForChild(PrestigeConfig.REMOTES.GET_STATE, 10)
		stateUpdatedRemote = remoteFolder:WaitForChild(PrestigeConfig.REMOTES.STATE_UPDATED, 10)
		reportRunRemote = remoteFolder:WaitForChild(PrestigeConfig.REMOTES.REPORT_RUN, 10)
		attemptPrestigeRemote = remoteFolder:WaitForChild(PrestigeConfig.REMOTES.ATTEMPT_PRESTIGE, 10)
		setTuningRemote = remoteFolder:WaitForChild(PrestigeConfig.REMOTES.SET_TUNING, 10)

		if not getStateRemote or not stateUpdatedRemote or not reportRunRemote or not attemptPrestigeRemote or not setTuningRemote then
			warn("[PrestigeManager] Prestige remotes not found - prestige disabled.")
			return
		end

		stateUpdatedRemote.OnClientEvent:Connect(handlePayload)

		isReady = true
		flushQueuedRunEvents()
		PrestigeManager.requestState()
	end)
end

function PrestigeManager.requestState()
	if not getStateRemote then
		return
	end

	local ok, payload = pcall(function()
		return getStateRemote:InvokeServer()
	end)
	if ok and payload then
		handlePayload(payload)
	end
end

function PrestigeManager.getState()
	return cachedState
end

function PrestigeManager.isReady()
	return isReady
end

function PrestigeManager.getSelectedTuning()
	local tuning = cachedState and cachedState.tuning and cachedState.tuning.selected
	return RuntimeTuning.cloneTuning(tuning or RuntimeTuning.getDefaultTuning())
end

function PrestigeManager.isPrestigeReady()
	local nextLevel = cachedState and cachedState.nextLevel
	return type(nextLevel) == "table" and nextLevel.unlocked == true
end

function PrestigeManager.setTuning(tuning)
	local ok, response = invokeRemote(setTuningRemote, tuning)
	if not ok then
		return response
	end
	return response
end

function PrestigeManager.attemptPrestige()
	local ok, response = invokeRemote(attemptPrestigeRemote)
	if not ok then
		return response
	end
	return response
end

function PrestigeManager.reportRunStarted()
	if reportRunRemote and isReady then
		reportRunRemote:FireServer("run_started", {})
		return
	end
	queueRunEvent("run_started", {})
end

function PrestigeManager.reportRunFinished(score, runMetrics)
	local payload = {
		score = score,
	}
	if type(runMetrics) == "table" then
		local maxSpeedMultiplierReached = tonumber(runMetrics.maxSpeedMultiplierReached)
		if maxSpeedMultiplierReached ~= nil then
			payload.maxSpeedMultiplierReached = maxSpeedMultiplierReached
		end
	else
		local maxSpeedMultiplierReached = tonumber(runMetrics)
		if maxSpeedMultiplierReached ~= nil then
			payload.maxSpeedMultiplierReached = maxSpeedMultiplierReached
		end
	end

	if reportRunRemote and isReady then
		reportRunRemote:FireServer("run_finished", payload)
		return
	end
	queueRunEvent("run_finished", payload)
end

function PrestigeManager.reportRunAbandoned()
	if reportRunRemote and isReady then
		reportRunRemote:FireServer("run_abandoned", {})
		return
	end
	queueRunEvent("run_abandoned", {})
end

function PrestigeManager.onStateChanged(callback)
	if type(callback) ~= "function" then
		return
	end

	table.insert(stateChangedCallbacks, callback)
	if cachedState then
		task.spawn(callback, cachedState, nil)
	end
end

function PrestigeManager.onPrestigeSuccess(callback)
	if type(callback) ~= "function" then
		return
	end

	table.insert(prestigeSuccessCallbacks, callback)
end

return PrestigeManager
