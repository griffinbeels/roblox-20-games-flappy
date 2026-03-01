--[[
	MissionManager.luau

	Client facade for the mission/challenge system:
	- Reports client-side mission events
	- Caches mission state from server
	- Applies reward sync payloads (currency + shop cache)
	- Redeems completed missions on user action
	- Emits completion notifications and callbacks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local CurrencyConfig = require(ReplicatedStorage.Shared.CurrencyConfig)
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)

local CurrencyManager = require(script.Parent.CurrencyManager)
local ShopManager = require(script.Parent.ShopManager)

local MissionManager = {}

local initialized = false
local isReady = false

local getStateRemote = nil
local reportEventRemote = nil
local stateUpdatedRemote = nil
local redeemMissionRemote = nil

local queuedEvents = {}
local cachedState = nil

local stateChangedCallbacks = {}
local missionCompletedCallbacks = {}

local function getPrestigeMissionIdPrefix()
	local cfg = PrestigeConfig.PRESTIGE_MISSION or {}
	return tostring(cfg.ID_PREFIX or "prestige_next_score")
end

local function isPrestigeMissionId(missionId)
	if type(missionId) ~= "string" or missionId == "" then
		return false
	end

	local prefix = getPrestigeMissionIdPrefix()
	return string.sub(missionId, 1, #prefix) == prefix
end

--============================================================================
-- HELPERS
--============================================================================

local function getItemName(itemId)
	local item = ShopConfig.getItem(itemId)
	if item and item.name then
		return item.name
	end
	return itemId
end

local function rewardSummary(reward)
	if type(reward) ~= "table" then
		return nil
	end

	if reward.type == "bacon" and reward.amount and reward.granted ~= false then
		return string.format("+%d %s", reward.amount, CurrencyConfig.NAME)
	end

	if reward.type == "shop_item" then
		if reward.convertedToBacon then
			return string.format("+%d %s", reward.convertedToBacon, CurrencyConfig.NAME)
		end
		if reward.itemId and reward.granted == true then
			return "Unlocked " .. getItemName(reward.itemId)
		end
		if reward.itemId and reward.granted == nil then
			return "Unlock " .. getItemName(reward.itemId)
		end
	end

	if reward.type == "shop_unlock" and reward.itemId then
		if reward.granted == true then
			return "Shop unlocked: " .. getItemName(reward.itemId)
		end
		if reward.granted == nil then
			return "Shop Unlock: " .. getItemName(reward.itemId)
		end
	end

	if reward.type == "prestige_level" then
		local level = math.max(1, math.floor(tonumber(reward.level) or 1))
		return string.format("Prestige %d", level)
	end

	return nil
end

local function completionSummary(completion)
	local parts = {}
	for _, reward in ipairs(completion.rewards or {}) do
		local summary = rewardSummary(reward)
		if summary then
			table.insert(parts, summary)
		end
	end

	if #parts == 0 then
		return "Mission complete"
	end
	return table.concat(parts, ", ")
end

local function notifyCompletion(completion)
	local title = "Mission Complete"
	local text = string.format("%s - Redeem in Missions (%s)", completion.title or "Challenge", completionSummary(completion))
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = 5,
		})
	end)
end

local function applySync(syncPayload)
	if type(syncPayload) ~= "table" then
		return
	end

	if syncPayload.currencyBalance ~= nil then
		CurrencyManager.setLifetimeBalance(syncPayload.currencyBalance)
	end

	if syncPayload.shopData ~= nil and ShopManager.applyServerSnapshot then
		ShopManager.applyServerSnapshot(syncPayload.shopData)
	end
end

local function emitStateChanged(state)
	for _, callback in ipairs(stateChangedCallbacks) do
		task.spawn(callback, state)
	end
end

local function emitCompleted(completion)
	for _, callback in ipairs(missionCompletedCallbacks) do
		task.spawn(callback, completion)
	end
end

local function handlePayload(payload)
	if type(payload) ~= "table" then
		return
	end

	applySync(payload.sync)

	if payload.state then
		cachedState = payload.state
		emitStateChanged(cachedState)
	end

	for _, completion in ipairs(payload.newlyCompleted or {}) do
		notifyCompletion(completion)
		emitCompleted(completion)
	end
end

local function flushQueuedEvents()
	if not reportEventRemote then
		return
	end

	for _, queued in ipairs(queuedEvents) do
		reportEventRemote:FireServer(queued.eventName, queued.payload)
	end

	table.clear(queuedEvents)
end

--============================================================================
-- PUBLIC API
--============================================================================

