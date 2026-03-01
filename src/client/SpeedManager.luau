--[[
	SpeedManager.luau
	
	Handles progressive speed increase over time (like Jetpack Joyride).
	Tracks current speed multiplier and provides methods to get current speed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RuntimeTuning = require(ReplicatedStorage.Shared.RuntimeTuning)

local SpeedManager = {}
SpeedManager.__index = SpeedManager

local speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
local gameStartTime = 0
local isRunning = false
local debugSpeedLogEnabled = false
local debugSpeedLogLastPrintAt = 0
local DEBUG_SPEED_LOG_INTERVAL = 1.0
local debugPipeSpacingLast = nil
local debugPipeSpacingLastAt = 0
local debugPipeSpacingLastSpacingMultiplier = nil
local debugPipeSpacingRecentSamples = {}
local DEBUG_PIPE_SPACING_SAMPLE_WINDOW = 8
local debugPipeGapXMinLast = nil
local debugPipeGapXMaxLast = nil
local debugPipeGapXEffectiveSpeedLast = nil
local debugPipeGapYLast = nil
local debugPipeGapYMinLast = nil
local debugPipeGapYMaxLast = nil
local debugPipeGapYMaxDeltaLast = nil

local function resetDebugPipeSpacingSamples()
	debugPipeSpacingLast = nil
	debugPipeSpacingLastAt = 0
	debugPipeSpacingLastSpacingMultiplier = nil
	debugPipeSpacingRecentSamples = {}
	debugPipeGapXMinLast = nil
	debugPipeGapXMaxLast = nil
	debugPipeGapXEffectiveSpeedLast = nil
	debugPipeGapYLast = nil
	debugPipeGapYMinLast = nil
	debugPipeGapYMaxLast = nil
	debugPipeGapYMaxDeltaLast = nil
end

local function getDebugPipeSpacingAverage()
	local count = #debugPipeSpacingRecentSamples
	if count <= 0 then
		return nil, 0
	end

	local total = 0
	for _, sample in ipairs(debugPipeSpacingRecentSamples) do
		total = total + sample
	end
	return total / count, count
end

local function getSelectedSpeedRampMultiplier()
	local configuredRamp = nil
	if RuntimeTuning.getActiveSpeedRampMultiplier then
		configuredRamp = tonumber(RuntimeTuning.getActiveSpeedRampMultiplier())
	else
		configuredRamp = tonumber(RuntimeTuning.getActiveSpeedCapMultiplier())
	end

	local defaultRamp = tonumber(GameConfig.SPEED.RAMP_RATE_MULTIPLIER_DEFAULT)
		or tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER)
		or 1.0
	return math.max(0, configuredRamp or defaultRamp)
end

local function getInternalSpeedMultiplierCap()
	local configuredCap = tonumber(GameConfig.SPEED.INTERNAL_MULTIPLIER_CAP)
		or tonumber(GameConfig.SPEED.MAX_MULTIPLIER)
		or 2.5
	local initialMultiplier = tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1
	return math.max(initialMultiplier, configuredCap)
end

local function getEffectiveIncreaseRate(rampRateMultiplier)
	local baseIncreaseRate = tonumber(GameConfig.SPEED.INCREASE_RATE) or 0
	local rampScale = math.max(0, tonumber(rampRateMultiplier) or getSelectedSpeedRampMultiplier())
	return baseIncreaseRate * rampScale
end

local function lerp(a, b, t)
	return (tonumber(a) or 0) + ((tonumber(b) or 0) - (tonumber(a) or 0)) * (tonumber(t) or 0)
end

local function clamp01(value)
	return math.clamp(tonumber(value) or 0, 0, 1)
end

local function easeAlpha(alpha, easingName)
	local t = clamp01(alpha)
	local easing = string.lower(tostring(easingName or "outCubic"))

	if easing == "linear" then
		return t
	end
	if easing == "outsine" then
		return math.sin((t * math.pi) * 0.5)
	end
	if easing == "inoutsine" then
		return -(math.cos(math.pi * t) - 1) * 0.5
	end
	if easing == "smoothstep" then
		return t * t * (3 - (2 * t))
	end

	-- Default: ease-out cubic (fast early adaptation, gentler tail)
	local oneMinus = 1 - t
	return 1 - (oneMinus * oneMinus * oneMinus)
end

local function getUnifiedProgressionProfile()
	local speedCfg = GameConfig.SPEED or {}
	local profile = speedCfg.PROGRESSION_PROFILE
	if type(profile) ~= "table" or profile.ENABLED ~= true then
		return nil
	end
	return profile
end

local function getActiveSpeedSettingRange()
	local speedCfg = GameConfig.SPEED or {}
	local defaultMin = tonumber(speedCfg.RAMP_RATE_MULTIPLIER_DEFAULT)
		or tonumber(speedCfg.INITIAL_MULTIPLIER)
		or 1.0
	local defaultMax = tonumber(speedCfg.MAX_MULTIPLIER) or defaultMin

	local minValue = defaultMin
	local maxValue = math.max(defaultMin, defaultMax)

	if RuntimeTuning.getActiveLimits then
		local limits = RuntimeTuning.getActiveLimits()
		local speedLimits = type(limits) == "table" and limits.speedCapMultiplier or nil
		local runtimeMin = tonumber(speedLimits and speedLimits.min)
		local runtimeMax = tonumber(speedLimits and speedLimits.max)
		if runtimeMin then
			minValue = runtimeMin
		end
		if runtimeMax then
			maxValue = runtimeMax
		end
		if maxValue < minValue then
			maxValue = minValue
		end
	end

	return minValue, maxValue
end

local function getNormalizedSpeedSetting(settingOverride)
	local settingValue = tonumber(settingOverride)
	if settingValue == nil then
		settingValue = getSelectedSpeedRampMultiplier()
	end

	local minSetting, maxSetting = getActiveSpeedSettingRange()
	if maxSetting <= minSetting then
		return 0, math.clamp(settingValue, minSetting, minSetting), minSetting, maxSetting
	end

	local clampedSetting = math.clamp(settingValue, minSetting, maxSetting)
	local normalized = (clampedSetting - minSetting) / (maxSetting - minSetting)
	return clamp01(normalized), clampedSetting, minSetting, maxSetting
end

local function sampleCurvePoints(alpha, points)
	if type(points) ~= "table" or #points == 0 then
		return nil
	end

	local t = clamp01(alpha)
	local first = points[1]
	if type(first) ~= "table" then
		return nil
	end

	local firstT = clamp01(first.t)
	local firstValue = clamp01(first.value)
	if t <= firstT then
		return firstValue
	end

	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		if type(a) == "table" and type(b) == "table" then
			local at = clamp01(a.t)
			local bt = clamp01(b.t)
			local av = clamp01(a.value)
			local bv = clamp01(b.value)
			if t <= bt then
				local segmentSpan = bt - at
				if segmentSpan <= 0 then
					return bv
				end
				local localT = (t - at) / segmentSpan
				return clamp01(lerp(av, bv, localT))
			end
		end
	end

	local last = points[#points]
	if type(last) == "table" then
		return clamp01(last.value)
	end

	return nil
end

local function getRunElapsedTime()
	if not isRunning or gameStartTime <= 0 then
		return 0
	end
	return math.max(0, tick() - gameStartTime)
end

local function getUnifiedProgressionStateAtElapsed(elapsedSeconds, settingOverride)
	local profile = getUnifiedProgressionProfile()
	if not profile then
		return nil
	end

	local speedCfg = GameConfig.SPEED or {}
	local baseForwardSpeed = math.max(0.0001, tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0.0001)
	local initialMultiplier = tonumber(speedCfg.INITIAL_MULTIPLIER) or 1
	local startSpeed = tonumber(profile.START_SPEED) or (baseForwardSpeed * initialMultiplier)
	startSpeed = math.max(0, startSpeed)

	local rawNormalizedSetting, clampedSetting, minSetting, maxSetting = getNormalizedSpeedSetting(settingOverride)
	local normalizedSetting = rawNormalizedSetting
	local targetExponent = tonumber(profile.TARGET_SPEED_EXPONENT) or 1.0
	if targetExponent > 0 and targetExponent ~= 1 then
		normalizedSetting = normalizedSetting ^ targetExponent
	end

	local rawMinTargetSpeed = tonumber(profile.MIN_TARGET_SPEED) or startSpeed
	local rawMaxTargetSpeed = tonumber(profile.MAX_TARGET_SPEED) or rawMinTargetSpeed
	local minTargetSpeed = math.max(startSpeed, math.min(rawMinTargetSpeed, rawMaxTargetSpeed))
	local maxTargetSpeed = math.max(minTargetSpeed, rawMaxTargetSpeed)
	local targetSpeed = lerp(minTargetSpeed, maxTargetSpeed, normalizedSetting)

	local hardMaxForwardSpeed = tonumber(speedCfg.MAX_FORWARD_SPEED)
	if hardMaxForwardSpeed then
		targetSpeed = math.min(targetSpeed, hardMaxForwardSpeed)
	end
	targetSpeed = math.max(startSpeed, targetSpeed)

	local minTimeToTarget = tonumber(profile.MIN_TIME_TO_TARGET) or 24
	local maxTimeToTarget = tonumber(profile.MAX_TIME_TO_TARGET) or minTimeToTarget
	if maxTimeToTarget < minTimeToTarget then
		maxTimeToTarget = minTimeToTarget
	end

	local timeSettingAlpha = rawNormalizedSetting
	local timeExponent = tonumber(profile.TIME_TO_TARGET_EXPONENT) or 1.0
	if timeExponent > 0 and timeExponent ~= 1 then
		timeSettingAlpha = timeSettingAlpha ^ timeExponent
	end

	-- Lower setting => longer time to target. Higher setting => shorter.
	local timeToTarget = lerp(maxTimeToTarget, minTimeToTarget, timeSettingAlpha)
	timeToTarget = math.max(0.001, tonumber(timeToTarget) or minTimeToTarget)

	local elapsed = math.max(0, tonumber(elapsedSeconds) or 0)
	local delaySeconds = math.max(0, tonumber(profile.START_DELAY) or 0)
	local activeElapsed = math.max(0, elapsed - delaySeconds)
	local rawAlpha = clamp01(activeElapsed / timeToTarget)

	local curveAlpha = sampleCurvePoints(rawAlpha, profile.CURVE_POINTS)
	if curveAlpha == nil then
		curveAlpha = easeAlpha(rawAlpha, profile.EASING)
	end

	local speed = lerp(startSpeed, targetSpeed, curveAlpha)
	if hardMaxForwardSpeed then
		speed = math.min(speed, hardMaxForwardSpeed)
	end
	speed = math.max(0, speed)

	local effectiveMultiplier = speed / baseForwardSpeed
	local targetMultiplier = targetSpeed / baseForwardSpeed

	return {
		speed = speed,
		multiplier = effectiveMultiplier,
		targetSpeed = targetSpeed,
		targetMultiplier = targetMultiplier,
		timeToTarget = timeToTarget,
		delaySeconds = delaySeconds,
		elapsedSeconds = elapsed,
		rawAlpha = rawAlpha,
		curveAlpha = curveAlpha,
		setting = clampedSetting,
		minSetting = minSetting,
		maxSetting = maxSetting,
		normalizedSetting = rawNormalizedSetting,
		startSpeed = startSpeed,
	}
end

local function getUnifiedProgressionState()
	return getUnifiedProgressionStateAtElapsed(getRunElapsedTime(), getSelectedSpeedRampMultiplier())
end

local function getChallengeFloorSpeedAtElapsed(elapsedSeconds, rampRateMultiplier)
	if getUnifiedProgressionProfile() then
		return nil
	end

	local speedCfg = GameConfig.SPEED or {}
	local rampCfg = speedCfg.CHALLENGE_FLOOR_RAMP
	if type(rampCfg) ~= "table" or rampCfg.ENABLED == false then
		return nil
	end

	local maxForwardSpeed = tonumber(speedCfg.MAX_FORWARD_SPEED)
	local configuredTarget = tonumber(rampCfg.TARGET_SPEED)
	local initialMultiplier = tonumber(speedCfg.INITIAL_MULTIPLIER) or 1
	local startSpeed = (tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0) * initialMultiplier

	local targetSpeed = configuredTarget or maxForwardSpeed
	if not targetSpeed then
		return nil
	end
	targetSpeed = math.max(startSpeed, targetSpeed)
	if maxForwardSpeed then
		targetSpeed = math.min(targetSpeed, maxForwardSpeed)
	end

	local delaySeconds = math.max(0, tonumber(rampCfg.START_DELAY) or 0)
	local durationSeconds = math.max(0.001, tonumber(rampCfg.DURATION) or 60)
	local elapsed = math.max(0, tonumber(elapsedSeconds) or 0)
	local rampScale = math.max(0, tonumber(rampRateMultiplier) or getSelectedSpeedRampMultiplier())
	local rampedElapsed = math.max(0, elapsed - delaySeconds) * rampScale
	local rawAlpha = rampedElapsed / durationSeconds
	local easedAlpha = easeAlpha(rawAlpha, rampCfg.EASING)

	return startSpeed + ((targetSpeed - startSpeed) * easedAlpha)
end

local function getChallengeFloorSpeed()
	return getChallengeFloorSpeedAtElapsed(getRunElapsedTime(), getSelectedSpeedRampMultiplier())
end

--[[
	Starts the speed progression (call when game starts).
]]
function SpeedManager.start()
	speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
	gameStartTime = tick()
	isRunning = true
	debugSpeedLogLastPrintAt = gameStartTime
end

--[[
	Stops the speed progression (call when game ends).
]]
function SpeedManager.stop()
	isRunning = false
end

--[[
	Updates the speed multiplier based on elapsed time.
	Should be called every frame during gameplay.
	
]]
function SpeedManager.update()
	if not isRunning then
		return
	end

	local now = tick()
	local timeElapsed = now - gameStartTime
	local unifiedState = getUnifiedProgressionStateAtElapsed(timeElapsed, nil)
	if unifiedState then
		speedMultiplier = tonumber(unifiedState.multiplier) or (tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1)
	else
		local rampRateMultiplier = getSelectedSpeedRampMultiplier()
		speedMultiplier = (tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1) + (timeElapsed * getEffectiveIncreaseRate(rampRateMultiplier))

		-- Cap to hidden runtime multiplier cap (user tuning now controls ramp rate, not cap).
		local speedCap = getInternalSpeedMultiplierCap()
		if speedMultiplier > speedCap then
			speedMultiplier = speedCap
		end
	end

	if debugSpeedLogEnabled and (now - debugSpeedLogLastPrintAt) >= DEBUG_SPEED_LOG_INTERVAL then
		local currentSpeed = SpeedManager.getCurrentSpeed()
		local currentSpeedNumber = tonumber(currentSpeed) or 0
		local elapsed = math.max(0, now - gameStartTime)
		local logProgressionState = unifiedState or getUnifiedProgressionStateAtElapsed(elapsed, nil)
		local message = string.format(
			"[SpeedDebug] t=%.1fs speed=%.2f studs/s (multiplier=%.2fx)",
			elapsed,
			currentSpeedNumber,
			tonumber(speedMultiplier) or 0
		)

		if logProgressionState then
			message = message .. string.format(
				" [setting=%.2fx target=%.0f ttt=%.0fs prog=%.0f%%]",
				tonumber(logProgressionState.setting) or 0,
				tonumber(logProgressionState.targetSpeed) or 0,
				tonumber(logProgressionState.timeToTarget) or 0,
				(clamp01(logProgressionState.rawAlpha) * 100)
			)
		end

		if debugPipeSpacingLast ~= nil then
			local avgSpacing, sampleCount = getDebugPipeSpacingAverage()
			local spacingAge = math.max(0, now - (tonumber(debugPipeSpacingLastAt) or now))
			local spacingSegment = string.format(" | spacing=%.2f studs", tonumber(debugPipeSpacingLast) or 0)

			local detailParts = {}
			if sampleCount > 1 and avgSpacing then
				table.insert(detailParts, string.format("avg%d=%.2f", sampleCount, avgSpacing))
			end
			if currentSpeedNumber > 0 then
				table.insert(detailParts, string.format("~%.0fms", ((tonumber(debugPipeSpacingLast) or 0) / currentSpeedNumber) * 1000))
			end
			if debugPipeSpacingLastSpacingMultiplier then
				table.insert(detailParts, string.format("spacingMul=%.2fx", tonumber(debugPipeSpacingLastSpacingMultiplier) or 0))
			end
			table.insert(detailParts, string.format("age=%.1fs", spacingAge))

			if #detailParts > 0 then
				spacingSegment = spacingSegment .. " (" .. table.concat(detailParts, ", ") .. ")"
			end

			message = message .. spacingSegment
		else
			message = message .. " | spacing=n/a"
		end

		if debugPipeGapXMinLast ~= nil and debugPipeGapXMaxLast ~= nil then
			local gapXSegment = string.format(
				" | gapXRange=%.2f..%.2f",
				tonumber(debugPipeGapXMinLast) or 0,
				tonumber(debugPipeGapXMaxLast) or 0
			)

			if debugPipeGapXEffectiveSpeedLast ~= nil then
				gapXSegment = gapXSegment .. string.format(
					" (eff=%.2fx)",
					tonumber(debugPipeGapXEffectiveSpeedLast) or 0
				)
			end

			message = message .. gapXSegment
		else
			message = message .. " | gapXRange=n/a"
		end

		if debugPipeGapYMinLast ~= nil and debugPipeGapYMaxLast ~= nil then
			local gapSegment = string.format(
				" | gapYRange=%.2f..%.2f",
				tonumber(debugPipeGapYMinLast) or 0,
				tonumber(debugPipeGapYMaxLast) or 0
			)

			local gapDetailParts = {}
			if debugPipeGapYLast ~= nil then
				table.insert(gapDetailParts, string.format("gapY=%.2f", tonumber(debugPipeGapYLast) or 0))
			end
			if debugPipeGapYMaxDeltaLast ~= nil then
				table.insert(gapDetailParts, string.format("maxDelta=%.2f", tonumber(debugPipeGapYMaxDeltaLast) or 0))
			end

			if #gapDetailParts > 0 then
				gapSegment = gapSegment .. " (" .. table.concat(gapDetailParts, ", ") .. ")"
			end

			message = message .. gapSegment
		else
			message = message .. " | gapYRange=n/a"
		end

		print(message)
		debugSpeedLogLastPrintAt = now
	end
end

--[[
	Gets the current speed multiplier.
	@return number - Current speed multiplier
]]
function SpeedManager.getCurrentMultiplier()
	if isRunning then
		local unifiedState = getUnifiedProgressionState()
		if unifiedState then
			speedMultiplier = tonumber(unifiedState.multiplier) or speedMultiplier
		end
	end
	return speedMultiplier
end

function SpeedManager.getPredictedMultiplierAtElapsed(elapsedSeconds, rampRateMultiplier, speedMultiplierCap)
	local unifiedState = getUnifiedProgressionStateAtElapsed(elapsedSeconds, rampRateMultiplier)
	if unifiedState then
		return tonumber(unifiedState.multiplier) or (tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1)
	end

	local elapsed = math.max(0, tonumber(elapsedSeconds) or 0)
	local initialMultiplier = tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER) or 1
	local increaseRate = getEffectiveIncreaseRate(rampRateMultiplier)
	local multiplier = initialMultiplier + (elapsed * increaseRate)
	local cap = tonumber(speedMultiplierCap) or getInternalSpeedMultiplierCap()
	cap = math.max(initialMultiplier, tonumber(cap) or initialMultiplier)
	return math.min(multiplier, cap)
end

function SpeedManager.getPredictedSpeedAtElapsed(elapsedSeconds, rampRateMultiplier, speedMultiplierCap)
	local unifiedState = getUnifiedProgressionStateAtElapsed(elapsedSeconds, rampRateMultiplier)
	if unifiedState then
		return tonumber(unifiedState.speed) or 0, tonumber(unifiedState.multiplier) or 0
	end

	local elapsed = math.max(0, tonumber(elapsedSeconds) or 0)
	local predictedMultiplier = SpeedManager.getPredictedMultiplierAtElapsed(elapsed, rampRateMultiplier, speedMultiplierCap)
	local speed = (tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0) * predictedMultiplier

	local challengeFloorSpeed = getChallengeFloorSpeedAtElapsed(elapsed, rampRateMultiplier)
	if challengeFloorSpeed then
		speed = math.max(speed, challengeFloorSpeed)
	end

	local maxForwardSpeed = tonumber(GameConfig.SPEED and GameConfig.SPEED.MAX_FORWARD_SPEED)
	if maxForwardSpeed then
		speed = math.min(speed, maxForwardSpeed)
	end

	return speed, predictedMultiplier
end

function SpeedManager.getTargetMultiplierCapForRampSetting(rampRateMultiplier)
	local unifiedState = getUnifiedProgressionStateAtElapsed(0, rampRateMultiplier)
	if unifiedState and unifiedState.targetMultiplier then
		return tonumber(unifiedState.targetMultiplier) or getInternalSpeedMultiplierCap()
	end
	return getInternalSpeedMultiplierCap()
end

function SpeedManager.getCurrentTargetMultiplierCap()
	return SpeedManager.getTargetMultiplierCapForRampSetting(getSelectedSpeedRampMultiplier())
end

function SpeedManager.getCurrentProgressionState()
	if not isRunning then
		return getUnifiedProgressionStateAtElapsed(0, nil)
	end
	return getUnifiedProgressionState()
end

--[[
	Gets the current forward speed after multiplier + long-run challenge ramp.
	@return number - Current forward speed in studs per second
]]
function SpeedManager.getCurrentSpeed()
	local unifiedState = getUnifiedProgressionState()
	if unifiedState then
		speedMultiplier = tonumber(unifiedState.multiplier) or speedMultiplier
		return tonumber(unifiedState.speed) or 0
	end

	local speed = (tonumber(PlayerConfig.BASE_FORWARD_SPEED) or 0) * speedMultiplier

	-- Layer in a time-based challenge floor so low selected speed still ramps
	-- toward meaningful pressure over long runs.
	local challengeFloorSpeed = getChallengeFloorSpeed()
	if challengeFloorSpeed then
		speed = math.max(speed, challengeFloorSpeed)
	end

	local maxForwardSpeed = tonumber(GameConfig.SPEED and GameConfig.SPEED.MAX_FORWARD_SPEED)
	if maxForwardSpeed then
		speed = math.min(speed, maxForwardSpeed)
	end

	return speed
end

--[[
	Resets the speed to initial value.
]]
function SpeedManager.reset()
	speedMultiplier = GameConfig.SPEED.INITIAL_MULTIPLIER
	gameStartTime = 0
	isRunning = false
	debugSpeedLogLastPrintAt = 0
end

--[[
	Enables/disables the once-per-second speed debug console log.
	@return boolean - Final enabled state
]]
function SpeedManager.setDebugSpeedLogEnabled(enabled)
	debugSpeedLogEnabled = (enabled == true)
	if isRunning then
		debugSpeedLogLastPrintAt = tick()
	end
	warn(string.format("[SpeedDebug] Console speed log %s.", debugSpeedLogEnabled and "ENABLED" or "DISABLED"))
	return debugSpeedLogEnabled
end

function SpeedManager.recordDebugPipeSpacingSample(spacing, metadata)
	local spacingNumber = tonumber(spacing)
	if not spacingNumber or spacingNumber <= 0 then
		return
	end

	debugPipeSpacingLast = spacingNumber
	debugPipeSpacingLastAt = tick()
	debugPipeSpacingLastSpacingMultiplier = nil
	if type(metadata) == "table" and metadata.spacingSpeedMultiplier ~= nil then
		debugPipeSpacingLastSpacingMultiplier = tonumber(metadata.spacingSpeedMultiplier)
	end
	debugPipeGapXMinLast = if type(metadata) == "table" then tonumber(metadata.gapXMin) else nil
	debugPipeGapXMaxLast = if type(metadata) == "table" then tonumber(metadata.gapXMax) else nil
	debugPipeGapXEffectiveSpeedLast = if type(metadata) == "table" then tonumber(metadata.gapXEffectiveSpeed) else nil
	debugPipeGapYLast = if type(metadata) == "table" then tonumber(metadata.gapY) else nil
	debugPipeGapYMinLast = if type(metadata) == "table" then tonumber(metadata.gapYMin) else nil
	debugPipeGapYMaxLast = if type(metadata) == "table" then tonumber(metadata.gapYMax) else nil
	debugPipeGapYMaxDeltaLast = if type(metadata) == "table" then tonumber(metadata.gapYMaxDelta) else nil

	table.insert(debugPipeSpacingRecentSamples, spacingNumber)
	while #debugPipeSpacingRecentSamples > DEBUG_PIPE_SPACING_SAMPLE_WINDOW do
		table.remove(debugPipeSpacingRecentSamples, 1)
	end
end

function SpeedManager.clearDebugPipeSpacingSamples()
	resetDebugPipeSpacingSamples()
end

function SpeedManager.toggleDebugSpeedLog()
	return SpeedManager.setDebugSpeedLogEnabled(not debugSpeedLogEnabled)
end

function SpeedManager.isDebugSpeedLogEnabled()
	return debugSpeedLogEnabled == true
end

return SpeedManager
