--[[
	Constants.luau
	
	Central configuration file for Flappy Bird game.
	All magic numbers and game parameters are defined here for easy tweaking.
	
	==========================================================================
	HOW TO ADJUST GAMEPLAY FEEL:
	==========================================================================
	
	JUMP FEEL:
	- PLAYER.JUMP_FORCE: Higher = bigger jumps, Lower = micro adjustments
	  Start with 25-35 for subtle taps, 50-70 for big bouncy jumps
	
	GAP SIZE (difficulty):
	- PIPE.GAP_MIN: Minimum gap at hardest difficulty (recommend 10-12)
	- PIPE.GAP_MAX: Starting gap size (recommend 14-18 for comfortable play)
	- Largest Roblox character is ~5 studs tall, so gap should be 10+ minimum
	
	PIPE SPACING:
	- PIPE.SPACING_MIN/MAX: Distance between pipe pairs (20-40 typical)
	
	==========================================================================
]]

local Constants = {}

--============================================================================
-- PLAYER CONFIGURATION
-- Adjust these to change how the player character feels
--============================================================================
Constants.PLAYER = {
	-- JUMP FORCE: How much upward velocity is applied when pressing space
	-- Lower values = subtle micro-adjustments (good for precision)
	-- Higher values = big bouncy jumps (more arcade-like)
	-- Recommended range: 20-50
	JUMP_FORCE = 30,
	
	-- GRAVITY: How fast the player falls
	-- Higher = falls faster, more urgent gameplay
	-- Lower = floatier, more forgiving
	GRAVITY = 196.2,
	
	-- Starting position in the game area
	START_POSITION = Vector3.new(0, 2, 0),
	
	-- Forward movement speed (studs per second)
	BASE_FORWARD_SPEED = 20,
}

--============================================================================
-- PIPE GAP CONFIGURATION
-- These control how big the gap between pipes is (the space player flies through)
-- Largest Roblox character is approximately 5-6 studs tall
--============================================================================
Constants.PIPE = {
	-- GAP SIZE: The vertical space between top and bottom pipes
	-- Player must fit through this gap
	-- Minimum recommended: 10 studs (fits largest character + tiny margin)
	-- Comfortable play: 14-18 studs
	-- EASILY ADJUSTABLE: Increase these for easier gameplay
	GAP_MIN = 12,  -- Minimum gap at max difficulty
	GAP_MAX = 16,  -- Starting gap (easier)
	
	-- GAP POSITION: Where the gap can appear vertically
	-- These control how high/low the gap center can be placed
	-- Should be within the VISIBLE camera area (camera center is at Y=15)
	-- Player sees roughly Y=5 to Y=25 on screen
	GAP_Y_MIN = 8,   -- Lowest the gap center can be (near floor)
	GAP_Y_MAX = 22,  -- Highest the gap center can be (near top of screen)
	
	-- GAP DIFFICULTY: How fast the gap shrinks as player progresses
	-- Set to 0 to disable difficulty progression
	GAP_SHRINK_RATE = 0.003, -- Gap shrinks by this much per stud traveled
	
	-- SPACING: Distance between pipe pairs (X axis)
	SPACING_MIN = 30,  -- Minimum distance between pipes
	SPACING_MAX = 45,  -- Maximum distance between pipes
	
	-- FIRST PIPE: How far ahead is the first pipe pair
	FIRST_PIPE_MIN = 40,
	FIRST_PIPE_MAX = 55,
	
	-- Visual properties - EASILY ADJUSTABLE
	WIDTH = 8,  -- How thick the pipes are (X and Z)
	COLOR = Color3.fromRGB(0, 200, 0),  -- Green
	MATERIAL = Enum.Material.SmoothPlastic,
}

--============================================================================
-- PLAY AREA BOUNDARIES
-- Defines the vertical space where pipes extend to
-- Pipes should extend BEYOND the camera view for the "infinite pipe" look
--============================================================================
Constants.BOUNDARIES = {
	-- MIN_Y: The floor level (bottom of play area)
	-- Bottom of the bottom pipe will be at this Y
	MIN_Y = 0,
	
	-- MAX_Y: The ceiling level (top of play area)
	-- Top of the top pipe will be at this Y
	-- This should be ABOVE the camera view so pipes look like they extend to infinity
	-- Increase this value if pipes appear to be floating in mid-air
	MAX_Y = 50,
}

--============================================================================
-- CAMERA CONFIGURATION
-- Side-scrolling camera settings
--============================================================================
Constants.CAMERA = {
	OFFSET_X = 10,   -- Camera is slightly ahead of player
	FIXED_Y = 15,    -- Camera vertical center (middle of play area)
	OFFSET_Z = 50,   -- Distance from player (wider = see more)
	LOOK_AT_Y = 15,  -- Camera looks at this Y (prevents tilting)
}

--============================================================================
-- FLOOR CONFIGURATION
-- Must match the Baseplate in default.project.json
--============================================================================
Constants.FLOOR = {
	Y_POSITION = -10,  -- Y center of the floor part
	HEIGHT = 20,       -- Height of floor (top surface at Y=0)
}

--============================================================================
-- SPEED PROGRESSION
-- Game gets faster over time
--============================================================================
Constants.SPEED = {
	INITIAL_MULTIPLIER = 1.0,
	INCREASE_RATE = 0.1,    -- Speed increase per second
	MAX_MULTIPLIER = 3.0,   -- Cap on speed increase
}

--============================================================================
-- READY STATE (Pre-game hover)
--============================================================================
Constants.READY = {
	PLAYER_Y = 15,        -- Y position while hovering
	HOVER_AMPLITUDE = 0.3, -- Bobbing amount
	HOVER_SPEED = 2,      -- Bobbing speed
}

--============================================================================
-- GAME STATES
--============================================================================
Constants.GAME = {
	RESET_DELAY = 1,
	STATES = {
		MENU = "menu",
		READY = "ready",
		PLAYING = "playing",
		GAME_OVER = "gameOver",
	},
}

--============================================================================
-- START BUTTON (Hub area)
--============================================================================
Constants.START_BUTTON = {
	POSITION = Vector3.new(20, 5, 0),
	SIZE = Vector3.new(8, 10, 2),
	COLOR = Color3.fromRGB(50, 200, 50),
	INTERACT_DISTANCE = 10,
}

--============================================================================
-- LEGACY COMPATIBILITY (for any code still using old names)
--============================================================================
Constants.PIPETYPE_DEFAULT = {
	WIDTH = Constants.PIPE.WIDTH,
	HEIGHT = 50,  -- Not used anymore - heights are calculated dynamically
	GAP_SIZE = Constants.PIPE.GAP_MAX,
	COLOR = Constants.PIPE.COLOR,
	MATERIAL = Constants.PIPE.MATERIAL,
}

Constants.PATTERN = {
	ALTERNATING = true,
}

return Constants
