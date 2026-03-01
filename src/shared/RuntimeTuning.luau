--[[
	RuntimeTuning.luau

Single runtime source for gameplay tuning values:
	- speed ramp multiplier (legacy field name: speedCapMultiplier)
	- gravity
	- jump power multiplier

Modules that affect gameplay should read from this layer instead of
directly from static config constants:
	- PlayerController -> gravity
	- PlayerController -> jump force multiplier
	- SpeedManager -> speed ramp multiplier (plus hidden internal cap from GameConfig)
	- PipeManager pre-spawn estimation -> speed ramp multiplier
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerConfig = require(ReplicatedStorage.Shared.PlayerConfig)

local RuntimeTuning = {}

local DEFAULT_TUNING = {
	speedCapMultiplier = tonumber(GameConfig.SPEED.RAMP_RATE_MULTIPLIER_DEFAULT)
		or tonumber(GameConfig.SPEED.INITIAL_MULTIPLIER)
		or 1.0,
	gravity = 150,
	jumpPowerMultiplier = 0.75,
}

local DEFAULT_LIMITS = {
	speedCapMultiplier = {
		min = DEFAULT_TUNING.speedCapMultiplier,
		max = DEFAULT_TUNING.speedCapMultiplier,
		step = 0.05,
	},
	gravity = {
		min = DEFAULT_TUNING.gravity,
		max = DEFAULT_TUNING.gravity,
		step = 1,
	},
	jumpPowerMultiplier = {
		min = DEFAULT_TUNING.jumpPowerMultiplier,
		max = DEFAULT_TUNING.jumpPowerMultiplier,
		step = 0.05,
	},
}

local activeTuning = {
	speedCapMultiplier = DEFAULT_TUNING.speedCapMultiplier,
	gravity = DEFAULT_TUNING.gravity,
	jumpPowerMultiplier = DEFAULT_TUNING.jumpPowerMultiplier,
}
local activeLimits = nil

local function cloneTuning(tuning)
	return {
		speedCapMultiplier = tonumber(tuning and tuning.speedCapMultiplier) or DEFAULT_TUNING.speedCapMultiplier,
		gravity = tonumber(tuning and tuning.gravity) or DEFAULT_TUNING.gravity,
		jumpPowerMultiplier = tonumber(tuning and tuning.jumpPowerMultiplier) or DEFAULT_TUNING.jumpPowerMultiplier,
	}
end

local function cloneLimits(limits)
	local source = limits or DEFAULT_LIMITS
	local speed = source.speedCapMultiplier or DEFAULT_LIMITS.speedCapMultiplier
	local gravity = source.gravity or DEFAULT_LIMITS.gravity
	local jump = source.jumpPowerMultiplier or DEFAULT_LIMITS.jumpPowerMultiplier

	local speedMin = tonumber(speed.min)
	local speedMax = tonumber(speed.max)
	local speedStep = tonumber(speed.step)
	if not speedMin then speedMin = DEFAULT_LIMITS.speedCapMultiplier.min end
	if not speedMax then speedMax = DEFAULT_LIMITS.speedCapMultiplier.max end
	if speedMax < speedMin then speedMax = speedMin end
	if speedStep and speedStep <= 0 then speedStep = nil end

	local gravityMin = tonumber(gravity.min)
	local gravityMax = tonumber(gravity.max)
	local gravityStep = tonumber(gravity.step)
	if not gravityMin then gravityMin = DEFAULT_LIMITS.gravity.min end
	if not gravityMax then gravityMax = DEFAULT_LIMITS.gravity.max end
	if gravityMax < gravityMin then gravityMax = gravityMin end
	if gravityStep and gravityStep <= 0 then gravityStep = nil end

	local jumpMin = tonumber(jump.min)
	local jumpMax = tonumber(jump.max)
	local jumpStep = tonumber(jump.step)
	if not jumpMin then jumpMin = DEFAULT_LIMITS.jumpPowerMultiplier.min end
	if not jumpMax then jumpMax = DEFAULT_LIMITS.jumpPowerMultiplier.max end
	if jumpMax < jumpMin then jumpMax = jumpMin end
	if jumpStep and jumpStep <= 0 then jumpStep = nil end

	return {
		speedCapMultiplier = {
			min = speedMin,
			max = speedMax,
			step = speedStep,
		},
		gravity = {
			min = gravityMin,
			max = gravityMax,
			step = gravityStep,
		},
		jumpPowerMultiplier = {
			min = jumpMin,
			max = jumpMax,
			step = jumpStep,
		},
	}
end

activeLimits = cloneLimits(DEFAULT_LIMITS)

local function quantize(value, step, minValue)
	if not step or step <= 0 then
		return value
	end

	local base = minValue or 0
	local snappedSteps = math.floor(((value - base) / step) + 0.5)
	return base + snappedSteps * step
end

function RuntimeTuning.getDefaultTuning()
	return cloneTuning(DEFAULT_TUNING)
end

function RuntimeTuning.getDefaultLimits()
	return cloneLimits(DEFAULT_LIMITS)
end

function RuntimeTuning.cloneTuning(tuning)
	return cloneTuning(tuning or DEFAULT_TUNING)
end

function RuntimeTuning.cloneLimits(limits)
	return cloneLimits(limits)
end

function RuntimeTuning.clampTuning(tuning, limits)
	local safeLimits = cloneLimits(limits)
	local requested = cloneTuning(tuning)

	local speed = quantize(
		math.clamp(requested.speedCapMultiplier, safeLimits.speedCapMultiplier.min, safeLimits.speedCapMultiplier.max),
		safeLimits.speedCapMultiplier.step,
		safeLimits.speedCapMultiplier.min
	)
	speed = math.clamp(speed, safeLimits.speedCapMultiplier.min, safeLimits.speedCapMultiplier.max)

	local gravity = quantize(
		math.clamp(requested.gravity, safeLimits.gravity.min, safeLimits.gravity.max),
		safeLimits.gravity.step,
		safeLimits.gravity.min
	)
	gravity = math.clamp(gravity, safeLimits.gravity.min, safeLimits.gravity.max)

	local jump = quantize(
		math.clamp(requested.jumpPowerMultiplier, safeLimits.jumpPowerMultiplier.min, safeLimits.jumpPowerMultiplier.max),
		safeLimits.jumpPowerMultiplier.step,
		safeLimits.jumpPowerMultiplier.min
	)
	jump = math.clamp(jump, safeLimits.jumpPowerMultiplier.min, safeLimits.jumpPowerMultiplier.max)

	return {
		speedCapMultiplier = speed,
		gravity = gravity,
		jumpPowerMultiplier = jump,
	}, safeLimits
end

function RuntimeTuning.getRecommendedTuning(limits)
	local safeLimits = cloneLimits(limits)
	local recommendedGravity = safeLimits.gravity.min + (safeLimits.gravity.max - safeLimits.gravity.min) * 0.65
	local recommendedJump = safeLimits.jumpPowerMultiplier.min + (safeLimits.jumpPowerMultiplier.max - safeLimits.jumpPowerMultiplier.min) * 0.6

	local tuned, _ = RuntimeTuning.clampTuning({
		speedCapMultiplier = safeLimits.speedCapMultiplier.max,
		gravity = recommendedGravity,
		jumpPowerMultiplier = recommendedJump,
	}, safeLimits)

	return tuned
end

function RuntimeTuning.setActiveTuning(tuning, limits)
	local clampedTuning, safeLimits = RuntimeTuning.clampTuning(tuning, limits)
	activeTuning = clampedTuning
	activeLimits = safeLimits
	return RuntimeTuning.getActiveTuning()
end

function RuntimeTuning.setActiveFixedTuning(tuning)
	local safeTuning = cloneTuning(tuning)
	local fixedLimits = {
		speedCapMultiplier = {
			min = safeTuning.speedCapMultiplier,
			max = safeTuning.speedCapMultiplier,
		},
		gravity = {
			min = safeTuning.gravity,
			max = safeTuning.gravity,
		},
		jumpPowerMultiplier = {
			min = safeTuning.jumpPowerMultiplier,
			max = safeTuning.jumpPowerMultiplier,
		},
	}
	return RuntimeTuning.setActiveTuning(safeTuning, fixedLimits)
end

function RuntimeTuning.resetActiveTuning()
	activeTuning = cloneTuning(DEFAULT_TUNING)
	activeLimits = cloneLimits(DEFAULT_LIMITS)
	return RuntimeTuning.getActiveTuning()
end

function RuntimeTuning.getActiveTuning()
	return cloneTuning(activeTuning)
end

function RuntimeTuning.getActiveLimits()
	return cloneLimits(activeLimits or DEFAULT_LIMITS)
end

function RuntimeTuning.getActiveSpeedCapMultiplier()
	return tonumber(activeTuning.speedCapMultiplier) or DEFAULT_TUNING.speedCapMultiplier
end

-- Clearer alias for the legacy speedCapMultiplier field.
function RuntimeTuning.getActiveSpeedRampMultiplier()
	return RuntimeTuning.getActiveSpeedCapMultiplier()
end

function RuntimeTuning.getActiveGravity()
	return tonumber(activeTuning.gravity) or DEFAULT_TUNING.gravity
end

function RuntimeTuning.getActiveJumpPowerMultiplier()
	return tonumber(activeTuning.jumpPowerMultiplier) or DEFAULT_TUNING.jumpPowerMultiplier
end

function RuntimeTuning.tuningEquals(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	local speedDiff = math.abs((tonumber(a.speedCapMultiplier) or 0) - (tonumber(b.speedCapMultiplier) or 0))
	local gravityDiff = math.abs((tonumber(a.gravity) or 0) - (tonumber(b.gravity) or 0))
	local jumpDiff = math.abs((tonumber(a.jumpPowerMultiplier) or 0) - (tonumber(b.jumpPowerMultiplier) or 0))
	return speedDiff < 0.0001 and gravityDiff < 0.0001 and jumpDiff < 0.0001
end

return RuntimeTuning
