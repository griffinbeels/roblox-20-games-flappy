--[[
	PlayerConfig.luau

	All player character configuration: physics, movement, and hover behavior.

	==========================================================================
	HOW TO ADJUST GAMEPLAY FEEL:
	==========================================================================

	JUMP FEEL:
	- JUMP_FORCE: Higher = bigger jumps, Lower = micro adjustments
	  Start with 25-35 for subtle taps, 50-70 for big bouncy jumps

	GRAVITY:
	- Higher = falls faster, more urgent gameplay
	- Lower = floatier, more forgiving

	FORWARD SPEED:
	- BASE_FORWARD_SPEED: How fast the player moves horizontally (studs/sec)

	HOVER (pre-game bobbing):
	- The player bobs in the air on the ready screen before Space is pressed

	==========================================================================
]]

local PlayerConfig = {}

-- GRAVITY: How fast the player falls
PlayerConfig.GRAVITY = 150

-- Starting position in the game area
PlayerConfig.START_POSITION = Vector3.new(0, 15, 0)

-- Forward movement speed (studs per second)
PlayerConfig.BASE_FORWARD_SPEED = 40

-- JUMP FORCE: How much upward velocity is applied when pressing space
-- Lower values = subtle micro-adjustments (good for precision)
-- Higher values = big bouncy jumps (more arcade-like)
PlayerConfig.JUMP_FORCE = 60

-- HOVER: Pre-game ready state (player bobs in the air before Space is pressed)
PlayerConfig.READY_X_OFFSET = 12    -- X offset from START_POSITION during ready/hover (positive = further right)
PlayerConfig.HOVER_Y_OFFSET = 13    -- Y offset above START_POSITION.Y
PlayerConfig.HOVER_AMPLITUDE = 0.5  -- Bobbing amount (studs)
PlayerConfig.HOVER_SPEED = 2        -- Bobbing speed

-- TILT MODE: How the character orients along their trajectory
-- "NONE"    = no tilt, player stays perfectly flat
-- "DIRECT"  = instant rotation matching trajectory (no lag)
-- "DAMPED"  = BodyGyro spring-damper rotation (smooth but lags behind)
PlayerConfig.TILT_MODE = "DAMPED"

-- TILT SHARPNESS: Only used in DIRECT and DAMPED modes
-- 1.0 = true trajectory angle, >1.0 = exaggerated tilt, <1.0 = subtle
PlayerConfig.TILT_SHARPNESS = 1

-- DAMPED MODE tuning (only used when TILT_MODE = "DAMPED")
-- P = stiffness: how fast it rotates toward the target (higher = snappier)
-- D = damping:   how much it resists overshooting (higher = less bounce)
-- Slow & smooth: P=3000,  D=500
-- Responsive:    P=15000, D=800
-- Very snappy:   P=40000, D=1200
PlayerConfig.TILT_DAMPED_P = 25000
PlayerConfig.TILT_DAMPED_D = 300

-- COLLISION HITBOX: Used by CollisionDetector for AABB checks
-- These define the player's logical hitbox around the HumanoidRootPart.
-- Smaller values = more forgiving (player can visually clip pipe edges and survive).
PlayerConfig.HITBOX_RADIUS = 1.0       -- Horizontal half-extent (X and Z); character is ~2 wide
PlayerConfig.HITBOX_HALF_HEIGHT = 1.5  -- Vertical half-extent (Y); character is ~4 tall
PlayerConfig.COLLISION_TOLERANCE = 0.75 -- Small margin to catch edge-on-edge contact (landing on surfaces)

return PlayerConfig
