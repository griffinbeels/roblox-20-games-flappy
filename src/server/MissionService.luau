--[[
	MissionService.luau

	Server-authoritative mission progression system:
	- Persists mission stats + completion state per player
	- Accepts tracked events (client + server)
	- Evaluates mission conditions from MissionConfig
	- Grants rewards (bacon + shop items) on explicit redeem
	- Pushes mission state/completion updates to clients
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local ConditionEvaluator = require(ReplicatedStorage.Shared.ConditionEvaluator)
local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)

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
local prestigeService = nil

-- Remotes
local getStateRemote = nil
local reportEventRemote = nil
local stateUpdatedRemote = nil
local redeemMissionRemote = nil

local initialized = false
local scoreThresholdTrackers = {}
if type(MissionConfig.getScoreThresholdTrackers) == "function" then
	scoreThresholdTrackers = MissionConfig.getScoreThresholdTrackers() or {}
end

--============================================================================
-- PROFILE SHAPE
--============================================================================

local function createDefaultProfile()
	return {
		version = MissionConfig.VERSION,
		stats = {},
		flags = {},
		completed = {}, -- [missionId] = unix timestamp (condition satisfied)
		redeemed = {}, -- [missionId] = unix timestamp (reward claimed)
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

local function copySpeedGraduationMap(source)
	local output = {}
	if type(source) ~= "table" then
		return output
	end

	for key, value in pairs(source) do
		if type(key) == "string" and string.match(key, "^p%d+$") then
			local num = tonumber(value)
			if num ~= nil then
				output[key] = math.clamp(math.floor(num), 0, MissionConfig.MAX_TRACKED_SCORE)
			end
		end
	end

	return output
end

local function copyMissionStatsMap(source)
	local output = copyPrimitiveMap(source)
	if type(source) ~= "table" then
		return output
	end

	if type(source.speed_graduation_by_level) == "table" then
		output.speed_graduation_by_level = copySpeedGraduationMap(source.speed_graduation_by_level)
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
	profile.stats = copyMissionStatsMap(raw.stats)
	profile.flags = copyPrimitiveMap(raw.flags)
	profile.completed = copyCompletedMap(raw.completed)
	if type(raw.redeemed) == "table" then
		profile.redeemed = copyCompletedMap(raw.redeemed)
	else
		-- Migration: before VERSION 2, completed missions were auto-rewarded.
		profile.redeemed = copyCompletedMap(raw.completed)
	end

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
		redeemed = profile.redeemed,
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

local function getCurrentPrestigeLevel(userId)
	if not prestigeService or type(prestigeService.getCurrentLevel) ~= "function" then
		return 0
	end

	local ok, level = pcall(prestigeService.getCurrentLevel, userId)
	if not ok then
		return 0
	end

	return math.max(0, math.floor(tonumber(level) or 0))
end

local function getDynamicPrestigeMissions(userId)
	if PrestigeConfig.ENABLED ~= true then
		return {}
	end

	local currentPrestigeLevel = getCurrentPrestigeLevel(userId)
	if type(PrestigeConfig.getNextPrestigeMissions) == "function" then
		local missions = PrestigeConfig.getNextPrestigeMissions(currentPrestigeLevel)
		if type(missions) == "table" then
			return missions
		end
	end

	local mission = PrestigeConfig.getNextPrestigeMission(currentPrestigeLevel)
	if mission then
		return { mission }
	end

	return {}
end

local function getMissionDefsForUser(userId)
	local missionDefs = {}

	for _, mission in ipairs(MissionConfig.MISSIONS) do
		table.insert(missionDefs, mission)
	end

	for _, prestigeMission in ipairs(getDynamicPrestigeMissions(userId)) do
		table.insert(missionDefs, prestigeMission)
	end

	return missionDefs
end

local function findMissionDefForUser(userId, missionId)
	if type(missionId) ~= "string" or missionId == "" then
		return nil
	end

	for _, mission in ipairs(getMissionDefsForUser(userId)) do
		if mission.id == missionId then
			return mission
		end
	end

	return nil
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

local function updateMaxAtPath(profile, path, value)
	if type(path) ~= "string" or path == "" then
		return false
	end

	local parent, key = resolveParent(profile, path, true)
	if not parent or not key then
		return false
	end

	local currentValue = tonumber(parent[key]) or 0
	if value > currentValue then
		parent[key] = value
		return true
	end

	return false
end

local function applyScoreThresholdTrackers(profile, payload)
	if #scoreThresholdTrackers <= 0 then
		return false
	end

	local rawScore = tonumber(payload and payload.score)
	if not rawScore then
		return false
	end

	local safeScore = math.clamp(math.floor(rawScore), 0, MissionConfig.MAX_TRACKED_SCORE)
	local changed = false

	for _, tracker in ipairs(scoreThresholdTrackers) do
		if type(tracker) == "table" then
			local metricField = tostring(tracker.metricField or "")
			local metricValue = tonumber(payload[metricField])
			local thresholdValue = tonumber(tracker.thresholdValue) or 0
			local path = tostring(tracker.path or "")

			if metricValue and metricValue >= thresholdValue and path ~= "" then
				if updateMaxAtPath(profile, path, safeScore) then
					changed = true
				end
			end
		end
	end

	return changed
end

local function getEffectivePrestigeTrackingThresholds()
	if type(PrestigeConfig.getEffectiveTrackingThresholds) == "function" then
		local ok, thresholds = pcall(PrestigeConfig.getEffectiveTrackingThresholds)
		if ok and type(thresholds) == "table" then
			return thresholds
		end
	end

	local tracking = PrestigeConfig.TRACKING or {}
	return {
		speedCapMultiplier = tonumber(tracking.SPEED_THRESHOLD) or 0,
		gravity = tonumber(tracking.GRAVITY_THRESHOLD) or 0,
	}
end

local function applyPrestigeMissionTrackers(userId, profile, payload)
	if PrestigeConfig.ENABLED ~= true then
		return false
	end
	if type(profile) ~= "table" or type(profile.stats) ~= "table" then
		return false
	end

	local rawScore = tonumber(payload and payload.score)
	if rawScore == nil then
		return false
	end

	local safeScore = math.clamp(math.floor(rawScore), 0, MissionConfig.MAX_TRACKED_SCORE)
	local changed = false

	local thresholds = getEffectivePrestigeTrackingThresholds()
	local gravityThreshold = tonumber(thresholds.gravity) or math.huge
	local selectedGravity = tonumber(payload and payload.gravity) or 0
	if selectedGravity >= gravityThreshold then
		if updateMaxAtPath(profile, "stats.best_score_at_gravity_threshold", safeScore) then
			changed = true
		end
	end

	local currentPrestigeLevel = getCurrentPrestigeLevel(userId)
	local targetPrestigeLevel = math.max(1, currentPrestigeLevel + 1)
	local requiredCap = if type(PrestigeConfig.getSpeedGraduationTargetForLevel) == "function"
		then tonumber(PrestigeConfig.getSpeedGraduationTargetForLevel(targetPrestigeLevel))
		else nil
	if requiredCap == nil then
		return changed
	end

	local tolerance = if type(PrestigeConfig.getSpeedGraduationToleranceForLevel) == "function"
		then tonumber(PrestigeConfig.getSpeedGraduationToleranceForLevel(targetPrestigeLevel))
		else nil
	tolerance = math.max(0.01, tonumber(tolerance) or 0.01)

	local selectedCap = tonumber(payload and payload.speedCapMultiplier) or 0
	if selectedCap + 0.0001 < (requiredCap - tolerance) then
		return changed
	end

	local reachedSpeed = tonumber(payload and payload.maxSpeedMultiplierReached)
	if reachedSpeed == nil then
		-- Compatibility fallback for older clients that do not send peak speed.
		reachedSpeed = selectedCap
	end
	reachedSpeed = math.min(reachedSpeed, selectedCap)
	if reachedSpeed + 0.0001 < (requiredCap - tolerance) then
		return changed
	end

	local statPath = nil
	if type(PrestigeConfig.getSpeedGraduationStatPathForTargetLevel) == "function" then
		statPath = PrestigeConfig.getSpeedGraduationStatPathForTargetLevel(targetPrestigeLevel)
	end
	if type(statPath) ~= "string" or statPath == "" then
		local statKey = if type(PrestigeConfig.getSpeedGraduationStatKeyForCurrentLevel) == "function"
			then PrestigeConfig.getSpeedGraduationStatKeyForCurrentLevel(currentPrestigeLevel)
			else ("p" .. tostring(currentPrestigeLevel))
		statPath = string.format("stats.speed_graduation_by_level.%s", tostring(statKey))
	end

	if updateMaxAtPath(profile, statPath, safeScore) then
		changed = true
	end

	return changed
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
	if eventDef.requiresRunActive and not runActiveByUser[userId] then
		return false
	end
	if eventDef.requiresRunInactive and runActiveByUser[userId] then
		return false
	end

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

local function grantShopUnlockReward(_userId, reward, _syncData)
	local itemId = reward.itemId
	if type(itemId) ~= "string" or itemId == "" then
		return {
			type = "shop_unlock",
			itemId = tostring(itemId),
			granted = false,
			reason = "Invalid item ID",
		}
	end

	-- Unlock missions gate purchase eligibility; they do not grant ownership.
	return {
		type = "shop_unlock",
		itemId = itemId,
		granted = true,
	}
end

local function grantPrestigeLevelReward(_userId, reward, _syncData)
	local level = math.max(1, math.floor(tonumber(reward.level) or 1))
	return {
		type = "prestige_level",
		level = level,
		granted = true,
		displayOnly = true,
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
		elseif rewardType == "shop_unlock" then
			rewardResult = grantShopUnlockReward(userId, reward, syncData)
		elseif rewardType == "prestige_level" then
			rewardResult = grantPrestigeLevelReward(userId, reward, syncData)
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

	if #progressCfg > 0 then
		local rows = {}
		local minPercent = 1
		local completedObjectives = 0

		for _, rowCfg in ipairs(progressCfg) do
			if type(rowCfg) == "table" and type(rowCfg.path) == "string" then
				local target = tonumber(rowCfg.target) or 1
				local rawCurrent = readPath(profile, rowCfg.path)
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

				if percent >= 1 then
					completedObjectives += 1
				end
				minPercent = math.min(minPercent, percent)

				table.insert(rows, {
					label = rowCfg.label or rowCfg.path,
					current = current,
					target = target,
					percent = percent,
				})
			end
		end

		if #rows == 0 then
			return nil
		end

		return {
			current = completedObjectives,
			target = #rows,
			percent = minPercent,
			rows = rows,
		}
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

local function buildClientState(profile, userId)
	local missions = {}
	local order = 0

	for _, mission in ipairs(getMissionDefsForUser(userId)) do
		order += 1
		local completedAt = profile.completed[mission.id]
		local completed = completedAt ~= nil
		local redeemedAt = profile.redeemed[mission.id]
		local redeemed = redeemedAt ~= nil
		local unlocked = completed or requirementsMet(profile, mission)

		table.insert(missions, {
			id = mission.id,
			title = mission.title,
			description = mission.description,
			order = order,
			unlocked = unlocked,
			completed = completed,
			completedAt = completedAt,
			redeemed = redeemed,
			redeemedAt = redeemedAt,
			canRedeem = completed and not redeemed,
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

	for _, mission in ipairs(getMissionDefsForUser(userId)) do
		if not profile.completed[mission.id] then
			if requirementsMet(profile, mission) and ConditionEvaluator.evaluate(mission.condition, profile) then
				profile.completed[mission.id] = os.time()

				table.insert(completions, {
					missionId = mission.id,
					title = mission.title,
					description = mission.description,
					rewards = mission.rewards or {},
					redeemRequired = true,
				})
			end
		end
	end

	return completions, {}
end

local function fireStateUpdated(player, profile, newlyCompleted, syncData)
	if not stateUpdatedRemote then
		return
	end

	stateUpdatedRemote:FireClient(player, {
		state = buildClientState(profile, player.UserId),
		newlyCompleted = newlyCompleted or {},
		sync = syncData or {},
	})
end

local function buildRedeemResponse(player, profile, success, reason, newlyCompleted, syncData, redeemedPayload)
	return {
		success = success == true,
		reason = reason,
		state = buildClientState(profile, player.UserId),
		newlyCompleted = newlyCompleted or {},
		sync = syncData or {},
		redeemed = redeemedPayload,
	}
end

local function isPrestigeReward(reward)
	return type(reward) == "table" and reward.type == "prestige_level"
end

local function isPrestigeProgressionMission(mission)
	if type(mission) ~= "table" then
		return false
	end

	for _, reward in ipairs(mission.rewards or {}) do
		if isPrestigeReward(reward) then
			return true
		end
	end

	return false
end

local function redeemMission(player, missionId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return {
			success = false,
			reason = "Invalid player",
		}
	end

	if type(missionId) ~= "string" or missionId == "" then
		return {
			success = false,
			reason = "Invalid mission",
		}
	end

	local userId = player.UserId
	local profile = loadProfile(userId)
	local newlyCompleted, completionSync = evaluateMissions(userId, profile)
	local syncData = {}
	mergeSyncData(syncData, completionSync)

	if #newlyCompleted > 0 then
		markProfileDirty(userId)
		queueCompletionSave(userId)
	end

	local mission = findMissionDefForUser(userId, missionId)
	if not mission then
		return buildRedeemResponse(player, profile, false, "Mission unavailable", newlyCompleted, syncData, nil)
	end

	if not profile.completed[missionId] then
		return buildRedeemResponse(player, profile, false, "Mission not complete", newlyCompleted, syncData, nil)
	end

	if profile.redeemed[missionId] then
		return buildRedeemResponse(player, profile, false, "Already redeemed", newlyCompleted, syncData, nil)
	end

	local grantedRewards, rewardSync = grantRewards(userId, mission)
	mergeSyncData(syncData, rewardSync)

	profile.redeemed[missionId] = os.time()
	markProfileDirty(userId)
	queueCompletionSave(userId)

	return buildRedeemResponse(player, profile, true, nil, newlyCompleted, syncData, {
		missionId = mission.id,
		title = mission.title,
		description = mission.description,
		rewards = grantedRewards,
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

	if eventName == "score_progress" or eventName == "run_finished" then
		if applyScoreThresholdTrackers(profile, safePayload) then
			changed = true
		end
	end

	if eventName == "run_finished" then
		if applyPrestigeMissionTrackers(userId, profile, safePayload) then
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
	@param deps table? { currencyService = module, shopService = module, prestigeService = module }
]]
function MissionService.setDependencies(deps)
	if type(deps) ~= "table" then
		return
	end
	currencyService = deps.currencyService or currencyService
	shopService = deps.shopService or shopService
	prestigeService = deps.prestigeService or prestigeService
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

--[[
	Forces a mission state push to the client using the latest dynamic mission set.
	Used after prestige level changes so the prestige mission list swaps to the new tier
	immediately instead of showing stale completed missions from the previous tier.
]]
function MissionService.refreshStateForPlayer(player)
	if not initialized then
		return false, "Not initialized"
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Invalid player"
	end

	local userId = player.UserId
	local profile = loadProfile(userId)
	fireStateUpdated(player, profile, {}, {})
	return true
end

--[[
	Marks the currently-active prestige missions as completed + redeemed.
	Called when the player successfully clicks Prestige in PrestigeUI.
	This intentionally happens outside the Missions UI redeem flow.
]]
function MissionService.completeCurrentPrestigeMissionsForPlayer(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Invalid player"
	end

	local userId = player.UserId
	local profile = loadProfile(userId)
	local syncData = {}
	local changed = false

	for _, mission in ipairs(getDynamicPrestigeMissions(userId)) do
		if isPrestigeProgressionMission(mission) then
			if not profile.completed[mission.id] then
				profile.completed[mission.id] = os.time()
				changed = true
			end

			if not profile.redeemed[mission.id] then
				local _, rewardSync = grantRewards(userId, mission)
				mergeSyncData(syncData, rewardSync)
				profile.redeemed[mission.id] = os.time()
				changed = true

				-- Prestige missions route through PrestigeUI and are auto-completed
				-- on prestige click. Rewards (currently display-only prestige_level
				-- + optional future extras) are still granted server-side above.
			end
		end
	end

	if not changed then
		return true
	end

	markProfileDirty(userId)
	queueCompletionSave(userId)
	fireStateUpdated(player, profile, {}, syncData)

	return true
end

--[[
	Returns whether a mission reward has been redeemed for the given user.
	Used by ShopService for mission-gated purchase validation.
]]
function MissionService.isMissionCompleted(userId, missionId)
	if type(userId) ~= "number" or type(missionId) ~= "string" then
		return false
	end

	local profile = loadProfile(userId)
	if type(profile) ~= "table" or type(profile.redeemed) ~= "table" then
		return false
	end

	return profile.redeemed[missionId] ~= nil
end

--[[
	Debug-only helper: resets a player's mission profile (stats/flags/completions).
	@param playerOrUserId Player|number
	@return boolean success, string? err
]]
function MissionService.debugResetPlayer(playerOrUserId)
	local userId = nil
	local player = nil
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		player = playerOrUserId
		userId = player.UserId
	else
		userId = tonumber(playerOrUserId)
		if userId then
			player = Players:GetPlayerByUserId(userId)
		end
	end

	if not userId then
		return false, "Invalid player/userId"
	end

	cancelQueuedCompletionSave(userId)
	local profile = createDefaultProfile()
	cachedProfiles[userId] = profile
	dirtyProfiles[userId] = nil
	eventCooldowns[userId] = nil
	runActiveByUser[userId] = false
	queuedCompletionSaves[userId] = nil
	queuedCompletionSaveTokens[userId] = nil
	exitSaveStarted[userId] = nil

	if dataStoreAvailable and missionDataStore then
		local ok, err = pcall(function()
			missionDataStore:RemoveAsync(profileKeyForUser(userId))
		end)
		if not ok then
			warn("[MissionService] Failed to reset mission data for user " .. userId .. ": " .. tostring(err))
			return false, tostring(err)
		end
	end

	if player then
		fireStateUpdated(player, profile, {}, {})
	end

	return true
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

	redeemMissionRemote = remoteFolder:FindFirstChild(MissionConfig.REMOTES.REDEEM)
	if not redeemMissionRemote then
		redeemMissionRemote = Instance.new("RemoteFunction")
		redeemMissionRemote.Name = MissionConfig.REMOTES.REDEEM
		redeemMissionRemote.Parent = remoteFolder
	end

	getStateRemote.OnServerInvoke = function(player)
		local profile = loadProfile(player.UserId)
		local newlyCompleted, syncData = evaluateMissions(player.UserId, profile)
		if #newlyCompleted > 0 then
			markProfileDirty(player.UserId)
			queueCompletionSave(player.UserId)
		end
		return {
			state = buildClientState(profile, player.UserId),
			newlyCompleted = newlyCompleted,
			sync = syncData,
		}
	end

	reportEventRemote.OnServerEvent:Connect(function(player, eventName, payload)
		processEvent(player, eventName, payload, "client")
	end)

	redeemMissionRemote.OnServerInvoke = function(player, missionId)
		return redeemMission(player, missionId)
	end

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
