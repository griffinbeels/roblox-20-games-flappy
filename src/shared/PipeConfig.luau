--[[
	PipeConfig.luau

	Single source of truth for all pipe configuration and spawn logic.
	Everything related to pipes lives here: dimensions, gap rules, spacing,
	styles, spawn management, and the functions that make spawn decisions.

	==========================================================================
	HOW TO ADJUST GAMEPLAY FEEL:
	==========================================================================

	GAP SIZE (difficulty):
	- GAP_MIN: Minimum gap at hardest difficulty (recommend 10-12)
	- GAP_MAX: Starting gap size (recommend 14-18 for comfortable play)
	- Largest Roblox character is ~5 studs tall, so gap should be 10+ minimum

	GAP POSITION:
	- GAP_Y_MIN/MAX: Vertical range where gap center can appear
	- GAP_Y_MAX_DELTA: Max vertical jump between consecutive gaps (fairness)

	PIPE SPACING:
	- SPACING_FLOOR/CEILING: Absolute bounds on distance between pipe pairs
	- Speed scaling makes spacing grow with player speed

	==========================================================================
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local CameraConfig = require(ReplicatedStorage.Shared.CameraConfig)

local PipeConfig = {}

--============================================================================
-- GAP CONFIGURATION
-- The vertical space between top and bottom pipes (player flies through)
--============================================================================

-- Gap size in studs (shrinks with distance for difficulty progression)
PipeConfig.GAP_MIN = 16   -- Minimum gap at max difficulty
PipeConfig.GAP_MAX = 16   -- Starting gap (easier)
PipeConfig.GAP_SHRINK_RATE = 0.003  -- Gap shrinks by this per stud traveled (0 = disabled)

-- Gap vertical position bounds (where the gap center can be placed)
-- Should be within the visible camera area (camera center is at Y=15)
PipeConfig.GAP_Y_MIN = 15   -- Lowest gap center
PipeConfig.GAP_Y_MAX = 50   -- Highest gap center

-- Max vertical change between consecutive gaps (studs)
-- Prevents unfair jumps from top to bottom of screen
PipeConfig.GAP_Y_MAX_DELTA = 10

-- Optional speed-adaptive gap variance:
-- - Slow runs: wider vertical window + larger per-gap jumps (high variance)
-- - Fast runs: shrinks back toward the legacy window + smaller jumps
-- Uses forward speed in studs/sec when available (preferred).
PipeConfig.GAP_Y_SPEED_VARIANCE = {
	enabled = true,
	slowForwardSpeed = 40,   -- ~base speed (widest variance)
	fastForwardSpeed = 110,  -- near/above legacy high-speed runs (tight variance)
	easing = "smoothstep",   -- linear | outSine | outCubic | smoothstep
	slow = {
		min = 10,
		max = 50,
		maxDelta = 10,
	},
	fast = {
		min = PipeConfig.GAP_Y_MIN,
		max = PipeConfig.GAP_Y_MAX,
		maxDelta = PipeConfig.GAP_Y_MAX_DELTA,
	},
}

--============================================================================
-- SPACING CONFIGURATION
-- Horizontal distance between pipe pairs
--============================================================================

-- Absolute clamps applied after evaluating the speed curve.
-- Keep these a little wider than your control points so tuning points can move.
PipeConfig.SPACING_FLOOR = 24
PipeConfig.SPACING_CEILING = 140

-- Speed -> spacing profile (piecewise linear interpolation between control points).
-- Each point defines the randomized spacing range [min, max] at that speed multiplier.
-- Add more points for finer control (e.g. 1.25, 1.75, 2.25) without changing code.
--
-- Design intent:
-- - Speed 1.0 feels dense (short spacing)
-- - Higher speeds progressively open up spacing for readability/reaction time
PipeConfig.SPACING_SPEED_POINTS = {
	{ speed = 1.0, min = 28, max = 42 },
	{ speed = 1.5, min = 32, max = 50 },
	{ speed = 2.0, min = 38, max = 62 },
	{ speed = 2.5, min = 46, max = 76 },
	{ speed = 3.0, min = 54, max = 92 },
	{ speed = 4.0, min = 70, max = 120 },
	{ speed = 4.5, min = 80, max = 136 },
}

-- Shapes interpolation *within* a control-point segment.
-- 1.0 = linear, >1 = slower growth early in segment, <1 = faster early growth.
PipeConfig.SPACING_SPEED_INTERP_EXPONENT = 1.0

-- Shapes randomness within the current [min, max] range.
-- 1.0 = uniform, >1 biases denser (toward min), <1 biases wider (toward max).
PipeConfig.SPACING_SAMPLE_EXPONENT = 1.0

-- Optional dynamic minimum spacing floor based on actual forward speed:
-- minSpacing >= forwardSpeed * ratio
-- Use 1.0 for "1 second of travel", 0.5 for "half a second of travel", etc.
PipeConfig.SPACING_MIN_FORWARD_SPEED_RATIO = 0.5

-- Optional cap-aware early-game relief:
-- When the configured speed cap is higher than the reference cap, spacing behaves
-- as if the run were slightly "faster" at the beginning, which prevents early
-- pipe counts from feeling too dense on high-cap runs. The effect fades out
-- automatically as the player progresses toward the cap.
PipeConfig.SPACING_CAP_START_RELIEF = {
	enabled = true,
	referenceCap = 2.5,          -- no relief at or below this cap (legacy feel)
	fullEffectCap = 4.0,         -- cap value that receives full configured relief
	maxVirtualSpeedBoost = 0.45, -- added to spacing-speed axis at run start (not player speed)
	capExponent = 1.0,           -- shapes how relief scales between referenceCap and fullEffectCap
	fadeToZeroByCapProgress = 0.40, -- effect reaches zero after this fraction of speed-cap progress
	fadeExponent = 1.2,          -- >1 keeps more relief very early, then fades more strongly
}

-- First pipe pair distance from player start
PipeConfig.FIRST_PIPE_MIN = 55
PipeConfig.FIRST_PIPE_MAX = 55

--============================================================================
-- VISUAL PROPERTIES
--============================================================================

PipeConfig.WIDTH = 8               -- Pipe thickness (X and Z studs)
PipeConfig.TOP_PIPE_EXTENSION = 30 -- Extra studs above MAX_Y so top pipes extend off-screen
PipeConfig.BOTTOM_PIPE_EXTENSION = 30 -- Extra studs below MIN_Y so bottom pipes extend below the floor

--============================================================================
-- STYLE DEFAULTS
-- Default visual properties for each pipe type. Styles only need to
-- override the fields they want to change.
--============================================================================

PipeConfig.STYLE_DEFAULTS = {
	studs = {
		shaftColor = Color3.fromRGB(0, 180, 0),
		lipColor = Color3.fromRGB(0, 160, 0),
		shaftMaterial = Enum.Material.SmoothPlastic,
		lipMaterial = Enum.Material.SmoothPlastic,
		lipHeight = 1.5,
		lipOverhang = 1.0,
	},
	part = {
		color = Color3.fromRGB(0, 200, 0),
		material = Enum.Material.SmoothPlastic,
	},
	model = {},
}

--============================================================================
-- PIPE STYLES
-- Each pair randomly picks ONE style (weighted). Both top and bottom share it.
-- Every style must have a `type` field: "part", "model", or "studs".
-- All other fields override the defaults from STYLE_DEFAULTS[type].
-- Optional `weight` field controls spawn probability (default 1).
-- Chance = weight / sum(all weights). Higher weight = more common.
--
-- Part-based (simple colored block):
--   { type = "part", color = Color3.fromRGB(R, G, B), material = Enum.Material.XXX }
--
-- Model-based (marketplace model, auto-scaled to fit):
--   { type = "model", assetId = 123456789 }
--   The model must be pre-loaded into ReplicatedStorage.PipeTemplates
--   with its Name set to the asset ID string (e.g. "123456789").
--
-- Studs (composite shaft + lip):
--   { type = "studs" }
--   Override shaftColor, lipColor, shaftMaterial, lipMaterial, lipHeight,
--   lipOverhang to customize appearance.
--============================================================================

PipeConfig.STYLES = {
	-- { type = "studs", weight = 10 },
	{ type = "model", assetId = 1918080807, weight = 1 }, -- Neon Pillar
}

--============================================================================
-- PIPE STYLE DEFINITIONS (for shop swapping)
-- Maps a shop configKey to the STYLES array that should be active.
--============================================================================

PipeConfig.PIPE_STYLE_DEFS = {
	neon_pillar = {
		{ type = "model", assetId = 1918080807, weight = 1 },
	},
	classic_green = {
		{ type = "studs", weight = 1 },
	},
}

--[[
	Sets the active pipe styles from a style definition key.
	Called by ShopManager when the player equips a pipe style.
	@param styleKey string — key into PIPE_STYLE_DEFS
]]
function PipeConfig.setActiveStyles(styleKey)
	local def = PipeConfig.PIPE_STYLE_DEFS[styleKey]
	if not def then
		warn("[PipeConfig] Unknown style key: " .. tostring(styleKey))
		return
	end
	PipeConfig.STYLES = def
end

--============================================================================
-- SPAWN MANAGEMENT
-- Controls how pipes are spawned and recycled around the player
--============================================================================

PipeConfig.ENABLED = true              -- Set to false to disable all pipe spawning
PipeConfig.PRE_SPAWN_COUNT = 6         -- Pipe pairs pre-spawned ahead of player
PipeConfig.SPAWN_AHEAD_PADDING = 30    -- Extra studs beyond visible right edge to spawn pipes
PipeConfig.DESPAWN_BEHIND_PADDING = 20 -- Extra studs beyond visible left edge to despawn pipes
PipeConfig.FALLBACK_SPAWN_AHEAD = 120  -- Fallback if camera is unavailable
PipeConfig.FALLBACK_DESPAWN_BEHIND = 80
PipeConfig.MAX_POOL_SIZE = 6           -- Max pooled pipes per style before destroying extras

--============================================================================
-- SPAWN LOGIC FUNCTIONS
-- These make the per-pipe-pair decisions. PipeManager calls them directly.
--============================================================================

--[[
	Calculates gap size based on distance traveled (difficulty progression).
	@param totalDistanceTraveled number
	@return number - Gap size in studs
]]
function PipeConfig.getGapSize(totalDistanceTraveled)
	local shrinkAmount = totalDistanceTraveled * PipeConfig.GAP_SHRINK_RATE
	return math.max(PipeConfig.GAP_MIN, PipeConfig.GAP_MAX - shrinkAmount)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function clamp01(value)
	return math.clamp(tonumber(value) or 0, 0, 1)
end

local function ease01(value, easingName)
	local t = clamp01(value)
	local easing = string.lower(tostring(easingName or "smoothstep"))

	if easing == "linear" then
		return t
	end
	if easing == "outsine" then
		return math.sin((t * math.pi) * 0.5)
	end
	if easing == "outcubic" then
		local oneMinus = 1 - t
		return 1 - (oneMinus * oneMinus * oneMinus)
	end

	-- Default: smoothstep
	return t * t * (3 - (2 * t))
end

local function getAdaptiveGapVariance(forwardSpeed)
	local cfg = PipeConfig.GAP_Y_SPEED_VARIANCE
	local fallback = {
		min = PipeConfig.GAP_Y_MIN,
		max = PipeConfig.GAP_Y_MAX,
		maxDelta = PipeConfig.GAP_Y_MAX_DELTA,
	}

	if type(cfg) ~= "table" or cfg.enabled == false then
		return fallback
	end

	local speed = tonumber(forwardSpeed)
	if speed == nil then
		return fallback
	end

	local slowSpeed = math.max(0, tonumber(cfg.slowForwardSpeed) or 40)
	local fastSpeed = math.max(slowSpeed, tonumber(cfg.fastForwardSpeed) or slowSpeed)
	local t = 1
	if fastSpeed > slowSpeed then
		t = (speed - slowSpeed) / (fastSpeed - slowSpeed)
	else
		t = if speed >= fastSpeed then 1 else 0
	end
	t = ease01(t, cfg.easing)

	local slow = type(cfg.slow) == "table" and cfg.slow or {}
	local fast = type(cfg.fast) == "table" and cfg.fast or {}

	local slowMin = tonumber(slow.min) or fallback.min
	local slowMax = tonumber(slow.max) or fallback.max
	local slowDelta = tonumber(slow.maxDelta) or fallback.maxDelta
	local fastMin = tonumber(fast.min) or fallback.min
	local fastMax = tonumber(fast.max) or fallback.max
	local fastDelta = tonumber(fast.maxDelta) or fallback.maxDelta

	local minY = lerp(slowMin, fastMin, t)
	local maxY = lerp(slowMax, fastMax, t)
	local maxDelta = lerp(slowDelta, fastDelta, t)

	if maxY < minY then
		maxY = minY
	end
	maxDelta = math.max(0, maxDelta)

	return {
		min = minY,
		max = maxY,
		maxDelta = maxDelta,
	}
end

--[[
	Picks a random gap Y position, delta-clamped to the previous gap.
	@param gapSize number - Current gap size
	@param previousGapY number|nil - Previous gap's Y (nil on first pipe)
	@param gapContext table|nil - Optional context (e.g. { forwardSpeed = 90 })
	@return number - Y position for gap center
	@return table - Debug info (effective min/max bounds, maxDelta)
]]
function PipeConfig.getGapY(gapSize, previousGapY, gapContext)
	local variance = getAdaptiveGapVariance(gapContext and gapContext.forwardSpeed)
	local halfGap = gapSize / 2
	local minY = math.max(WorldConfig.BOUNDARIES.MIN_Y + halfGap + 2, tonumber(variance.min) or PipeConfig.GAP_Y_MIN)
	local maxY = math.min(WorldConfig.BOUNDARIES.MAX_Y - halfGap - 2, tonumber(variance.max) or PipeConfig.GAP_Y_MAX)
	if maxY < minY then
		maxY = minY
	end
	local maxDelta = math.max(0, tonumber(variance.maxDelta) or PipeConfig.GAP_Y_MAX_DELTA)

	local gapY = minY + math.random() * (maxY - minY)

	-- Delta-clamp to prevent unfair jumps between consecutive pipes.
	-- This clamp also scales with speed via GAP_Y_SPEED_VARIANCE.
	if previousGapY ~= nil then
		gapY = math.clamp(gapY, previousGapY - maxDelta, previousGapY + maxDelta)
		gapY = math.clamp(gapY, minY, maxY)
	end

	return gapY, {
		minY = minY,
		maxY = maxY,
		maxDelta = maxDelta,
	}
end

local function sanitizeSpacingRange(minSpacing, maxSpacing)
	local absMin = tonumber(PipeConfig.SPACING_FLOOR) or 0
	local absMax = tonumber(PipeConfig.SPACING_CEILING) or absMin
	if absMax < absMin then
		absMax = absMin
	end

	local safeMin = tonumber(minSpacing) or absMin
	local safeMax = tonumber(maxSpacing) or safeMin
	if safeMax < safeMin then
		safeMax = safeMin
	end

	safeMin = math.clamp(safeMin, absMin, absMax)
	safeMax = math.clamp(safeMax, safeMin, absMax)
	return safeMin, safeMax
end

local function getSpacingCurvePoints()
	local rawPoints = PipeConfig.SPACING_SPEED_POINTS
	local points = {}

	if type(rawPoints) ~= "table" then
		return points
	end

	for _, point in ipairs(rawPoints) do
		local speed = tonumber(point and point.speed)
		local minSpacing = tonumber(point and point.min)
		local maxSpacing = tonumber(point and point.max)
		if speed and minSpacing and maxSpacing then
			if maxSpacing < minSpacing then
				maxSpacing = minSpacing
			end
			table.insert(points, {
				speed = speed,
				min = minSpacing,
				max = maxSpacing,
			})
		end
	end

	table.sort(points, function(a, b)
		return a.speed < b.speed
	end)

	return points
end

local function getFirstSpacingPointSpeed(points)
	return (points[1] and tonumber(points[1].speed)) or 1
end

local function getEffectiveSpacingSpeed(speedMultiplier, spacingContext)
	local points = getSpacingCurvePoints()
	local speed = tonumber(speedMultiplier) or getFirstSpacingPointSpeed(points)
	local cfg = PipeConfig.SPACING_CAP_START_RELIEF

	if type(cfg) ~= "table" or cfg.enabled == false then
		return speed
	end

	local speedCap = tonumber(spacingContext and spacingContext.speedCapMultiplier)
	if not speedCap then
		return speed
	end

	local referenceCap = tonumber(cfg.referenceCap) or speedCap
	local fullEffectCap = tonumber(cfg.fullEffectCap) or referenceCap
	if fullEffectCap < referenceCap then
		fullEffectCap = referenceCap
	end
	if speedCap <= referenceCap then
		return speed
	end

	local capAlpha = 1
	local capSpan = fullEffectCap - referenceCap
	if capSpan > 0 then
		capAlpha = math.clamp((speedCap - referenceCap) / capSpan, 0, 1)
	else
		capAlpha = 1
	end

	local capExponent = tonumber(cfg.capExponent) or 1.0
	if capExponent > 0 and capExponent ~= 1 then
		capAlpha = capAlpha ^ capExponent
	end

	local startSpeed = tonumber(cfg.startSpeed) or getFirstSpacingPointSpeed(points)
	local safeSpeedCap = math.max(speedCap, startSpeed)
	local progressToCap = 1
	if safeSpeedCap > startSpeed then
		progressToCap = math.clamp((speed - startSpeed) / (safeSpeedCap - startSpeed), 0, 1)
	end

	local fadeProgress = tonumber(cfg.fadeToZeroByCapProgress) or 0.4
	fadeProgress = math.clamp(fadeProgress, 0.0001, 1.0)
	local fadeT = math.clamp(progressToCap / fadeProgress, 0, 1)
	local fadeExponent = tonumber(cfg.fadeExponent) or 1.0
	if fadeExponent > 0 and fadeExponent ~= 1 then
		fadeT = fadeT ^ fadeExponent
	end
	local earlyAlpha = 1 - fadeT

	local maxVirtualSpeedBoost = math.max(0, tonumber(cfg.maxVirtualSpeedBoost) or 0)
	local boost = maxVirtualSpeedBoost * capAlpha * earlyAlpha
	local effectiveSpeed = speed + boost

	-- Keep spacing-speed proxy within the actual cap band.
	return math.clamp(effectiveSpeed, speed, safeSpeedCap)
end

--[[
	Returns the randomized spacing range for a given speed multiplier.
	Uses piecewise interpolation across PipeConfig.SPACING_SPEED_POINTS.
	@param speedMultiplier number|nil
	@return number, number - minSpacing, maxSpacing
]]
function PipeConfig.getSpacingRangeForSpeed(speedMultiplier)
	local points = getSpacingCurvePoints()
	if #points == 0 then
		return sanitizeSpacingRange(PipeConfig.SPACING_FLOOR, PipeConfig.SPACING_CEILING)
	end

	local speed = tonumber(speedMultiplier) or points[1].speed or 1

	if speed <= points[1].speed then
		return sanitizeSpacingRange(points[1].min, points[1].max)
	end

	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		if speed <= b.speed then
			local segmentSpan = b.speed - a.speed
			local t = 0
			if segmentSpan > 0 then
				t = (speed - a.speed) / segmentSpan
			end

			local interpExponent = tonumber(PipeConfig.SPACING_SPEED_INTERP_EXPONENT) or 1.0
			if interpExponent > 0 and interpExponent ~= 1 then
				t = t ^ interpExponent
			end

			return sanitizeSpacingRange(
				lerp(a.min, b.min, t),
				lerp(a.max, b.max, t)
			)
		end
	end

	local lastPoint = points[#points]
	return sanitizeSpacingRange(lastPoint.min, lastPoint.max)
end

--[[
	Calculates spacing to the next pipe pair, scaled by speed.
	@param speedMultiplier number|nil - Current speed multiplier
	@param spacingContext table|nil - Optional context (e.g. { speedCapMultiplier = 4.0, forwardSpeed = 90 })
	@return number - Spacing in studs
	@return table - Debug info (effectiveSpeed, minSpacing, maxSpacing)
]]
function PipeConfig.getSpacing(speedMultiplier, spacingContext)
	local effectiveSpeed = getEffectiveSpacingSpeed(speedMultiplier, spacingContext)
	local minSpacing, maxSpacing = PipeConfig.getSpacingRangeForSpeed(effectiveSpeed)
	local forwardSpeed = tonumber(spacingContext and spacingContext.forwardSpeed)
	if forwardSpeed and forwardSpeed > 0 then
		local speedRatio = math.clamp(tonumber(PipeConfig.SPACING_MIN_FORWARD_SPEED_RATIO) or 1.0, 0, 1)
		-- Guarantee a configurable fraction of ~1 second of horizontal travel
		-- time at the current forward speed so high-speed runs remain readable/fun.
		minSpacing = math.max(minSpacing, forwardSpeed * speedRatio)
		maxSpacing = math.max(maxSpacing, minSpacing)
	end
	local roll = math.random()
	local sampleExponent = tonumber(PipeConfig.SPACING_SAMPLE_EXPONENT) or 1.0
	if sampleExponent > 0 and sampleExponent ~= 1 then
		roll = roll ^ sampleExponent
	end

	return (minSpacing + roll * (maxSpacing - minSpacing)), {
		effectiveSpeed = effectiveSpeed,
		minSpacing = minSpacing,
		maxSpacing = maxSpacing,
	}
end

--[[
	Picks a weighted-random style index.
	Each style's `weight` field (default 1) controls its spawn probability.
	@param styleCount number - Number of resolved styles
	@return number - 1-based style index
]]
function PipeConfig.getStyleIndex(styleCount)
	local styles = PipeConfig.STYLES
	local totalWeight = 0
	for i = 1, styleCount do
		totalWeight = totalWeight + (styles[i] and styles[i].weight or 1)
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for i = 1, styleCount do
		cumulative = cumulative + (styles[i] and styles[i].weight or 1)
		if roll <= cumulative then
			return i
		end
	end
	return styleCount
end

--[[
	Calculates top and bottom pipe heights from gap position and size.
	@param gapY number - Gap center Y
	@param gapSize number - Gap size in studs
	@return number, number - topPipeHeight, bottomPipeHeight
]]
function PipeConfig.getPipeHeights(gapY, gapSize)
	local topHeight = WorldConfig.BOUNDARIES.MAX_Y - (gapY + gapSize / 2)
	local bottomHeight = (gapY - gapSize / 2) - WorldConfig.BOUNDARIES.MIN_Y

	-- Ensure minimum height, then extend pipes off-screen
	topHeight = math.max(1, topHeight) + PipeConfig.TOP_PIPE_EXTENSION
	bottomHeight = math.max(1, bottomHeight) + PipeConfig.BOTTOM_PIPE_EXTENSION

	return topHeight, bottomHeight
end

--[[
	Computes the visible horizontal half-width at the play plane (Z=0)
	based on the current camera's FOV and viewport aspect ratio.
	Returns nil if the camera is not available.
	@return number|nil - Half-width in studs from camera center to screen edge
]]
function PipeConfig.getVisibleHalfWidth()
	local camera = workspace.CurrentCamera
	if not camera then return nil end

	local vFovDeg = camera.FieldOfView
	local viewport = camera.ViewportSize
	if viewport.X == 0 or viewport.Y == 0 then return nil end

	local aspectRatio = viewport.X / viewport.Y
	local vFovRad = math.rad(vFovDeg) / 2
	local hFovRad = math.atan(aspectRatio * math.tan(vFovRad))

	local distance = CameraConfig.OFFSET_Z -- camera distance from play plane
	return distance * math.tan(hFovRad)
end

--[[
	Returns the spawn-ahead distance (studs ahead of player to spawn pipes).
	Adapts to the current screen size / aspect ratio.
	@return number
]]
function PipeConfig.getSpawnAheadDistance()
	local halfWidth = PipeConfig.getVisibleHalfWidth()
	if not halfWidth then
		return PipeConfig.FALLBACK_SPAWN_AHEAD
	end
	-- Right edge from player = halfWidth + dynamic camera X offset.
	-- Use the gameplay screen fraction (player furthest left = camera offset is largest).
	local fraction = CameraConfig.PLAYER_SCREEN_X_PLAYING
	local offsetX = (0.5 - fraction) * 2 * halfWidth
	local rightEdge = halfWidth + offsetX
	return rightEdge + PipeConfig.SPAWN_AHEAD_PADDING
end

--[[
	Returns the despawn-behind distance (studs behind player to recycle pipes).
	Adapts to the current screen size / aspect ratio.
	@return number
]]
function PipeConfig.getDespawnBehindDistance()
	local halfWidth = PipeConfig.getVisibleHalfWidth()
	if not halfWidth then
		return PipeConfig.FALLBACK_DESPAWN_BEHIND
	end
	-- Left edge from player = halfWidth - dynamic camera X offset.
	-- Use the gameplay screen fraction for consistent despawn.
	local fraction = CameraConfig.PLAYER_SCREEN_X_PLAYING
	local offsetX = (0.5 - fraction) * 2 * halfWidth
	local leftEdge = halfWidth - offsetX
	return leftEdge + PipeConfig.DESPAWN_BEHIND_PADDING
end

return PipeConfig
