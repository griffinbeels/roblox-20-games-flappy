--[[
	CameraConfig.luau

	Side-scrolling camera settings.
	Controls how the camera follows the player and frames the play area.
]]

local CameraConfig = {}

CameraConfig.OFFSET_X = 10   -- Camera is slightly ahead of player
CameraConfig.FIXED_Y = 20    -- Camera vertical center (middle of play area)
CameraConfig.OFFSET_Z = 50   -- Distance from player (wider = see more)
CameraConfig.LOOK_AT_Y = 20  -- Camera looks at this Y (prevents tilting)

return CameraConfig
