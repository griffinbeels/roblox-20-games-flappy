--[[
	WorldConfig.luau

	Play area boundaries and floor configuration.
	Defines the vertical space of the game world and the physical floor.
]]

local WorldConfig = {}

--============================================================================
-- PLAY AREA BOUNDARIES
-- Defines the vertical space of the play area
--============================================================================
WorldConfig.BOUNDARIES = {
	-- MIN_Y: The floor level (bottom of play area)
	MIN_Y = 0,

	-- MAX_Y: The ceiling level (top of play area)
	-- This should be ABOVE the camera view so pipes look like they extend to infinity
	MAX_Y = 60
}

--============================================================================
-- FLOOR CONFIGURATION
-- Must match the Baseplate in default.project.json
--============================================================================
WorldConfig.FLOOR = {
	Y_POSITION = -100, -- Y center of the floor collider (top surface at Y=0)
	HEIGHT = 200,       -- Height of floor (extends from Y=0 down to Y=-200)
}

return WorldConfig
