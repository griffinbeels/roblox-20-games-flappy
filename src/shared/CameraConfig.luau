--[[
	CameraConfig.luau

	Side-scrolling camera settings.
	Controls how the camera follows the player and frames the play area.
]]

local CameraConfig = {}

CameraConfig.OFFSET_X = 10   -- Camera is slightly ahead of player
CameraConfig.FIXED_Y = 30    -- Camera vertical center (middle of play area)
CameraConfig.OFFSET_Z = 50   -- Distance from player (wider = see more)
CameraConfig.LOOK_AT_Y = 30  -- Camera looks at this Y (prevents tilting)

-- Viewport-adaptive camera (scales Z offset on smaller screens)
CameraConfig.ADAPTIVE_CAMERA = true           -- Toggle adaptive scaling
CameraConfig.REFERENCE_VIEWPORT_HEIGHT = 800  -- Desktop height where OFFSET_Z is ideal
CameraConfig.MIN_OFFSET_Z = 50               -- Closest the camera can get

-- Player screen position (fraction from left edge: 0 = left, 0.5 = center, 1 = right)
-- The camera X offset is computed dynamically from this value + FOV + aspect ratio,
-- so the player appears at the same screen fraction on all devices/resolutions.
CameraConfig.PLAYER_SCREEN_X_READY = 0.50    -- centered during ready/hover
CameraConfig.PLAYER_SCREEN_X_PLAYING = 0.30  -- 30% from left during gameplay
CameraConfig.TRANSITION_DURATION = 0.5       -- Seconds to lerp between ready/playing offset

return CameraConfig
