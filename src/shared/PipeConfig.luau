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
PipeConfig.GAP_Y_MAX = 40   -- Highest gap center

-- Max vertical change between consecutive gaps (studs)
-- Prevents unfair jumps from top to bottom of screen
PipeConfig.GAP_Y_MAX_DELTA = 10

--============================================================================
-- SPACING CONFIGURATION
-- Horizontal distance between pipe pairs
--============================================================================


-- Speed-scaled spacing: how horizontal gap grows with speed
-- Formula: spacing = baseSpacing * (1 + SCALE_FACTOR * (speed - 1) ^ SCALE_EXPONENT)
-- Then clamped to [SPACING_FLOOR, SPACING_CEILING]
PipeConfig.SPEED_SCALE_FACTOR = 1
PipeConfig.SPEED_SCALE_EXPONENT = 1.0
PipeConfig.SPACING_FLOOR = 40     -- Absolute minimum spacing (studs)
PipeConfig.SPACING_CEILING = 100  -- Absolute maximum spacing (studs)

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

--[[
	Picks a random gap Y position, delta-clamped to the previous gap.
	@param gapSize number - Current gap size
	@param previousGapY number|nil - Previous gap's Y (nil on first pipe)
	@return number - Y position for gap center
]]
function PipeConfig.getGapY(gapSize, previousGapY)
	local halfGap = gapSize / 2
	local minY = math.max(WorldConfig.BOUNDARIES.MIN_Y + halfGap + 2, PipeConfig.GAP_Y_MIN)
	local maxY = math.min(WorldConfig.BOUNDARIES.MAX_Y - halfGap - 2, PipeConfig.GAP_Y_MAX)

	local gapY = minY + math.random() * (maxY - minY)

	-- Delta-clamp to prevent unfair jumps between consecutive pipes
	if previousGapY ~= nil then
		gapY = math.clamp(gapY, previousGapY - PipeConfig.GAP_Y_MAX_DELTA, previousGapY + PipeConfig.GAP_Y_MAX_DELTA)
		gapY = math.clamp(gapY, minY, maxY)
	end

	return gapY
end

--[[
	Calculates spacing to the next pipe pair, scaled by speed.
	@param speedMultiplier number|nil - Current speed multiplier
	@return number - Spacing in studs
]]
function PipeConfig.getSpacing(speedMultiplier)
	local floor = PipeConfig.SPACING_FLOOR
	local ceiling = PipeConfig.SPACING_CEILING

	if speedMultiplier and speedMultiplier > 1 then
		local scale = 1 + PipeConfig.SPEED_SCALE_FACTOR * (speedMultiplier - 1) ^ PipeConfig.SPEED_SCALE_EXPONENT
		floor = math.min(floor * scale, ceiling)
	end

	return floor + math.random() * (ceiling - floor)
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
