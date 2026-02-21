--[[
	MissionService.luau

	Server-authoritative mission progression system:
	- Persists mission stats + completion state per player
	- Accepts tracked events (client + server)
	- Evaluates mission conditions from MissionConfig
	- Grants rewards (bacon + shop items)
	- Pushes mission state/completion updates to clients
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)

local MissionService = {}

-- DataStore handle
local missionDataStore = nil
local dataStoreAvailable = false

local initOk, _ = pcall(function()
	missionDataStore = DataStoreService:GetDataStore(MissionConfig.DATASTORE_NAME)
	dataStoreAvailable = true
end)

if not dataStoreAvailable then
	warn("[MissionService] DataStore not available - mission progress will persist in-memory only (Studio mode).")
end

-- In-memory state
local cachedProfiles = {}     -- userId -> profile
local dirtyProfiles = {}      -- userId -> true
local eventCooldowns = {}     -- userId -> { eventName = tick() }
local runActiveByUser = {}    -- userId -> boolean
local queuedCompletionSaves = {} -- userId -> true (debounced completion save)
local queuedCompletionSaveTokens = {} -- userId -> token (cancels stale delayed callbacks)
local exitSaveStarted = {} -- userId -> true once an exit save has started (PlayerRemoving/BindToClose dedupe)

-- Dependencies (injected from init.server.luau)
local currencyService = nil
local shopService = nil

-- Remotes
local getStateRemote = nil
local reportEventRemote = nil
local stateUpdatedRemote = nil

local initialized = false

--============================================================================
-- PROFILE SHAPE
--============================================================================

local function createDefaultProfile()
	return {
		version = MissionConfig.VERSION,
		stats = {},
		flags = {},
		completed = {}, -- [missionId] = unix timestamp
	}
end

local function copyPrimitiveMap(source)
	local output = {}
	if type(source) ~= "table" then
		return output
	end

	for key, value in pairs(source) do
		if type(key) == "string" then
			local valueType = type(value)
			if valueType == "number" or valueType == "string" or valueType == "boolean" then
				output[key] = value
			end
		end
	end

	return output
end

local function copyCompletedMap(source)
	local output = {}
	if type(source) ~= "table" then
		return output
	end

	for missionId, completedAt in pairs(source) do
		if type(missionId) == "string" then
			if type(completedAt) == "number" then
				output[missionId] = completedAt
			elseif completedAt == true then
				output[missionId] = os.time()
			end
		end
	end

	return output
end

local function sanitizeProfile(raw)
	local profile = createDefaultProfile()
	if type(raw) ~= "table" then
		return profile
	end

	if type(raw.version) == "number" then
		profile.version = raw.version
	end
	profile.stats = copyPrimitiveMap(raw.stats)
	profile.flags = copyPrimitiveMap(raw.flags)
	profile.completed = copyCompletedMap(raw.completed)

	return profile
end

local function profileKeyForUser(userId)
	return "user_" .. userId
end

local function loadProfile(userId)
	if cachedProfiles[userId] then
		return cachedProfiles[userId]
	end

	-- Player may rejoin the same server instance; clear one-shot exit flags.
	exitSaveStarted[userId] = nil
	queuedCompletionSaveTokens[userId] = nil

	local profile = createDefaultProfile()

	if dataStoreAvailable and missionDataStore then
		local ok, stored = pcall(function()
			return missionDataStore:GetAsync(profileKeyForUser(userId))
		end)
		if ok and stored then
			profile = sanitizeProfile(stored)
		end
	end

	cachedProfiles[userId] = profile
	runActiveByUser[userId] = false
	return profile
end

local function saveProfile(userId, force)
	local profile = cachedProfiles[userId]
	if not profile then
		return false
	end

	if not force and not dirtyProfiles[userId] then
		return true
	end

	if not dataStoreAvailable or not missionDataStore then
		dirtyProfiles[userId] = nil
		return true
	end

	local payload = {
		version = MissionConfig.VERSION,
		stats = profile.stats,
		flags = profile.flags,
		completed = profile.completed,
	}

	local ok, err = pcall(function()
		missionDataStore:SetAsync(profileKeyForUser(userId), payload)
	end)

	if ok then
		dirtyProfiles[userId] = nil
		return true
	end

	warn("[MissionService] Failed to save mission data for user " .. userId .. ": " .. tostring(err))
	dirtyProfiles[userId] = true
	return false
end

local function markProfileDirty(userId)
	dirtyProfiles[userId] = true
end

local function cancelQueuedCompletionSave(userId)
	queuedCompletionSaves[userId] = nil
	queuedCompletionSaveTokens[userId] = (queuedCompletionSaveTokens[userId] or 0) + 1
end

local function queueCompletionSave(userId)
	if queuedCompletionSaves[userId] then
		return
	end

	queuedCompletionSaves[userId] = true
	local token = (queuedCompletionSaveTokens[userId] or 0) + 1
	queuedCompletionSaveTokens[userId] = token
	local delaySeconds = MissionConfig.COMPLETION_SAVE_DELAY or 2

	task.delay(delaySeconds, function()
		if queuedCompletionSaveTokens[userId] ~= token then
			return
		end
		queuedCompletionSaves[userId] = nil
		saveProfile(userId, true)
	end)
end

local function saveProfileOnExit(userId)
	if exitSaveStarted[userId] then
		return true
	end
	exitSaveStarted[userId] = true
	cancelQueuedCompletionSave(userId)

	-- Exit paths should not force a write if nothing changed.
	return saveProfile(userId, false)
end

--============================================================================
-- PATH HELPERS
--============================================================================

local function readPath(root, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local node = root
	for part in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
		if node == nil then
			return nil
		end
	end

	return node
end

local function resolveParent(root, path, createMissing)
	if type(path) ~= "string" or path == "" then
		return nil, nil
	end

	local keys = {}
	for part in string.gmatch(path, "[^%.]+") do
		table.insert(keys, part)
	end

	if #keys == 0 then
		return nil, nil
	end

	local node = root
	for i = 1, #keys - 1 do
		local key = keys[i]
		local child = node[key]
		if type(child) ~= "table" then
			if not createMissing then
				return nil, nil
			end
			child = {}
			node[key] = child
		end
		node = child
	end

	return node, keys[#keys]
end

--============================================================================
-- CONDITION EVALUATION
--============================================================================

local function evaluateCondition(condition, context)
	if type(condition) ~= "table" then
		return false
	end

	local conditionType = condition.type or "compare"

	if conditionType == "all" then
		local list = condition.conditions
		if type(list) ~= "table" then
			return false
		end
		for _, subCondition in ipairs(list) do
			if not evaluateCondition(subCondition, context) then
				return false
			end
		end
		return true
	end

	if conditionType == "any" then
		local list = condition.conditions
		if type(list) ~= "table" then
			return false
		end
		for _, subCondition in ipairs(list) do
			if evaluateCondition(subCondition, context) then
				return true
			end
		end
		return false
	end

	if conditionType == "not" then
		return not evaluateCondition(condition.condition, context)
	end

	if conditionType == "compare" then
		local left = readPath(context, condition.path)
		if left == nil and condition.default ~= nil then
			left = condition.default
		end

		local right = condition.value
		if condition.valuePath then
			right = readPath(context, condition.valuePath)
		end

		local op = condition.op or ">="
		if op == "==" then
			return left == right
		end
		if op == "~=" then
			return left ~= right
		end

		if op == "contains_key" then
			return type(left) == "table" and left[right] ~= nil
		end
		if op == "contains_value" then
			if type(left) ~= "table" then
				return false
			end
			for _, value in pairs(left) do
				if value == right then
					return true
				end
			end
			return false
		end

		if type(left) ~= "number" or type(right) ~= "number" then
			return false
		end

		if op == ">=" then return left >= right end
		if op == ">" then return left > right end
		if op == "<=" then return left <= right end
		if op == "<" then return left < right end
		return false
	end

	return false
end

local function requirementsMet(profile, mission)
	local requirements = mission.requires
	if type(requirements) ~= "table" then
		return true
	end

	for _, requiredMissionId in ipairs(requirements) do
		if not profile.completed[requiredMissionId] then
			return false
		end
	end

	return true
end

--============================================================================
-- EVENT -> STAT UPDATES
--============================================================================

local function resolveUpdateValue(update, payload)
	local value = update.value
	if update.from then
		value = readPath(payload, update.from)
	end

	if value == nil then
		return nil
	end

	if update.integer and type(value) == "number" then
		value = math.floor(value)
	end

	if type(value) == "number" then
		if update.clampMin ~= nil then
			value = math.max(update.clampMin, value)
		end
		if update.clampMax ~= nil then
			value = math.min(update.clampMax, value)
		end
	end

	return value
end

local function applyUpdate(profile, update, payload)
	if type(update) ~= "table" or type(update.path) ~= "string" then
		return false
	end

	local parent, key = resolveParent(profile, update.path, true)
	if not parent or not key then
		return false
	end

	local op = update.op or "set"

	if op == "set_now" then
		parent[key] = os.time()
		return true
	end

	local value = resolveUpdateValue(update, payload)
	if value == nil then
		return false
	end

	local current = parent[key]

	if op == "set" then
		parent[key] = value
		return true
	end

	if op == "add" then
		if type(value) ~= "number" then
			return false
		end
		local currentNumber = if type(current) == "number" then current else 0
		parent[key] = currentNumber + value
		return true
	end

	if op == "max" then
		if type(value) ~= "number" then
			return false
		end
		local currentNumber = if type(current) == "number" then current else value
		parent[key] = math.max(currentNumber, value)
		return true
	end

	if op == "min" then
		if type(value) ~= "number" then
			return false
		end
		local currentNumber = if type(current) == "number" then current else value
		parent[key] = math.min(currentNumber, value)
		return true
	end

	return false
end

local function passesCooldown(userId, eventName, eventDef)
	local cooldown = eventDef.cooldown or 0
	if cooldown <= 0 then
		return true
	end

	local byEvent = eventCooldowns[userId]
	if not byEvent then
		byEvent = {}
		eventCooldowns[userId] = byEvent
	end

	local now = tick()
	local last = byEvent[eventName]
	if last and (now - last) < cooldown then
		return false
	end

	byEvent[eventName] = now
	return true
end

local function passesRunGate(userId, eventDef)
	if eventDef.startRun then
		if runActiveByUser[userId] then
			return false
		end
		runActiveByUser[userId] = true
	end

	if eventDef.finishRun then
		if not runActiveByUser[userId] then
			return false
		end
		runActiveByUser[userId] = false
	end

	return true
end

--============================================================================
-- REWARDS
--============================================================================

local function mergeSyncData(target, delta)
	if not delta then return end
	if delta.currencyBalance ~= nil then
		target.currencyBalance = delta.currencyBalance
	end
	if delta.shopData ~= nil then
		target.shopData = delta.shopData
	end
end

local function grantBaconReward(userId, reward, syncData)
	local amount = math.floor(tonumber(reward.amount) or 0)
	if amount <= 0 then
		return {
			type = "bacon",
			amount = amount,
			granted = false,
			reason = "Invalid amount",
		}
	end

	if not currencyService or not currencyService.add then
		return {
			type = "bacon",
			amount = amount,
			granted = false,
			reason = "Currency service unavailable",
		}
	end

	local newBalance = currencyService.add(userId, amount)
	syncData.currencyBalance = newBalance
	return {
		type = "bacon",
		amount = amount,
		granted = true,
		newBalance = newBalance,
	}
end

local function grantShopItemReward(userId, reward, syncData)
	local itemId = reward.itemId
	if type(itemId) ~= "string" then
		return {
			type = "shop_item",
			itemId = tostring(itemId),
			granted = false,
			reason = "Invalid item ID",
		}
	end

	if not shopService or not shopService.grantItem then
		return {
			type = "shop_item",
			itemId = itemId,
			granted = false,
			reason = "Shop service unavailable",
		}
	end

	local success, reason, data = shopService.grantItem(userId, itemId, {
		autoEquip = reward.autoEquip == true,
	})

	if success then
		if data then
			syncData.shopData = {
				owned = data.owned,
				equipped = data.equipped,
			}
		end
		return {
			type = "shop_item",
			itemId = itemId,
			granted = true,
			autoEquip = reward.autoEquip == true,
		}
	end

	local duplicateBacon = math.floor(tonumber(reward.duplicateBacon) or 0)
	if reason == "Already owned" and duplicateBacon > 0 and currencyService and currencyService.add then
		local newBalance = currencyService.add(userId, duplicateBacon)
		syncData.currencyBalance = newBalance
		return {
			type = "shop_item",
			itemId = itemId,
			granted = true,
			convertedToBacon = duplicateBacon,
			newBalance = newBalance,
		}
	end

	return {
		type = "shop_item",
		itemId = itemId,
		granted = false,
		reason = reason,
	}
end

local function grantRewards(userId, mission)
	local grantedRewards = {}
	local syncData = {}
	local rewards = mission.rewards or {}

	for _, reward in ipairs(rewards) do
		local rewardType = reward.type
		local rewardResult

		if rewardType == "bacon" then
			rewardResult = grantBaconReward(userId, reward, syncData)
		elseif rewardType == "shop_item" then
			rewardResult = grantShopItemReward(userId, reward, syncData)
		else
			rewardResult = {
				type = tostring(rewardType),
				granted = false,
				reason = "Unknown reward type",
			}
		end

		table.insert(grantedRewards, rewardResult)
	end

	return grantedRewards, syncData
end

--============================================================================
-- MISSION EVALUATION
--============================================================================

local function buildProgress(profile, mission)
	local progressCfg = mission.progress
	if type(progressCfg) ~= "table" then
		return nil
	end

	local target = tonumber(progressCfg.target) or 1
	local rawCurrent = readPath(profile, progressCfg.path)
	local current = 0

	if type(rawCurrent) == "number" then
		current = rawCurrent
	elseif type(rawCurrent) == "boolean" then
		current = if rawCurrent then 1 else 0
	end

	local percent
	if target <= 0 then
		percent = 1
	else
		percent = math.clamp(current / target, 0, 1)
	end

	return {
		current = current,
		target = target,
		percent = percent,
	}
end

local function buildClientState(profile)
	local missions = {}

	for index, mission in ipairs(MissionConfig.MISSIONS) do
		local completedAt = profile.completed[mission.id]
		local completed = completedAt ~= nil
		local unlocked = completed or requirementsMet(profile, mission)

		table.insert(missions, {
			id = mission.id,
			title = mission.title,
			description = mission.description,
			order = index,
			unlocked = unlocked,
			completed = completed,
			completedAt = completedAt,
			rewards = mission.rewards or {},
			progress = buildProgress(profile, mission),
		})
	end

	return {
		version = MissionConfig.VERSION,
		missions = missions,
		stats = profile.stats,
	}
end

local function evaluateMissions(userId, profile)
	local completions = {}
	local syncData = {}

	for _, mission in ipairs(MissionConfig.MISSIONS) do
		if not profile.completed[mission.id] then
			if requirementsMet(profile, mission) and evaluateCondition(mission.condition, profile) then
				profile.completed[mission.id] = os.time()

				local grantedRewards, rewardSync = grantRewards(userId, mission)
				mergeSyncData(syncData, rewardSync)

				table.insert(completions, {
					missionId = mission.id,
					title = mission.title,
					description = mission.description,
					rewards = grantedRewards,
				})
			end
		end
	end

	return completions, syncData
end

local function fireStateUpdated(player, profile, newlyCompleted, syncData)
	if not stateUpdatedRemote then
		return
	end

	stateUpdatedRemote:FireClient(player, {
		state = buildClientState(profile),
		newlyCompleted = newlyCompleted or {},
		sync = syncData or {},
	})
end

local function processEvent(player, eventName, payload, source)
	if type(eventName) ~= "string" then
		return
	end

	local eventDef = MissionConfig.getEvent(eventName)
	if not eventDef then
		return
	end

	local allowedSource = eventDef.source or "any"
	if allowedSource ~= "any" and allowedSource ~= source then
		return
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	local userId = player.UserId
	local profile = loadProfile(userId)
	local safePayload = if type(payload) == "table" then payload else {}

	if not passesCooldown(userId, eventName, eventDef) then
		return
	end

	if not passesRunGate(userId, eventDef) then
		return
	end

	local changed = false
	for _, update in ipairs(eventDef.updates or {}) do
		if applyUpdate(profile, update, safePayload) then
			changed = true
		end
	end

	local newlyCompleted, syncData = evaluateMissions(userId, profile)
	if changed or #newlyCompleted > 0 then
		markProfileDirty(userId)
	end

	if #newlyCompleted > 0 then
		queueCompletionSave(userId)
	end

	if changed or #newlyCompleted > 0 then
		fireStateUpdated(player, profile, newlyCompleted, syncData)
	end
end

--============================================================================
-- PUBLIC API
--============================================================================

--[[
	Injects service dependencies used for rewards.
	@param deps table? { currencyService = module, shopService = module }
]]
function MissionService.setDependencies(deps)
	if type(deps) ~= "table" then
		return
	end
	currencyService = deps.currencyService or currencyService
	shopService = deps.shopService or shopService
end

--[[
	Reports a trusted server event into the mission pipeline.
	Used by server services (leaderboard/currency/shop).
]]
function MissionService.reportServerEvent(player, eventName, payload)
	if not initialized then
		return
	end
	processEvent(player, eventName, payload, "server")
end

function MissionService.init(deps)
	if initialized then
		MissionService.setDependencies(deps)
		return
	end
	initialized = true
	MissionService.setDependencies(deps)

	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	getStateRemote = remoteFolder:FindFirstChild(MissionConfig.REMOTES.GET_STATE)
	if not getStateRemote then
		getStateRemote = Instance.new("RemoteFunction")
		getStateRemote.Name = MissionConfig.REMOTES.GET_STATE
		getStateRemote.Parent = remoteFolder
	end

	reportEventRemote = remoteFolder:FindFirstChild(MissionConfig.REMOTES.REPORT_EVENT)
	if not reportEventRemote then
		reportEventRemote = Instance.new("RemoteEvent")
		reportEventRemote.Name = MissionConfig.REMOTES.REPORT_EVENT
		reportEventRemote.Parent = remoteFolder
	end

	stateUpdatedRemote = remoteFolder:FindFirstChild(MissionConfig.REMOTES.STATE_UPDATED)
	if not stateUpdatedRemote then
		stateUpdatedRemote = Instance.new("RemoteEvent")
		stateUpdatedRemote.Name = MissionConfig.REMOTES.STATE_UPDATED
		stateUpdatedRemote.Parent = remoteFolder
	end

	getStateRemote.OnServerInvoke = function(player)
		local profile = loadProfile(player.UserId)
		local newlyCompleted, syncData = evaluateMissions(player.UserId, profile)
		if #newlyCompleted > 0 then
			markProfileDirty(player.UserId)
			queueCompletionSave(player.UserId)
		end
		return {
			state = buildClientState(profile),
			newlyCompleted = newlyCompleted,
			sync = syncData,
		}
	end

	reportEventRemote.OnServerEvent:Connect(function(player, eventName, payload)
		processEvent(player, eventName, payload, "client")
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			loadProfile(player.UserId)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		saveProfileOnExit(userId)
		cachedProfiles[userId] = nil
		dirtyProfiles[userId] = nil
		eventCooldowns[userId] = nil
		runActiveByUser[userId] = nil
		queuedCompletionSaves[userId] = nil
		queuedCompletionSaveTokens[userId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			loadProfile(player.UserId)
		end)
	end

	task.spawn(function()
		while true do
			task.wait(MissionConfig.AUTOSAVE_INTERVAL)
			for userId in pairs(dirtyProfiles) do
				saveProfile(userId, false)
				task.wait(MissionConfig.AUTOSAVE_SPREAD_DELAY or 0)
			end
		end
	end)

	game:BindToClose(function()
		for userId in pairs(cachedProfiles) do
			saveProfileOnExit(userId)
		end
	end)
end

return MissionService
