--[[
	PrestigeConfig.luau

	Central config for the prestige system.

Schema:
	- VERSION / DATASTORE_*: persistence compatibility and write cadence
	- UNBOUNDED_PRESTIGE / SOFT_MAX_PRESTIGE_LEVEL: infinite progression mode
	- REMOTES: network contract names (client <-> server)
	- READY_BUTTON: world-space ready button visuals/layout
	- UI: modal presentation constants
	- TRACKING: stat tracking thresholds and caps
	- TUNING_BANDS: unlocked tuning limits (speed/gravity/jump power) by current prestige level
	- LEVELS: next-prestige unlock requirements using Condition DSL

	How to rebalance safely:
	- Edit LEVELS[*].condition and LEVELS[*].progress
	- Edit TUNING_BANDS
	- Avoid touching service logic for normal balancing work
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)

local PrestigeConfig = {}

PrestigeConfig.VERSION = 1
PrestigeConfig.DATASTORE_NAME = "FlappyBirdPrestige"
PrestigeConfig.AUTOSAVE_INTERVAL = 60
PrestigeConfig.AUTOSAVE_SPREAD_DELAY = 0.05
-- Backend toggle: set true to enable prestige mode, false to use shop tuning mode.
PrestigeConfig.ENABLED = true
PrestigeConfig.PRESTIGE_PLAN = {
	-- Single source of truth for bounded progression length.
	-- Increase this to add more prestiges (the tuning/UI system will expand).
	-- If nil, max level can be inferred from authored data.
	TOTAL_LEVELS = 10,
	-- If true, levels beyond explicit `LEVELS` are generated (up to TOTAL_LEVELS).
	ALLOW_GENERATED_REQUIREMENTS = true,
}

PrestigeConfig.MAX_PRESTIGE_LEVEL = PrestigeConfig.PRESTIGE_PLAN.TOTAL_LEVELS
PrestigeConfig.UNBOUNDED_PRESTIGE = false
PrestigeConfig.SOFT_MAX_PRESTIGE_LEVEL = PrestigeConfig.MAX_PRESTIGE_LEVEL
PrestigeConfig.RUNTIME_TUNING_ENABLED = PrestigeConfig.ENABLED

PrestigeConfig.PRESTIGE_MISSION = {
	ID_PREFIX = "prestige_next_score",
	TITLE_FORMAT = "Prestige %d Mission",
	DESCRIPTION_FORMAT = "Reach requirements to unlock Prestige %d.",
	-- Keep empty by default so this mission is progression guidance first.
	REWARDS = {},
}

PrestigeConfig.REMOTES = {
	GET_STATE = "GetPrestigeState",
	STATE_UPDATED = "PrestigeStateUpdated",
	REPORT_RUN = "PrestigeReportRun",
	ATTEMPT_PRESTIGE = "AttemptPrestige",
	SET_TUNING = "SetPrestigeTuning",
}

PrestigeConfig.TRACKING = {
	MAX_ACCEPTED_SCORE = 1000000000,
	MAX_ACCEPTED_RUNS = 1000000000,
	SPEED_THRESHOLD = 2.8,
	GRAVITY_THRESHOLD = 300,
}

PrestigeConfig.READY_BUTTON = {
	BILLBOARD_SIZE = UDim2.new(8, 0, 8, 0),
	STUDS_OFFSET = Vector3.new(0, 0, 0),
	ROW_ORDER = 3,
	LOCAL_OFFSET = Vector3.new(0, 0, 0),
	BG_COLOR = Color3.fromRGB(190, 120, 255),
	BG_TRANSPARENCY = 0.1,
	CORNER_RADIUS = UDim.new(0.15, 0),
	TEXT = "\u{2728}",
	LABEL = "PRESTIGE",
	LABEL_FONT = Enum.Font.GothamBlack,
	LABEL_COLOR = Color3.fromRGB(35, 20, 55),
	READY_BG_COLOR = Color3.fromRGB(120, 230, 170),
	READY_LABEL = "READY!",
	READY_LABEL_COLOR = Color3.fromRGB(20, 60, 35),
}

PrestigeConfig.UI = {
	OVERLAY_COLOR = Color3.new(0, 0, 0),
	OVERLAY_TRANSPARENCY = 0.4,

	CONTAINER_WIDTH = 520,
	CONTAINER_HEIGHT = 620,
	CONTAINER_BG_COLOR = Color3.fromRGB(34, 26, 44),
	CONTAINER_BG_TRANSPARENCY = 0.05,
	CONTAINER_CORNER_RADIUS = UDim.new(0, 12),

	HEADER_HEIGHT = 50,
	TITLE_TEXT = "PRESTIGE TUNING",
	TITLE_FONT = Enum.Font.GothamBlack,
	TITLE_COLOR = Color3.fromRGB(255, 220, 120),
	TITLE_SIZE = 28,
	TITLE_STROKE_COLOR = Color3.fromRGB(80, 50, 10),
	TITLE_STROKE_TRANSPARENCY = 0.4,
	CLOSE_BUTTON_SIZE = 36,
	CLOSE_BUTTON_COLOR = Color3.fromRGB(200, 60, 60),
	CLOSE_BUTTON_FONT = Enum.Font.GothamBlack,

	TEXT_FONT = Enum.Font.Gotham,
	TEXT_BOLD_FONT = Enum.Font.GothamBold,
	BODY_TEXT_SIZE = 15,
	SMALL_TEXT_SIZE = 13,

	INPUT_BG = Color3.fromRGB(22, 22, 28),
	INPUT_TEXT = Color3.fromRGB(245, 245, 245),
	BUTTON_TEXT = Color3.fromRGB(255, 255, 255),

	BUTTON_PRIMARY = Color3.fromRGB(85, 145, 255),
	BUTTON_ACCENT = Color3.fromRGB(96, 190, 136),
	BUTTON_SECONDARY = Color3.fromRGB(85, 85, 95),
	BUTTON_WARN = Color3.fromRGB(210, 95, 80),

	REFERENCE_HEIGHT = 800,
	MIN_SCALE = 0.45,
	MAX_SCALE = 1.2,
}

local defaultSpeedCap = tonumber(GameConfig.SPEED.MAX_MULTIPLIER) or 2.5
local defaultGravity = tonumber(PlayerConfig.GRAVITY) or 150
local defaultJumpPowerMultiplier = 0.65

-- Tuning progression is now defined concretely for each prestige (0 -> 10).
-- Use `TUNING_BASE_BAND` for the starting menu values and then apply selective
-- per-prestige upgrades in `TUNING_PRESTIGE_UPGRADES`.
--
-- Example: to make Prestige 3 only upgrade jump power, define only
-- `[3] = { jumpPowerMultiplier = { max = ... } }`
PrestigeConfig.TUNING_BASE_BAND = {
	-- Level 0 (before any prestige): readable starting pace with room to tune
	-- easier/harder, while keeping the top end conservative.
	speedCapMultiplier = { min = 1.00, max = 1.00, step = 0.05 },
	gravity = { min = 150, max = defaultGravity, step = 5 },
	jumpPowerMultiplier = { min = 0.65, max = defaultJumpPowerMultiplier, step = 0.05 },
}

PrestigeConfig.TUNING_PRESTIGE_UPGRADES = {
	-- P1: first speed-ramp bump (players feel immediate progression).
	[1] = {
		speedCapMultiplier = { max = 1.35 },
	},
	-- P2: gravity ceiling expands for route/control experimentation.
	[2] = {
		gravity = { max = 270 },
	},
	-- P3: only jump power unlocks (explicit selective upgrade example).
	[3] = {
		jumpPowerMultiplier = { max = 1.15 },
	},
	-- P4: speed ramp expands again.
	[4] = {
		speedCapMultiplier = { max = 1.55 },
	},
	-- P5: expand gravity ceiling.
	[5] = {
		gravity = { max = 290 },
	},
	-- P6: jump power expands again.
	[6] = {
		jumpPowerMultiplier = { max = 1.35 },
	},
	-- P7: speed ramp expands into advanced pacing.
	[7] = {
		speedCapMultiplier = { max = 1.85 },
	},
	-- P8: gravity gets another step up.
	[8] = {
		gravity = { max = 315 },
	},
	-- P9: jump power pushes into expert territory.
	[9] = {
		jumpPowerMultiplier = { max = 1.65 },
	},
	-- P10: final tier unlocks full range.
	[10] = {
		speedCapMultiplier = { max = defaultSpeedCap },
		gravity = { max = 340 },
		jumpPowerMultiplier = { max = 2.00 },
	},
}

local TUNING_RANGE_KEYS = {
	"speedCapMultiplier",
	"gravity",
	"jumpPowerMultiplier",
}

local TUNING_RANGE_MIN_FLOORS = {
	speedCapMultiplier = 0.10,
	gravity = 1,
	jumpPowerMultiplier = 0.10,
}

local function getHighestNumericKey(mapLike)
	if type(mapLike) ~= "table" then
		return 0
	end

	local highest = 0
	for key in pairs(mapLike) do
		if type(key) == "number" then
			highest = math.max(highest, math.floor(key))
		end
	end

	return highest
end

local function getConfiguredTuningBandBuildMaxLevel()
	local plan = PrestigeConfig.PRESTIGE_PLAN or {}
	local totalLevels = tonumber(plan.TOTAL_LEVELS)
	if totalLevels ~= nil then
		return math.max(0, math.floor(totalLevels))
	end

	local explicitMax = tonumber(PrestigeConfig.MAX_PRESTIGE_LEVEL)
	if explicitMax ~= nil then
		return math.max(0, math.floor(explicitMax))
	end

	return math.max(0, getHighestNumericKey(PrestigeConfig.TUNING_PRESTIGE_UPGRADES))
end

local function cloneRangeSpec(range)
	local source = type(range) == "table" and range or {}
	return {
		min = tonumber(source.min),
		max = tonumber(source.max),
		step = tonumber(source.step),
	}
end

local function cloneBandSpec(band)
	local source = type(band) == "table" and band or {}
	return {
		speedCapMultiplier = cloneRangeSpec(source.speedCapMultiplier),
		gravity = cloneRangeSpec(source.gravity),
		jumpPowerMultiplier = cloneRangeSpec(source.jumpPowerMultiplier),
	}
end

local function sanitizeRangeSpecForKey(key, range)
	local floorValue = TUNING_RANGE_MIN_FLOORS[key]
	local safe = cloneRangeSpec(range)
	local minValue = tonumber(safe.min)
	local maxValue = tonumber(safe.max)
	local stepValue = tonumber(safe.step)

	if floorValue ~= nil then
		if minValue == nil then
			minValue = floorValue
		end
		minValue = math.max(floorValue, minValue)
	end

	if maxValue == nil then
		maxValue = minValue
	end
	if minValue == nil then
		minValue = maxValue
	end
	if maxValue == nil then
		minValue = 0
		maxValue = 0
	end

	if maxValue < minValue then
		maxValue = minValue
	end

	if stepValue ~= nil and stepValue <= 0 then
		stepValue = nil
	end

	return {
		min = minValue,
		max = maxValue,
		step = stepValue,
	}
end

local function mergeBandSpec(baseBand, patchBand)
	local merged = cloneBandSpec(baseBand)
	if type(patchBand) ~= "table" then
		for _, key in ipairs(TUNING_RANGE_KEYS) do
			merged[key] = sanitizeRangeSpecForKey(key, merged[key])
		end
		return merged
	end

	for _, key in ipairs(TUNING_RANGE_KEYS) do
		local patchRange = patchBand[key]
		if type(patchRange) == "table" then
			local currentRange = type(merged[key]) == "table" and merged[key] or {}
			merged[key] = {
				min = if patchRange.min ~= nil then tonumber(patchRange.min) else tonumber(currentRange.min),
				max = if patchRange.max ~= nil then tonumber(patchRange.max) else tonumber(currentRange.max),
				step = if patchRange.step ~= nil then tonumber(patchRange.step) else tonumber(currentRange.step),
			}
		end
		merged[key] = sanitizeRangeSpecForKey(key, merged[key])
	end

	return merged
end

local function mergeStepsForNonShrinkingOptions(previousStep, nextStep)
	local prev = tonumber(previousStep)
	local nxt = tonumber(nextStep)

	-- nil means "no quantization" (most flexible), so keep it if present.
	if prev == nil or nxt == nil then
		return nil
	end
	if prev <= 0 then
		return nxt
	end
	if nxt <= 0 then
		return prev
	end

	-- Smaller step preserves/adds options; larger step can remove options.
	return math.min(prev, nxt)
end

local function enforceNonShrinkingBand(previousBand, nextBand)
	local prev = cloneBandSpec(previousBand)
	local nextSpec = cloneBandSpec(nextBand)
	local result = cloneBandSpec(nextSpec)

	for _, key in ipairs(TUNING_RANGE_KEYS) do
		local prevRange = sanitizeRangeSpecForKey(key, prev[key])
		local nextRange = sanitizeRangeSpecForKey(key, nextSpec[key])

		local fixedMin = tonumber(prevRange.min)
		if fixedMin == nil then
			fixedMin = tonumber(nextRange.min) or 0
		end

		result[key] = {
			-- Lock the lower bound to the previous prestige's lower bound so
			-- the left edge of the slider never moves and no baseline options are lost.
			min = fixedMin,
			-- Do not let later prestiges reduce the maximum and remove upper-end options.
			max = math.max(tonumber(prevRange.max) or 0, tonumber(nextRange.max) or 0),
			-- Prefer equal or finer granularity so prior discrete choices remain reachable.
			step = mergeStepsForNonShrinkingOptions(prevRange.step, nextRange.step),
		}

		result[key] = sanitizeRangeSpecForKey(key, result[key])
	end

	return result
end

local function buildConcreteTuningBands(baseBand, upgradesByLevel, maxPrestigeLevel)
	local maxLevel = math.max(0, math.floor(tonumber(maxPrestigeLevel) or 0))
	local bands = {}
	local currentBand = mergeBandSpec(baseBand, nil)

	bands[0] = cloneBandSpec(currentBand)
	for level = 1, maxLevel do
		local mergedBand = mergeBandSpec(currentBand, upgradesByLevel and upgradesByLevel[level])
		currentBand = enforceNonShrinkingBand(currentBand, mergedBand)
		bands[level] = cloneBandSpec(currentBand)
	end

	return bands
end

PrestigeConfig.TUNING_BANDS = buildConcreteTuningBands(
	PrestigeConfig.TUNING_BASE_BAND,
	PrestigeConfig.TUNING_PRESTIGE_UPGRADES,
	getConfiguredTuningBandBuildMaxLevel()
)

local SPEED_GRADUATION_STAT_ROOT = "stats.speed_graduation_by_level"

local function getSpeedGraduationStatKeyForCurrentLevel(currentLevel)
	local level = math.max(0, math.floor(tonumber(currentLevel) or 0))
	return "p" .. tostring(level)
end

local function getSpeedGraduationStatPathForTargetLevel(targetLevel)
	local level = math.max(1, math.floor(tonumber(targetLevel) or 1))
	local currentLevel = math.max(0, level - 1)
	return string.format("%s.%s", SPEED_GRADUATION_STAT_ROOT, getSpeedGraduationStatKeyForCurrentLevel(currentLevel))
end

local function getSpeedGraduationProgressLabelForTargetLevel(targetLevel)
	local level = math.max(1, math.floor(tonumber(targetLevel) or 1))
	local currentLevel = math.max(0, level - 1)
	return string.format("Best @ Prestige %d Speed Ramp", currentLevel)
end

PrestigeConfig.LEVELS = {
	{
		id = "prestige_1",
		title = "Prestige I",
		requirementText = "Reach best score 20.",
		-- Rationale: first prestige should be reachable quickly so the system
		-- feels rewarding and unlocks tuning experimentation early.
		rationale = "First prestige is intentionally fast so tuning unlocks early.",
		condition = {
			type = "all",
			conditions = {
				{ type = "compare", path = "stats.best_score", op = ">=", value = 20, default = 0 },
			},
		},
		progress = {
			{ label = "Best Score", path = "stats.best_score", target = 20 },
		},
	},
	{
		id = "prestige_2",
		title = "Prestige II",
		requirementText = "Reach best score 35 and complete a speed-cap mastery run for your current prestige.",
		-- Rationale: introduces speed-focused mastery once tuning is unlocked.
		rationale = "Second prestige graduates players at the current prestige speed cap before the next cap unlocks.",
		condition = {
			type = "all",
			conditions = {
				{ type = "compare", path = "stats.best_score", op = ">=", value = 35, default = 0 },
				{ type = "compare", path = getSpeedGraduationStatPathForTargetLevel(2), op = ">=", value = 18, default = 0 },
			},
		},
		progress = {
			{ label = "Best Score", path = "stats.best_score", target = 35 },
			{ label = getSpeedGraduationProgressLabelForTargetLevel(2), path = getSpeedGraduationStatPathForTargetLevel(2), target = 18 },
		},
	},
	{
		id = "prestige_3",
		title = "Prestige III",
		requirementText = "Reach best score 55 and prove speed-cap + gravity consistency.",
		-- Rationale: requires balanced control at both harder speed and gravity settings.
		rationale = "Third prestige blends score with current-cap speed mastery and high-gravity consistency.",
		condition = {
			type = "all",
			conditions = {
				{ type = "compare", path = "stats.best_score", op = ">=", value = 55, default = 0 },
				{ type = "compare", path = getSpeedGraduationStatPathForTargetLevel(3), op = ">=", value = 32, default = 0 },
				{ type = "compare", path = "stats.best_score_at_gravity_threshold", op = ">=", value = 24, default = 0 },
			},
		},
		progress = {
			{ label = "Best Score", path = "stats.best_score", target = 55 },
			{ label = getSpeedGraduationProgressLabelForTargetLevel(3), path = getSpeedGraduationStatPathForTargetLevel(3), target = 32 },
			{ label = "Best @ High Gravity", path = "stats.best_score_at_gravity_threshold", target = 24 },
		},
	},
	{
		id = "prestige_4",
		title = "Prestige IV",
		requirementText = "Reach best score 80 and master advanced speed-cap + gravity runs.",
		-- Rationale: late tiers should demand mastery rather than pure grind.
		rationale = "Final tier favors skill expression with current-cap speed mastery and demanding tuned-run targets.",
		condition = {
			type = "all",
			conditions = {
				{ type = "compare", path = "stats.best_score", op = ">=", value = 80, default = 0 },
				{ type = "compare", path = getSpeedGraduationStatPathForTargetLevel(4), op = ">=", value = 50, default = 0 },
				{ type = "compare", path = "stats.best_score_at_gravity_threshold", op = ">=", value = 40, default = 0 },
			},
		},
		progress = {
			{ label = "Best Score", path = "stats.best_score", target = 80 },
			{ label = getSpeedGraduationProgressLabelForTargetLevel(4), path = getSpeedGraduationStatPathForTargetLevel(4), target = 50 },
			{ label = "Best @ High Gravity", path = "stats.best_score_at_gravity_threshold", target = 40 },
		},
	},
}

local function copyBand(band)
	local speed = band.speedCapMultiplier or {}
	local gravity = band.gravity or {}
	local jump = band.jumpPowerMultiplier or {}
	return {
		speedCapMultiplier = {
			min = speed.min,
			max = speed.max,
			step = speed.step,
		},
		gravity = {
			min = gravity.min,
			max = gravity.max,
			step = gravity.step,
		},
		jumpPowerMultiplier = {
			min = jump.min,
			max = jump.max,
			step = jump.step,
		},
	}
end

local function cloneRewards(rewards)
	local output = {}
	if type(rewards) ~= "table" then
		return output
	end

	for _, reward in ipairs(rewards) do
		if type(reward) == "table" then
			local rewardCopy = {}
			for key, value in pairs(reward) do
				rewardCopy[key] = value
			end
			table.insert(output, rewardCopy)
		end
	end

	return output
end

local function buildPrestigeMissionRewards(nextLevel)
	local missionCfg = PrestigeConfig.PRESTIGE_MISSION or {}
	local rewards = cloneRewards(missionCfg.REWARDS)

	table.insert(rewards, 1, {
		type = "prestige_level",
		level = math.max(1, math.floor(tonumber(nextLevel) or 1)),
	})

	return rewards
end

local function cloneTableDeep(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = cloneTableDeep(child)
	end
	return copy
end

local TRACKED_PATH_TO_TUNING_KEY = {
	["stats.best_score_at_gravity_threshold"] = "gravity",
}

local function conditionReferencesPath(condition, path)
	if type(condition) ~= "table" then
		return false
	end

	if condition.type == "compare" then
		return condition.path == path
	end

	if condition.type == "all" or condition.type == "any" then
		for _, child in ipairs(condition.conditions or {}) do
			if conditionReferencesPath(child, path) then
				return true
			end
		end
		return false
	end

	if condition.type == "not" then
		return conditionReferencesPath(condition.condition, path)
	end

	return false
end

local function levelRequiresTrackedPath(levelDef, trackedPath)
	return conditionReferencesPath(type(levelDef) == "table" and levelDef.condition, trackedPath)
end

local function extrapolateRange(previousRange, lastRange, levelDelta, levelSpan, minFloor)
	local prevMin = tonumber(previousRange and previousRange.min) or tonumber(lastRange and lastRange.min) or 0
	local prevMax = tonumber(previousRange and previousRange.max) or tonumber(lastRange and lastRange.max) or prevMin
	local lastMin = tonumber(lastRange and lastRange.min) or prevMin
	local lastMax = tonumber(lastRange and lastRange.max) or prevMax
	local step = tonumber(lastRange and lastRange.step) or tonumber(previousRange and previousRange.step)

	local safeSpan = math.max(1, levelSpan)
	local perLevelMin = (lastMin - prevMin) / safeSpan
	local perLevelMax = (lastMax - prevMax) / safeSpan

	local resultMin = lastMin + (perLevelMin * levelDelta)
	local resultMax = lastMax + (perLevelMax * levelDelta)

	if minFloor ~= nil then
		resultMin = math.max(minFloor, resultMin)
	end
	if resultMax < resultMin then
		resultMax = resultMin
	end

	return {
		min = resultMin,
		max = resultMax,
		step = step,
	}
end

local cachedBandLevels = nil
local cachedEffectiveTrackingThresholds = nil
local cachedBandChangeLevelsByKey = nil

local function cloneNumberArray(values)
	local copy = table.create(#values)
	for i, value in ipairs(values) do
		copy[i] = value
	end
	return copy
end

local function rangesEquivalent(a, b)
	if type(a) ~= "table" and type(b) ~= "table" then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	local function sameNumber(x, y)
		local nx = tonumber(x)
		local ny = tonumber(y)
		if nx == nil and ny == nil then
			return true
		end
		if nx == nil or ny == nil then
			return false
		end
		return math.abs(nx - ny) < 0.0001
	end

	return sameNumber(a.min, b.min)
		and sameNumber(a.max, b.max)
		and sameNumber(a.step, b.step)
end

local function getDefinedBandLevels()
	if cachedBandLevels then
		return cachedBandLevels
	end

	local levels = {}
	for bandLevel in pairs(PrestigeConfig.TUNING_BANDS) do
		if type(bandLevel) == "number" then
			table.insert(levels, math.floor(bandLevel))
		end
	end
	table.sort(levels)

	cachedBandLevels = levels
	return cachedBandLevels
end

local function findProgressTarget(levelDef, path, fallback)
	if type(levelDef) ~= "table" then
		return fallback
	end

	for _, progressDef in ipairs(levelDef.progress or {}) do
		if progressDef.path == path then
			local target = tonumber(progressDef.target)
			if target then
				return math.floor(target)
			end
		end
	end

	return fallback
end

local function buildGeneratedLevel(level)
	if type(level) ~= "number" or level <= 0 then
		return nil
	end

	local explicitCount = #PrestigeConfig.LEVELS
	if level <= explicitCount then
		return PrestigeConfig.LEVELS[level]
	end

	local extraIndex = level - explicitCount
	local anchor = PrestigeConfig.LEVELS[explicitCount]

	local baseBestScore = findProgressTarget(anchor, "stats.best_score", 80)
	local baseHighSpeed = findProgressTarget(anchor, getSpeedGraduationStatPathForTargetLevel(explicitCount), 50)
	local baseHighGravity = findProgressTarget(anchor, "stats.best_score_at_gravity_threshold", 40)

	local bestScoreTarget = baseBestScore + (extraIndex * 15)
	local highSpeedTarget = baseHighSpeed + (extraIndex * 8)
	local highGravityTarget = baseHighGravity + (extraIndex * 7)

	local generated = {
		id = "prestige_" .. tostring(level),
		title = "Prestige " .. tostring(level),
		requirementText = string.format(
			"Reach best score %d and complete current speed-cap + high-gravity mastery runs.",
			bestScoreTarget
		),
		rationale = "Auto-generated tier that makes the current prestige speed cap a graduation target before the next cap unlock.",
		condition = {
			type = "all",
			conditions = {
				{ type = "compare", path = "stats.best_score", op = ">=", value = bestScoreTarget, default = 0 },
				{ type = "compare", path = getSpeedGraduationStatPathForTargetLevel(level), op = ">=", value = highSpeedTarget, default = 0 },
				{ type = "compare", path = "stats.best_score_at_gravity_threshold", op = ">=", value = highGravityTarget, default = 0 },
			},
		},
		progress = {
			{ label = "Best Score", path = "stats.best_score", target = bestScoreTarget },
			{ label = getSpeedGraduationProgressLabelForTargetLevel(level), path = getSpeedGraduationStatPathForTargetLevel(level), target = highSpeedTarget },
			{ label = "Best @ High Gravity", path = "stats.best_score_at_gravity_threshold", target = highGravityTarget },
		},
	}

	return generated
end

local function findBestScoreTargetInProgress(levelDef)
	if type(levelDef) ~= "table" then
		return nil
	end

	for _, progressDef in ipairs(levelDef.progress or {}) do
		if progressDef.path == "stats.best_score" then
			local target = tonumber(progressDef.target)
			if target then
				return math.max(1, math.floor(target))
			end
		end
	end

	return nil
end

local function findBestScoreTargetInCondition(condition)
	if type(condition) ~= "table" then
		return nil
	end

	if condition.type == "compare" and condition.path == "stats.best_score" then
		local target = tonumber(condition.value)
		if target then
			return math.max(1, math.floor(target))
		end
	end

	if condition.type == "all" or condition.type == "any" then
		for _, child in ipairs(condition.conditions or {}) do
			local target = findBestScoreTargetInCondition(child)
			if target then
				return target
			end
		end
	elseif condition.type == "not" then
		return findBestScoreTargetInCondition(condition.condition)
	end

	return nil
end

function PrestigeConfig.getMaxPrestigeLevel()
	local plan = PrestigeConfig.PRESTIGE_PLAN or {}
	local planTotal = tonumber(plan.TOTAL_LEVELS)
	if planTotal ~= nil then
		return math.max(0, math.floor(planTotal))
	end

	local configuredMax = tonumber(PrestigeConfig.MAX_PRESTIGE_LEVEL)
	if configuredMax ~= nil then
		return math.max(0, math.floor(configuredMax))
	end

	if PrestigeConfig.UNBOUNDED_PRESTIGE == true then
		return nil
	end

	local highestUpgradeLevel = getHighestNumericKey(PrestigeConfig.TUNING_PRESTIGE_UPGRADES)
	local explicitLevelCount = #PrestigeConfig.LEVELS
	return math.max(explicitLevelCount, highestUpgradeLevel)
end

function PrestigeConfig.getLevel(level)
	local normalizedLevel = math.floor(tonumber(level) or 0)
	if normalizedLevel <= 0 then
		return nil
	end

	local explicit = PrestigeConfig.LEVELS[normalizedLevel]
	if explicit then
		return explicit
	end

	local configuredMax = PrestigeConfig.getMaxPrestigeLevel()
	if type(configuredMax) == "number" and normalizedLevel > configuredMax then
		return nil
	end

	local plan = PrestigeConfig.PRESTIGE_PLAN or {}
	if plan.ALLOW_GENERATED_REQUIREMENTS == false then
		return nil
	end

	return buildGeneratedLevel(normalizedLevel)
end

function PrestigeConfig.getTuningBand(prestigeLevel)
	local level = math.max(0, math.floor(tonumber(prestigeLevel) or 0))
	local selectedBand = PrestigeConfig.TUNING_BANDS[0]
	local selectedLevel = 0
	local bandLevels = getDefinedBandLevels()

	for _, bandLevel in ipairs(bandLevels) do
		if bandLevel <= level and bandLevel >= selectedLevel then
			selectedLevel = bandLevel
			selectedBand = PrestigeConfig.TUNING_BANDS[bandLevel]
		end
	end

	local highestBandLevel = bandLevels[#bandLevels] or 0
	if PrestigeConfig.UNBOUNDED_PRESTIGE == true and level > highestBandLevel and #bandLevels >= 2 then
		local lastLevel = bandLevels[#bandLevels]
		local previousLevel = bandLevels[#bandLevels - 1]
		local lastBand = PrestigeConfig.TUNING_BANDS[lastLevel]
		local previousBand = PrestigeConfig.TUNING_BANDS[previousLevel]
		local levelDelta = level - lastLevel
		local levelSpan = lastLevel - previousLevel

		local extrapolated = {
			speedCapMultiplier = extrapolateRange(
				previousBand and previousBand.speedCapMultiplier,
				lastBand and lastBand.speedCapMultiplier,
				levelDelta,
				levelSpan,
				1.0
			),
			gravity = extrapolateRange(
				previousBand and previousBand.gravity,
				lastBand and lastBand.gravity,
				levelDelta,
				levelSpan,
				100
			),
			jumpPowerMultiplier = extrapolateRange(
				previousBand and previousBand.jumpPowerMultiplier,
				lastBand and lastBand.jumpPowerMultiplier,
				levelDelta,
				levelSpan,
				0.50
			),
		}

		return copyBand(extrapolated)
	end

	return copyBand(selectedBand or PrestigeConfig.TUNING_BANDS[0])
end

function PrestigeConfig.getSpeedGraduationStatKeyForCurrentLevel(currentLevel)
	return getSpeedGraduationStatKeyForCurrentLevel(currentLevel)
end

function PrestigeConfig.getSpeedGraduationStatPathForTargetLevel(targetLevel)
	return getSpeedGraduationStatPathForTargetLevel(targetLevel)
end

function PrestigeConfig.getSpeedGraduationProgressLabelForTargetLevel(targetLevel)
	return getSpeedGraduationProgressLabelForTargetLevel(targetLevel)
end

function PrestigeConfig.getSpeedGraduationTargetForLevel(targetLevel)
	local level = math.max(1, math.floor(tonumber(targetLevel) or 1))
	local currentLevel = math.max(0, level - 1)
	local band = PrestigeConfig.getTuningBand(currentLevel)
	local speedRange = type(band) == "table" and band.speedCapMultiplier or nil
	local speedMax = tonumber(speedRange and speedRange.max)
	if speedMax ~= nil then
		return speedMax
	end
	return tonumber(speedRange and speedRange.min)
end

function PrestigeConfig.getSpeedGraduationToleranceForLevel(targetLevel)
	local level = math.max(1, math.floor(tonumber(targetLevel) or 1))
	local currentLevel = math.max(0, level - 1)
	local band = PrestigeConfig.getTuningBand(currentLevel)
	local speedRange = type(band) == "table" and band.speedCapMultiplier or nil
	local step = tonumber(speedRange and speedRange.step) or 0.05
	return math.max(0.01, step * 0.51)
end

function PrestigeConfig.getDefinedTuningBandLevels()
	return cloneNumberArray(getDefinedBandLevels())
end

function PrestigeConfig.getConfiguredPrestigePlan()
	local plan = PrestigeConfig.PRESTIGE_PLAN or {}
	return {
		totalLevels = if tonumber(plan.TOTAL_LEVELS) ~= nil then math.max(0, math.floor(tonumber(plan.TOTAL_LEVELS))) else nil,
		allowGeneratedRequirements = plan.ALLOW_GENERATED_REQUIREMENTS ~= false,
		highestExplicitRequirementLevel = #PrestigeConfig.LEVELS,
		highestTuningUpgradeLevel = getHighestNumericKey(PrestigeConfig.TUNING_PRESTIGE_UPGRADES),
		highestTuningBandLevel = PrestigeConfig.getHighestDefinedTuningBandLevel and PrestigeConfig.getHighestDefinedTuningBandLevel() or 0,
	}
end

function PrestigeConfig.getTuningBandChangeLevelsForKey(tuningKey)
	if type(tuningKey) ~= "string" or tuningKey == "" then
		return {}
	end

	if not cachedBandChangeLevelsByKey then
		cachedBandChangeLevelsByKey = {}
	end

	local cached = cachedBandChangeLevelsByKey[tuningKey]
	if cached then
		return cloneNumberArray(cached)
	end

	local changeLevels = {}
	local previousRange = nil
	for _, level in ipairs(getDefinedBandLevels()) do
		local band = PrestigeConfig.TUNING_BANDS[level]
		local range = type(band) == "table" and band[tuningKey] or nil
		if #changeLevels == 0 or not rangesEquivalent(previousRange, range) then
			table.insert(changeLevels, level)
		end

		if type(range) == "table" then
			previousRange = {
				min = tonumber(range.min),
				max = tonumber(range.max),
				step = tonumber(range.step),
			}
		else
			previousRange = nil
		end
	end

	cachedBandChangeLevelsByKey[tuningKey] = changeLevels
	return cloneNumberArray(changeLevels)
end

function PrestigeConfig.getHighestDefinedTuningBandLevel()
	local levels = getDefinedBandLevels()
	return levels[#levels] or 0
end

function PrestigeConfig.getBestScoreRequirementForLevel(level)
	local levelDef = PrestigeConfig.getLevel(level)
	if not levelDef then
		return nil
	end

	local fromProgress = findBestScoreTargetInProgress(levelDef)
	if fromProgress then
		return fromProgress
	end

	return findBestScoreTargetInCondition(levelDef.condition)
end

local function copyTrackingThresholds(thresholds)
	return {
		speedCapMultiplier = tonumber(thresholds and thresholds.speedCapMultiplier) or 0,
		gravity = tonumber(thresholds and thresholds.gravity) or 0,
	}
end

local function getPriorLevelReachableMax(levelNumber, tuningKey)
	local priorLevel = math.max(0, math.floor(tonumber(levelNumber) or 0) - 1)
	local priorBand = PrestigeConfig.getTuningBand(priorLevel)
	if type(priorBand) ~= "table" then
		return nil
	end

	local range = priorBand[tuningKey]
	if type(range) ~= "table" then
		return nil
	end

	local maxValue = tonumber(range.max)
	if maxValue then
		return maxValue
	end

	return tonumber(range.min)
end

local function clampThresholdForLevel(levelNumber, levelDef, thresholds)
	for trackedPath, tuningKey in pairs(TRACKED_PATH_TO_TUNING_KEY) do
		if levelRequiresTrackedPath(levelDef, trackedPath) then
			local reachableMax = getPriorLevelReachableMax(levelNumber, tuningKey)
			if reachableMax ~= nil then
				thresholds[tuningKey] = math.min(tonumber(thresholds[tuningKey]) or reachableMax, reachableMax)
			end
		end
	end
end

function PrestigeConfig.getEffectiveTrackingThresholds()
	if cachedEffectiveTrackingThresholds then
		return copyTrackingThresholds(cachedEffectiveTrackingThresholds)
	end

	-- Ensure every requirement that reads tracked high-speed/high-gravity stats
	-- is reachable with the prior prestige tier's unlocked tuning range.
	local tracking = PrestigeConfig.TRACKING or {}
	local defaultsBand = PrestigeConfig.getTuningBand(0)
	local defaultSpeedMax = tonumber(defaultsBand and defaultsBand.speedCapMultiplier and defaultsBand.speedCapMultiplier.max) or 1
	local defaultGravityMax = tonumber(defaultsBand and defaultsBand.gravity and defaultsBand.gravity.max) or 100

	local thresholds = {
		speedCapMultiplier = tonumber(tracking.SPEED_THRESHOLD) or defaultSpeedMax,
		gravity = tonumber(tracking.GRAVITY_THRESHOLD) or defaultGravityMax,
	}

	for levelNumber = 1, #PrestigeConfig.LEVELS do
		local levelDef = PrestigeConfig.getLevel(levelNumber)
		clampThresholdForLevel(levelNumber, levelDef, thresholds)
	end

	if PrestigeConfig.UNBOUNDED_PRESTIGE == true then
		local firstGeneratedLevel = #PrestigeConfig.LEVELS + 1
		local generatedLevel = PrestigeConfig.getLevel(firstGeneratedLevel)
		clampThresholdForLevel(firstGeneratedLevel, generatedLevel, thresholds)
	end

	cachedEffectiveTrackingThresholds = copyTrackingThresholds(thresholds)
	return copyTrackingThresholds(cachedEffectiveTrackingThresholds)
end

function PrestigeConfig.getNextPrestigeMission(currentPrestigeLevel)
	local currentLevel = math.max(0, math.floor(tonumber(currentPrestigeLevel) or 0))
	local nextLevel = currentLevel + 1
	local levelDef = PrestigeConfig.getLevel(nextLevel)
	if not levelDef then
		return nil
	end

	local missionCfg = PrestigeConfig.PRESTIGE_MISSION or {}
	local idPrefix = tostring(missionCfg.ID_PREFIX or "prestige_next_score")
	local titleFormat = tostring(missionCfg.TITLE_FORMAT or "Prestige %d Mission")
	local description = tostring(levelDef.requirementText or "")
	if description == "" then
		local fallbackDescriptionFormat = tostring(missionCfg.DESCRIPTION_FORMAT or "Reach requirements to unlock Prestige %d.")
		description = string.format(fallbackDescriptionFormat, nextLevel, nextLevel)
	end

	return {
		id = string.format("%s_%d", idPrefix, nextLevel),
		title = string.format(titleFormat, nextLevel),
		description = description,
		condition = cloneTableDeep(levelDef.condition),
		progress = cloneTableDeep(levelDef.progress),
		rewards = buildPrestigeMissionRewards(nextLevel),
	}
end

function PrestigeConfig.getNextPrestigeMissions(currentPrestigeLevel)
	local baseMission = PrestigeConfig.getNextPrestigeMission(currentPrestigeLevel)
	if not baseMission then
		return nil
	end

	local condition = baseMission.condition
	local progress = baseMission.progress
	local conditions = if type(condition) == "table" then condition.conditions else nil

	if type(condition) ~= "table"
		or condition.type ~= "all"
		or type(conditions) ~= "table"
		or #conditions <= 1
		or type(progress) ~= "table"
		or #progress ~= #conditions then
		return { baseMission }
	end

	local missions = table.create(#conditions)
	for index, subCondition in ipairs(conditions) do
		local progressRow = progress[index]
		local rowLabel = "Requirement " .. tostring(index)
		local rowTarget = nil

		if type(progressRow) == "table" then
			if progressRow.label ~= nil then
				rowLabel = tostring(progressRow.label)
			end
			rowTarget = tonumber(progressRow.target)
		end

		local partDescription
		if rowTarget then
			partDescription = string.format("%s (%d)", rowLabel, math.floor(rowTarget + 0.5))
		else
			partDescription = rowLabel
		end

		table.insert(missions, {
			id = string.format("%s_req_%d", baseMission.id, index),
			title = string.format("%s - %s", baseMission.title, rowLabel),
			description = partDescription,
			condition = cloneTableDeep(subCondition),
			progress = cloneTableDeep(progressRow),
			rewards = cloneRewards(baseMission.rewards),
		})
	end

	return missions
end

return PrestigeConfig
