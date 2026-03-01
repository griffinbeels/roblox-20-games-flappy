--[[
	PrestigeService.luau

	Server-authoritative prestige progression:
	- Persists prestige progression, selected tuning, and tracked stats
	- Tracks run outcomes for unlock requirements
	- Validates tuning and prestige attempts server-side
	- Pushes canonical state updates to clients
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PrestigeConfig = require(ReplicatedStorage.Shared.PrestigeConfig)
local ConditionEvaluator = require(ReplicatedStorage.Shared.ConditionEvaluator)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)

local PrestigeService = {}

local prestigeDataStore = nil
local dataStoreAvailable = false

local initOk, _ = pcall(function()
	prestigeDataStore = DataStoreService:GetDataStore(PrestigeConfig.DATASTORE_NAME)
	dataStoreAvailable = true
end)
if not dataStoreAvailable then
	warn("[PrestigeService] DataStore not available - prestige state persists in-memory only (Studio mode).")
end

local cachedProfiles = {} -- userId -> profile
local dirtyProfiles = {} -- userId -> true
local runStateByUser = {} -- userId -> { active = bool, tuning = table?, startedAt = number? }
local exitSaveStarted = {} -- userId -> true

local initialized = false
local missionService = nil

local getStateRemote = nil
local stateUpdatedRemote = nil
local reportRunRemote = nil
local attemptPrestigeRemote = nil
local setTuningRemote = nil

function PrestigeService.setDependencies(deps)
	if type(deps) ~= "table" then
		return
	end
	missionService = deps.missionService or missionService
end

local TRACKING = PrestigeConfig.TRACKING or {}
local EFFECTIVE_TRACKING = if type(PrestigeConfig.getEffectiveTrackingThresholds) == "function"
	then PrestigeConfig.getEffectiveTrackingThresholds()
	else {
		speedCapMultiplier = tonumber(TRACKING.SPEED_THRESHOLD) or 0,
		gravity = tonumber(TRACKING.GRAVITY_THRESHOLD) or 0,
	}

local function getPrestigeClampMax()
	local configuredMax = PrestigeConfig.getMaxPrestigeLevel()
	if type(configuredMax) == "number" then
		return math.max(0, math.floor(configuredMax))
	end

	local softMax = tonumber(PrestigeConfig.SOFT_MAX_PRESTIGE_LEVEL) or 1000000
	return math.max(0, math.floor(softMax))
end

local function normalizePrestigeLevel(level)
	local parsed = math.floor(tonumber(level) or 0)
	return math.clamp(parsed, 0, getPrestigeClampMax())
end

local function createDefaultStats()
	return {
		total_runs = 0,
		best_score = 0,
		best_score_at_speed_threshold = 0,
		best_score_at_gravity_threshold = 0,
		speed_graduation_by_level = {},
		last_score = 0,
	}
end

local function createDefaultProfile()
	local tuning = RuntimeTuning.getDefaultTuning()
	return {
		version = PrestigeConfig.VERSION,
		progression = {
			level = 0,
			lastPrestigeAt = nil,
		},
		tuning = {
			selected = tuning,
		},
		stats = createDefaultStats(),
	}
end

local function copyNumberField(value, fallback, minValue, maxValue)
	local numberValue = tonumber(value)
	if not numberValue then
		return fallback
	end

	if minValue ~= nil then
		numberValue = math.max(minValue, numberValue)
	end
	if maxValue ~= nil then
		numberValue = math.min(maxValue, numberValue)
	end

	return numberValue
end

local function sanitizeStats(rawStats)
	local defaults = createDefaultStats()
	if type(rawStats) ~= "table" then
		return defaults
	end

	local maxScore = tonumber(TRACKING.MAX_ACCEPTED_SCORE) or 10000
	local maxRuns = tonumber(TRACKING.MAX_ACCEPTED_RUNS) or 200000

	local function sanitizeSpeedGraduationByLevel(rawBuckets)
		local output = {}
		if type(rawBuckets) ~= "table" then
			return output
		end

		for key, value in pairs(rawBuckets) do
			if type(key) == "string" and string.match(key, "^p%d+$") then
				output[key] = math.floor(copyNumberField(value, 0, 0, maxScore))
			end
		end

		return output
	end

	defaults.total_runs = math.floor(copyNumberField(rawStats.total_runs, defaults.total_runs, 0, maxRuns))
	defaults.best_score = math.floor(copyNumberField(rawStats.best_score, defaults.best_score, 0, maxScore))
	defaults.best_score_at_speed_threshold = math.floor(copyNumberField(rawStats.best_score_at_speed_threshold, defaults.best_score_at_speed_threshold, 0, maxScore))
	defaults.best_score_at_gravity_threshold = math.floor(copyNumberField(rawStats.best_score_at_gravity_threshold, defaults.best_score_at_gravity_threshold, 0, maxScore))
	defaults.speed_graduation_by_level = sanitizeSpeedGraduationByLevel(rawStats.speed_graduation_by_level)
	defaults.last_score = math.floor(copyNumberField(rawStats.last_score, defaults.last_score, 0, maxScore))

	return defaults
end

local function sanitizeProfile(rawProfile)
	local profile = createDefaultProfile()
	if type(rawProfile) ~= "table" then
		return profile
	end

	if type(rawProfile.version) == "number" then
		profile.version = rawProfile.version
	end

	local rawProgression = rawProfile.progression
	if type(rawProgression) == "table" then
		profile.progression.level = normalizePrestigeLevel(rawProgression.level)
		if type(rawProgression.lastPrestigeAt) == "number" then
			profile.progression.lastPrestigeAt = rawProgression.lastPrestigeAt
		end
	end

	profile.stats = sanitizeStats(rawProfile.stats)

	local limits = PrestigeConfig.getTuningBand(profile.progression.level)
	local rawSelected = nil
	if type(rawProfile.tuning) == "table" then
		rawSelected = rawProfile.tuning.selected or rawProfile.tuning
	elseif type(rawProfile.selectedTuning) == "table" then
		rawSelected = rawProfile.selectedTuning
	end
	profile.tuning.selected = RuntimeTuning.clampTuning(rawSelected, limits)

	return profile
end

local function profileKeyForUser(userId)
	return "user_" .. userId
end

local function markDirty(userId)
	dirtyProfiles[userId] = true
end

local function loadProfile(userId)
	if cachedProfiles[userId] then
		return cachedProfiles[userId]
	end

	exitSaveStarted[userId] = nil

	local profile = createDefaultProfile()
	if dataStoreAvailable and prestigeDataStore then
		local ok, stored = pcall(function()
			return prestigeDataStore:GetAsync(profileKeyForUser(userId))
		end)
		if ok and stored then
			profile = sanitizeProfile(stored)
		end
	end

	cachedProfiles[userId] = profile
	if not runStateByUser[userId] then
		runStateByUser[userId] = { active = false, tuning = nil, startedAt = nil }
	end

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

	if not dataStoreAvailable or not prestigeDataStore then
		dirtyProfiles[userId] = nil
		return true
	end

	local payload = {
		version = PrestigeConfig.VERSION,
		progression = {
			level = profile.progression.level,
			lastPrestigeAt = profile.progression.lastPrestigeAt,
		},
		tuning = {
			selected = RuntimeTuning.cloneTuning(profile.tuning.selected),
		},
		stats = profile.stats,
	}

	local ok, err = pcall(function()
		prestigeDataStore:SetAsync(profileKeyForUser(userId), payload)
	end)

	if ok then
		dirtyProfiles[userId] = nil
		return true
	end

	warn("[PrestigeService] Failed to save prestige state for user " .. userId .. ": " .. tostring(err))
	dirtyProfiles[userId] = true
	return false
end

local function saveOnExit(userId)
	if exitSaveStarted[userId] then
		return true
	end
	exitSaveStarted[userId] = true
	return saveProfile(userId, false)
end

local function getProgressRows(profile, levelDef)
	local rows = {}
	for _, progressDef in ipairs(levelDef.progress or {}) do
		local label = tostring(progressDef.label or "Requirement")
		local target = tonumber(progressDef.target) or 1
		local rawCurrent = ConditionEvaluator.readPath(profile, progressDef.path)
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

		table.insert(rows, {
			label = label,
			current = current,
			target = target,
			percent = percent,
		})
	end

	return rows
end

local function buildClientState(profile, userId)
	local level = normalizePrestigeLevel(profile.progression.level)
	local configuredMaxLevel = PrestigeConfig.getMaxPrestigeLevel()
	local isUnbounded = configuredMaxLevel == nil
	local limits = PrestigeConfig.getTuningBand(level)
	local selected = RuntimeTuning.clampTuning(profile.tuning.selected, limits)
	local recommended = RuntimeTuning.getRecommendedTuning(limits)

	local nextLevelNumber = level + 1
	local nextLevelDef = PrestigeConfig.getLevel(nextLevelNumber)
	local nextLevel = nil
	if nextLevelDef then
		local speedGraduationTarget = if type(PrestigeConfig.getSpeedGraduationTargetForLevel) == "function"
			then tonumber(PrestigeConfig.getSpeedGraduationTargetForLevel(nextLevelNumber))
			else nil
		local speedGraduationTolerance = if type(PrestigeConfig.getSpeedGraduationToleranceForLevel) == "function"
			then tonumber(PrestigeConfig.getSpeedGraduationToleranceForLevel(nextLevelNumber))
			else nil
		nextLevel = {
			level = nextLevelNumber,
			id = nextLevelDef.id,
			title = nextLevelDef.title,
			requirementText = nextLevelDef.requirementText,
			rationale = nextLevelDef.rationale,
			unlocked = ConditionEvaluator.evaluate(nextLevelDef.condition, profile),
			progress = getProgressRows(profile, nextLevelDef),
			speedGraduation = {
				currentPrestigeLevel = math.max(0, nextLevelNumber - 1),
				speedCapTarget = speedGraduationTarget,
				tolerance = speedGraduationTolerance,
			},
		}
	end

	local runState = runStateByUser[userId]

	return {
		version = PrestigeConfig.VERSION,
		progression = {
			level = level,
			maxLevel = configuredMaxLevel,
			isUnbounded = isUnbounded,
			lastPrestigeAt = profile.progression.lastPrestigeAt,
		},
		stats = profile.stats,
		tuning = {
			defaults = RuntimeTuning.getDefaultTuning(),
			limits = limits,
			selected = selected,
			recommended = recommended,
		},
		trackingThresholds = {
			speedCapMultiplier = tonumber(EFFECTIVE_TRACKING.speedCapMultiplier) or 0,
			gravity = tonumber(EFFECTIVE_TRACKING.gravity) or 0,
		},
		nextLevel = nextLevel,
		isRunActive = runState and runState.active or false,
	}
end

local function pushState(player, profile, context)
	if not stateUpdatedRemote then
		return
	end

	stateUpdatedRemote:FireClient(player, {
		state = buildClientState(profile, player.UserId),
		context = context,
	})
end

local function sanitizeIncomingScore(score)
	local parsed = math.floor(tonumber(score) or 0)
	local maxScore = tonumber(TRACKING.MAX_ACCEPTED_SCORE) or 10000
	return math.clamp(parsed, 0, maxScore)
end

local function incrementTotalRuns(stats)
	local maxRuns = tonumber(TRACKING.MAX_ACCEPTED_RUNS) or 200000
	stats.total_runs = math.clamp((tonumber(stats.total_runs) or 0) + 1, 0, maxRuns)
end

local function sanitizeIncomingMaxSpeedMultiplier(value)
	local parsed = tonumber(value)
	if parsed == nil then
		return nil
	end
	return math.clamp(parsed, 0, 100)
end

local function ensureSpeedGraduationBuckets(stats)
	if type(stats.speed_graduation_by_level) ~= "table" then
		stats.speed_graduation_by_level = {}
	end
	return stats.speed_graduation_by_level
end

local function tryRecordSpeedGraduationScore(profile, runState, safeScore, runMetrics)
	if type(profile) ~= "table" or type(profile.stats) ~= "table" then
		return
	end
	if type(runState) ~= "table" then
		return
	end

	local runLevel = normalizePrestigeLevel(runState.prestigeLevel)
	local statKey = nil
	if type(PrestigeConfig.getSpeedGraduationStatKeyForCurrentLevel) == "function" then
		statKey = PrestigeConfig.getSpeedGraduationStatKeyForCurrentLevel(runLevel)
	end
	if type(statKey) ~= "string" or statKey == "" then
		return
	end

	local requiredCap = tonumber(runState.speedGraduationTarget)
	if requiredCap == nil and type(PrestigeConfig.getSpeedGraduationTargetForLevel) == "function" then
		requiredCap = tonumber(PrestigeConfig.getSpeedGraduationTargetForLevel(runLevel + 1))
	end
	if requiredCap == nil then
		return
	end

	local tolerance = tonumber(runState.speedGraduationCapTolerance)
	if tolerance == nil and type(PrestigeConfig.getSpeedGraduationToleranceForLevel) == "function" then
		tolerance = tonumber(PrestigeConfig.getSpeedGraduationToleranceForLevel(runLevel + 1))
	end
	tolerance = math.max(0.01, tonumber(tolerance) or 0.01)

	local runTuning = runState.tuning
	local selectedCap = tonumber(runTuning and runTuning.speedCapMultiplier) or 0
	if selectedCap + 0.0001 < (requiredCap - tolerance) then
		return
	end

	local reachedSpeed = sanitizeIncomingMaxSpeedMultiplier(runMetrics and runMetrics.maxSpeedMultiplierReached)
	if reachedSpeed == nil then
		-- Backward-compatible fallback for older clients that do not report peak speed yet.
		reachedSpeed = selectedCap
	end
	reachedSpeed = math.min(reachedSpeed, selectedCap)
	if reachedSpeed + 0.0001 < (requiredCap - tolerance) then
		return
	end

	local buckets = ensureSpeedGraduationBuckets(profile.stats)
	buckets[statKey] = math.max(tonumber(buckets[statKey]) or 0, safeScore)
end

local function applyRunResult(profile, runState, score, runMetrics)
	local stats = profile.stats
	local safeScore = sanitizeIncomingScore(score)
	local runTuning = type(runState) == "table" and runState.tuning or nil

	incrementTotalRuns(stats)
	stats.last_score = safeScore
	stats.best_score = math.max(tonumber(stats.best_score) or 0, safeScore)

	local speedThreshold = tonumber(EFFECTIVE_TRACKING.speedCapMultiplier) or math.huge
	local gravityThreshold = tonumber(EFFECTIVE_TRACKING.gravity) or math.huge

	if type(runTuning) == "table" and (tonumber(runTuning.speedCapMultiplier) or 0) >= speedThreshold then
		stats.best_score_at_speed_threshold = math.max(tonumber(stats.best_score_at_speed_threshold) or 0, safeScore)
	end

	if type(runTuning) == "table" and (tonumber(runTuning.gravity) or 0) >= gravityThreshold then
		stats.best_score_at_gravity_threshold = math.max(tonumber(stats.best_score_at_gravity_threshold) or 0, safeScore)
	end

	tryRecordSpeedGraduationScore(profile, runState, safeScore, runMetrics)
end

local function startRunForUser(userId)
	local profile = loadProfile(userId)
	local currentRunState = runStateByUser[userId]
	if currentRunState and currentRunState.active then
		return profile, false
	end

	local currentLevel = normalizePrestigeLevel(profile.progression.level)
	local limits = PrestigeConfig.getTuningBand(currentLevel)
	local selectedTuning = RuntimeTuning.clampTuning(profile.tuning.selected, limits)
	local targetLevel = currentLevel + 1
	local speedGraduationTarget = if type(PrestigeConfig.getSpeedGraduationTargetForLevel) == "function"
		then tonumber(PrestigeConfig.getSpeedGraduationTargetForLevel(targetLevel))
		else nil
	local speedGraduationCapTolerance = if type(PrestigeConfig.getSpeedGraduationToleranceForLevel) == "function"
		then tonumber(PrestigeConfig.getSpeedGraduationToleranceForLevel(targetLevel))
		else nil
	runStateByUser[userId] = {
		active = true,
		tuning = selectedTuning,
		prestigeLevel = currentLevel,
		targetPrestigeLevel = targetLevel,
		speedGraduationTarget = speedGraduationTarget,
		speedGraduationCapTolerance = speedGraduationCapTolerance,
		startedAt = tick(),
	}
	return profile, true
end

local function finishRunForUser(userId, score, runMetrics)
	local profile = loadProfile(userId)
	local runState = runStateByUser[userId]
	if not runState or not runState.active then
		return profile, false
	end

	applyRunResult(profile, runState, score, runMetrics)
	runStateByUser[userId] = {
		active = false,
		tuning = nil,
		prestigeLevel = nil,
		targetPrestigeLevel = nil,
		speedGraduationTarget = nil,
		speedGraduationCapTolerance = nil,
		startedAt = nil,
	}
	markDirty(userId)
	return profile, true
end

local function abandonRunForUser(userId)
	local profile = loadProfile(userId)
	local runState = runStateByUser[userId]
	if runState and runState.active then
		applyRunResult(profile, runState, 0, nil)
		runStateByUser[userId] = {
			active = false,
			tuning = nil,
			prestigeLevel = nil,
			targetPrestigeLevel = nil,
			speedGraduationTarget = nil,
			speedGraduationCapTolerance = nil,
			startedAt = nil,
		}
		markDirty(userId)
		return profile, true
	end

	return profile, false
end

local function setTuning(player, requestedTuning)
	local userId = player.UserId
	local profile = loadProfile(userId)
	local runState = runStateByUser[userId]
	if runState and runState.active then
		return {
			success = false,
			reasonCode = "RUN_ACTIVE",
			message = "You can only apply tuning while not in a run.",
			state = buildClientState(profile, userId),
		}
	end

	local limits = PrestigeConfig.getTuningBand(profile.progression.level)
	local requested = {
		speedCapMultiplier = tonumber(requestedTuning and requestedTuning.speedCapMultiplier) or tonumber(profile.tuning.selected.speedCapMultiplier) or RuntimeTuning.getDefaultTuning().speedCapMultiplier,
		gravity = tonumber(requestedTuning and requestedTuning.gravity) or tonumber(profile.tuning.selected.gravity) or RuntimeTuning.getDefaultTuning().gravity,
		jumpPowerMultiplier = tonumber(requestedTuning and requestedTuning.jumpPowerMultiplier) or tonumber(profile.tuning.selected.jumpPowerMultiplier) or RuntimeTuning.getDefaultTuning().jumpPowerMultiplier,
	}
	local clamped = RuntimeTuning.clampTuning(requested, limits)
	local changed = not RuntimeTuning.tuningEquals(clamped, profile.tuning.selected)
	local wasClamped = not RuntimeTuning.tuningEquals(clamped, requested)

	if changed then
		profile.tuning.selected = clamped
		markDirty(userId)
		pushState(player, profile, {
			type = "tuning_applied",
			clamped = wasClamped,
		})
	end

	return {
		success = true,
		changed = changed,
		clamped = wasClamped,
		tuning = clamped,
		state = buildClientState(profile, userId),
	}
end

local function attemptPrestige(player)
	local userId = player.UserId
	local profile = loadProfile(userId)
	local runState = runStateByUser[userId]
	if runState and runState.active then
		return {
			success = false,
			reasonCode = "RUN_ACTIVE",
			message = "Finish your run before attempting prestige.",
			state = buildClientState(profile, userId),
		}
	end

	local currentLevel = normalizePrestigeLevel(profile.progression.level)
	local nextLevelNumber = normalizePrestigeLevel(currentLevel + 1)
	if nextLevelNumber <= currentLevel then
		return {
			success = false,
			reasonCode = "MAX_LEVEL",
			message = "Prestige cap reached for this server build.",
			state = buildClientState(profile, userId),
		}
	end

	local nextLevel = PrestigeConfig.getLevel(nextLevelNumber)

	if not nextLevel then
		return {
			success = false,
			reasonCode = "MAX_LEVEL",
			message = "You already reached max prestige.",
			state = buildClientState(profile, userId),
		}
	end

	if not ConditionEvaluator.evaluate(nextLevel.condition, profile) then
		return {
			success = false,
			reasonCode = "REQUIREMENTS_NOT_MET",
			message = "Requirements not met yet.",
			state = buildClientState(profile, userId),
		}
	end

	-- Prestige missions in MissionsUI route the player here instead of redeeming
	-- directly, so mark/redeem the current prestige missions as part of the
	-- successful prestige action before advancing the prestige level.
	if missionService and type(missionService.completeCurrentPrestigeMissionsForPlayer) == "function" then
		local ok, err = pcall(missionService.completeCurrentPrestigeMissionsForPlayer, player)
		if not ok then
			warn("[PrestigeService] Failed to auto-complete prestige missions on prestige:", err)
		end
	end

	profile.progression.level = nextLevelNumber
	profile.progression.lastPrestigeAt = os.time()

	local newLimits = PrestigeConfig.getTuningBand(profile.progression.level)
	profile.tuning.selected = RuntimeTuning.clampTuning(profile.tuning.selected, newLimits)

	markDirty(userId)
	saveProfile(userId, true)
	pushState(player, profile, {
		type = "prestige_success",
		level = nextLevelNumber,
		title = nextLevel.title,
	})

	if missionService and type(missionService.refreshStateForPlayer) == "function" then
		local ok, err = pcall(missionService.refreshStateForPlayer, player)
		if not ok then
			warn("[PrestigeService] Failed to refresh mission state after prestige:", err)
		end
	end

	return {
		success = true,
		reasonCode = "PRESTIGE_SUCCESS",
		newLevel = nextLevelNumber,
		levelTitle = nextLevel.title,
		state = buildClientState(profile, userId),
	}
end

local function handleRunReport(player, eventName, payload)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if type(eventName) ~= "string" then
		return
	end

	local userId = player.UserId
	local safePayload = if type(payload) == "table" then payload else {}

	if eventName == "run_started" then
		local profile, changed = startRunForUser(userId)
		if changed then
			pushState(player, profile, { type = "run_started" })
		end
		return
	end

	if eventName == "run_finished" then
		local score = safePayload.score
		local runMetrics = {
			maxSpeedMultiplierReached = sanitizeIncomingMaxSpeedMultiplier(safePayload.maxSpeedMultiplierReached),
		}
		local profile, changed = finishRunForUser(userId, score, runMetrics)
		if changed then
			pushState(player, profile, {
				type = "run_finished",
				score = sanitizeIncomingScore(score),
			})
		end
		return
	end

	if eventName == "run_abandoned" then
		local profile, changed = abandonRunForUser(userId)
		if changed then
			pushState(player, profile, { type = "run_abandoned" })
		end
		return
	end
end

function PrestigeService.init()
	if PrestigeConfig.ENABLED ~= true then
		return
	end

	if initialized then
		return
	end
	initialized = true

	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = "Remotes"
		remoteFolder.Parent = ReplicatedStorage
	end

	getStateRemote = remoteFolder:FindFirstChild(PrestigeConfig.REMOTES.GET_STATE)
	if not getStateRemote then
		getStateRemote = Instance.new("RemoteFunction")
		getStateRemote.Name = PrestigeConfig.REMOTES.GET_STATE
		getStateRemote.Parent = remoteFolder
	end

	stateUpdatedRemote = remoteFolder:FindFirstChild(PrestigeConfig.REMOTES.STATE_UPDATED)
	if not stateUpdatedRemote then
		stateUpdatedRemote = Instance.new("RemoteEvent")
		stateUpdatedRemote.Name = PrestigeConfig.REMOTES.STATE_UPDATED
		stateUpdatedRemote.Parent = remoteFolder
	end

	reportRunRemote = remoteFolder:FindFirstChild(PrestigeConfig.REMOTES.REPORT_RUN)
	if not reportRunRemote then
		reportRunRemote = Instance.new("RemoteEvent")
		reportRunRemote.Name = PrestigeConfig.REMOTES.REPORT_RUN
		reportRunRemote.Parent = remoteFolder
	end

	attemptPrestigeRemote = remoteFolder:FindFirstChild(PrestigeConfig.REMOTES.ATTEMPT_PRESTIGE)
	if not attemptPrestigeRemote then
		attemptPrestigeRemote = Instance.new("RemoteFunction")
		attemptPrestigeRemote.Name = PrestigeConfig.REMOTES.ATTEMPT_PRESTIGE
		attemptPrestigeRemote.Parent = remoteFolder
	end

	setTuningRemote = remoteFolder:FindFirstChild(PrestigeConfig.REMOTES.SET_TUNING)
	if not setTuningRemote then
		setTuningRemote = Instance.new("RemoteFunction")
		setTuningRemote.Name = PrestigeConfig.REMOTES.SET_TUNING
		setTuningRemote.Parent = remoteFolder
	end

	getStateRemote.OnServerInvoke = function(player)
		local profile = loadProfile(player.UserId)
		return {
			state = buildClientState(profile, player.UserId),
		}
	end

	reportRunRemote.OnServerEvent:Connect(function(player, eventName, payload)
		handleRunReport(player, eventName, payload)
	end)

	attemptPrestigeRemote.OnServerInvoke = function(player)
		return attemptPrestige(player)
	end

	setTuningRemote.OnServerInvoke = function(player, tuning)
		return setTuning(player, tuning)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			loadProfile(player.UserId)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		saveOnExit(userId)
		cachedProfiles[userId] = nil
		dirtyProfiles[userId] = nil
		runStateByUser[userId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			loadProfile(player.UserId)
		end)
	end

	task.spawn(function()
		while true do
			task.wait(PrestigeConfig.AUTOSAVE_INTERVAL or 60)
			for userId in pairs(dirtyProfiles) do
				saveProfile(userId, false)
				task.wait(PrestigeConfig.AUTOSAVE_SPREAD_DELAY or 0)
			end
		end
	end)

	game:BindToClose(function()
		for userId in pairs(cachedProfiles) do
			saveOnExit(userId)
		end
	end)
end

function PrestigeService.getCurrentLevel(userId)
	if PrestigeConfig.ENABLED ~= true then
		return 0
	end

	local numericUserId = tonumber(userId)
	if not numericUserId then
		return 0
	end

	local profile = loadProfile(numericUserId)
	return normalizePrestigeLevel(profile.progression and profile.progression.level)
end

--[[
	Debug-only helper: resets a player's prestige progression/state to defaults.
	@param playerOrUserId Player|number
	@return boolean success, string? err
]]
function PrestigeService.debugResetPlayer(playerOrUserId)
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

	local profile = createDefaultProfile()
	cachedProfiles[userId] = profile
	dirtyProfiles[userId] = nil
	runStateByUser[userId] = {
		active = false,
		tuning = nil,
		prestigeLevel = nil,
		targetPrestigeLevel = nil,
		speedGraduationTarget = nil,
		speedGraduationCapTolerance = nil,
		startedAt = nil,
	}
	exitSaveStarted[userId] = nil

	if dataStoreAvailable and prestigeDataStore then
		local ok, err = pcall(function()
			prestigeDataStore:RemoveAsync(profileKeyForUser(userId))
		end)
		if not ok then
			warn("[PrestigeService] Failed to reset prestige data for user " .. userId .. ": " .. tostring(err))
			return false, tostring(err)
		end
	end

	if player then
		pushState(player, profile, { type = "debug_reset_prestige" })
	end

	return true
end

return PrestigeService
