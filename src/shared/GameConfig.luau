--[[
	GameConfig.luau

	Game flow, difficulty progression, scoring, leaderboard, and hub area config.
	Everything about how the game session works (not player physics or world geometry).
]]

local GameConfig = {}

--============================================================================
-- GAME STATES
--============================================================================
GameConfig.STATES = {
	MENU = "menu",
	READY = "ready",
	PLAYING = "playing",
	GAME_OVER = "gameOver",
}

GameConfig.RESET_DELAY = 0.5

--============================================================================
-- SPEED PROGRESSION
-- Game gets faster over time
--============================================================================
GameConfig.SPEED = {
	INITIAL_MULTIPLIER = 1.0,
	INCREASE_RATE = 0.05,    -- Speed increase per second
	MAX_MULTIPLIER = 4.0,   -- Cap on speed increase
}

--============================================================================
-- MEDAL THRESHOLDS
-- Score required for each medal tier on the Game Over screen.
--============================================================================
GameConfig.MEDALS = {
	BRONZE = 20,
	SILVER = 30,
	GOLD = 40,
}

--============================================================================
-- LEADERBOARD
-- Global leaderboard settings for the scrollable UI on the ready screen.
--============================================================================
GameConfig.LEADERBOARD = {
	PAGE_SIZE = 5,
	CACHE_REFRESH_INTERVAL = 30, -- seconds between server cache refreshes
	MAX_ENTRIES = 100,            -- max entries to cache from OrderedDataStore
}

--============================================================================
-- START BUTTON (Hub area)
--============================================================================
GameConfig.START_BUTTON = {
	POSITION = Vector3.new(20, 5, 0),
	SIZE = Vector3.new(8, 10, 2),
	COLOR = Color3.fromRGB(50, 200, 50),
	INTERACT_DISTANCE = 10,
}

return GameConfig
