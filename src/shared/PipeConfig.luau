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

--============================================================================
-- PIPE STYLES
-- Each pair randomly picks ONE style. Both top and bottom share it.
--
-- Part-based (simple colored block):
--   { COLOR = Color3.fromRGB(R, G, B), MATERIAL = Enum.Material.XXX }
--
-- Model-based (marketplace model, auto-scaled to fit):
--   { MODEL_ASSET_ID = 123456789 }
--   The model must be pre-loaded into ReplicatedStorage.PipeTemplates
--   with its Name set to the asset ID string (e.g. "123456789").
--============================================================================

PipeConfig.STYLES = {
	-- { COLOR = Color3.fromRGB(0, 200, 0),   MATERIAL = Enum.Material.SmoothPlastic }, -- Green
	{ MODEL_ASSET_ID = 103974792945275 },                                                -- Marketplace model
	-- { COLOR = Color3.fromRGB(200, 0, 0),   MATERIAL = Enum.Material.Neon },           -- Red neon
	-- { COLOR = Color3.fromRGB(0, 100, 255), MATERIAL = Enum.Material.Metal },          -- Blue metal
}

--============================================================================
-- SPAWN MANAGEMENT
-- Controls how pipes are spawned and recycled around the player
--============================================================================

PipeConfig.PRE_SPAWN_COUNT = 6         -- Pipe pairs pre-spawned ahead of player
PipeConfig.SPAWN_AHEAD_DISTANCE = 120  -- Distance ahead of player to spawn (off-screen right)
PipeConfig.DESPAWN_BEHIND_DISTANCE = 80 -- Distance behind player to recycle (off-screen left)
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
	Picks a random style index.
	@param styleCount number - Number of resolved styles
	@return number - 1-based style index
]]
function PipeConfig.getStyleIndex(styleCount)
	return math.random(1, styleCount)
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

	-- Ensure minimum height, then extend top pipe off-screen
	topHeight = math.max(1, topHeight) + PipeConfig.TOP_PIPE_EXTENSION
	bottomHeight = math.max(1, bottomHeight)

	return topHeight, bottomHeight
end

return PipeConfig