function MissionManager.init()
	if initialized then
		return
	end
	initialized = true

	task.spawn(function()
		local remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remoteFolder then
			warn("[MissionManager] Remotes folder not found - missions disabled.")
			return
		end

		getStateRemote = remoteFolder:WaitForChild(MissionConfig.REMOTES.GET_STATE, 10)
		reportEventRemote = remoteFolder:WaitForChild(MissionConfig.REMOTES.REPORT_EVENT, 10)
		stateUpdatedRemote = remoteFolder:WaitForChild(MissionConfig.REMOTES.STATE_UPDATED, 10)
		redeemMissionRemote = remoteFolder:WaitForChild(MissionConfig.REMOTES.REDEEM, 10)

		if not getStateRemote or not reportEventRemote or not stateUpdatedRemote or not redeemMissionRemote then
			warn("[MissionManager] Mission remotes not found - missions disabled.")
			return
		end

		stateUpdatedRemote.OnClientEvent:Connect(handlePayload)

		isReady = true
		flushQueuedEvents()

		local ok, payload = pcall(function()
			return getStateRemote:InvokeServer()
		end)
		if ok and payload then
			handlePayload(payload)
		end
	end)
end

--[[
	Reports a mission event to the server.
	Events sent before remotes are ready are queued.
]]
function MissionManager.reportEvent(eventName, payload)
	if type(eventName) ~= "string" then
		return
	end

	local safePayload = if type(payload) == "table" then payload else {}

	if reportEventRemote and isReady then
		reportEventRemote:FireServer(eventName, safePayload)
		return
	end

	if #queuedEvents >= 100 then
		table.remove(queuedEvents, 1)
	end
	table.insert(queuedEvents, {
		eventName = eventName,
		payload = safePayload,
	})
end

function MissionManager.requestState()
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

function MissionManager.getState()
	return cachedState
end

function MissionManager.getRedeemableCount(state)
	local sourceState = state or cachedState
	if type(sourceState) ~= "table" or type(sourceState.missions) ~= "table" then
		return 0
	end

	local count = 0
	for _, mission in ipairs(sourceState.missions) do
		if type(mission) == "table" and mission.canRedeem == true then
			count += 1
		end
	end

	return count
end

function MissionManager.isPrestigeMission(missionOrId)
	if type(missionOrId) == "table" then
		return isPrestigeMissionId(missionOrId.id)
	end
	return isPrestigeMissionId(missionOrId)
end

function MissionManager.getPrestigeMissions(state)
	local sourceState = state or cachedState
	if type(sourceState) ~= "table" or type(sourceState.missions) ~= "table" then
		return {}
	end

	local output = {}
	for _, mission in ipairs(sourceState.missions) do
		if type(mission) == "table" and MissionManager.isPrestigeMission(mission) then
			table.insert(output, mission)
		end
	end
	return output
end

function MissionManager.getPrestigeRedeemableCount(state)
	local sourceState = state or cachedState
	if type(sourceState) ~= "table" or type(sourceState.missions) ~= "table" then
		return 0
	end

	local count = 0
	for _, mission in ipairs(sourceState.missions) do
		if type(mission) == "table"
			and MissionManager.isPrestigeMission(mission)
			and mission.canRedeem == true then
			count += 1
		end
	end
	return count
end

function MissionManager.getNonPrestigeRedeemableCount(state)
	local sourceState = state or cachedState
	if type(sourceState) ~= "table" or type(sourceState.missions) ~= "table" then
		return 0
	end

	local count = 0
	for _, mission in ipairs(sourceState.missions) do
		if type(mission) == "table"
			and not MissionManager.isPrestigeMission(mission)
			and mission.canRedeem == true then
			count += 1
		end
	end
	return count
end

function MissionManager.onStateChanged(callback)
	if type(callback) ~= "function" then
		return
	end
	table.insert(stateChangedCallbacks, callback)
	if cachedState then
		task.spawn(callback, cachedState)
	end
end

function MissionManager.onMissionCompleted(callback)
	if type(callback) ~= "function" then
		return
	end
	table.insert(missionCompletedCallbacks, callback)
end

function MissionManager.redeemMission(missionId)
	if type(missionId) ~= "string" or missionId == "" then
		return false, "Invalid mission"
	end

	if not redeemMissionRemote or not isReady then
		return false, "Mission system not ready"
	end

	local ok, payload = pcall(function()
		return redeemMissionRemote:InvokeServer(missionId)
	end)
	if not ok then
		return false, tostring(payload)
	end

	if type(payload) == "table" then
		handlePayload(payload)
	end

	if type(payload) ~= "table" then
		return false, "Invalid response"
	end

	if payload.success ~= true then
		return false, tostring(payload.reason or "Redeem failed"), payload
	end

	return true, payload.redeemed, payload
end

return MissionManager
