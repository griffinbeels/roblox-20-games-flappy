--[[
	CurrencyConfig.luau

	Configuration for the Bacon currency system.
	All tunable constants for earning, persistence, and UI display.
]]

local CurrencyConfig = {}

--============================================================================
-- CURRENCY
--============================================================================
CurrencyConfig.NAME = "Bacon"
CurrencyConfig.PER_PIPE = 1           -- bacon earned per pipe passed
CurrencyConfig.DATASTORE_NAME = "FlappyBirdCurrency"
CurrencyConfig.MAX_SUBMIT_PER_RUN = 10000 -- sanity cap on a single submission
CurrencyConfig.SAVE_DEBOUNCE_DELAY = 2     -- seconds before flushing pending earned bacon
CurrencyConfig.SAVE_FLUSH_INTERVAL = 20    -- periodic flush interval for pending earned bacon
CurrencyConfig.SAVE_FLUSH_SPREAD_DELAY = 0.05 -- spread writes across users to avoid bursts

--============================================================================
-- UI — BillboardGui displayed above the leaderboard during READY state
--============================================================================
CurrencyConfig.UI = {
	ICON = "\u{1F953}",                -- bacon emoji
	FORMAT = "%s %d",                  -- icon + amount (e.g. "🥓 42")
	FONT = Enum.Font.GothamBold,
	TEXT_COLOR = Color3.fromRGB(255, 200, 120),
	STROKE_COLOR = Color3.fromRGB(80, 40, 10),
	STROKE_TRANSPARENCY = 0.4,

	-- Billboard sizing (studs, same coordinate space as leaderboard)
	BILLBOARD_WIDTH = 20,              -- studs wide
	BILLBOARD_HEIGHT = 4,              -- studs tall
	BILLBOARD_Y_OFFSET = 23,           -- studs above Part center (leaderboard top edge is ~20)
}

--============================================================================
-- CELEBRATION — Bacon count-up animation on game over screen
--============================================================================
CurrencyConfig.CELEBRATION = {
	TEXT_SIZE = 28,            -- bacon total counter on game over screen
	COUNT_UP_DELAY = 0.0,     -- seconds before count-up starts
	COUNT_UP_DURATION = 1,  -- seconds for full count-up animation
}

--============================================================================
-- COLLECTIBLE — Physical bacon that spawns in pipe gaps
--============================================================================
CurrencyConfig.COLLECTIBLE = {
	-- Sizing relative to pipe gap (e.g. 16-stud gap)
	GAP_FILL = 0.35,           -- visual is 25% of gap size (= 4 studs in a 16-stud gap)
	HITBOX_GAP_FILL = 0.875,   -- hitbox is 87.5% of gap height (= 14 studs)
	HITBOX_WIDTH = 10,         -- X/Z extent in studs (not gap-relative)

	-- Display: what the collectible looks like
	-- MODE: "emoji" | "image" | "model"
	DISPLAY = {
		MODE = "emoji",
		EMOJI = "\u{1F953}",              -- used when MODE = "emoji"
		IMAGE = "",                        -- asset ID, used when MODE = "image"
		MODEL_NAME = "",                   -- name in ReplicatedStorage.CollectibleModels, used when MODE = "model"
	},

	-- Floating animation
	BOB_AMPLITUDE = 0.5,                     -- Studs up/down from center
	BOB_SPEED = 2,                           -- Oscillation speed

	-- Glow effect (PointLight)
	GLOW_COLOR = Color3.fromRGB(255, 200, 100),
	GLOW_BRIGHTNESS = 2,
	GLOW_RANGE = 12,

	-- Lifecycle
	DESPAWN_BEHIND = 30,                     -- Studs behind player before auto-recycling
}

--============================================================================
-- COLLECT ANIMATION — Bacon flies to score UI when collected
--============================================================================
CurrencyConfig.COLLECT_ANIMATION = {
	DURATION = 0.5,                     -- base seconds for fly-to-score animation
	SPEED_MULTIPLIER = 1.35,            -- easy speed knob: 1 = normal, 2 = 2x faster
	scales_with_game = true,            -- when true, collect speed scales with current gameplay speed
	GAME_SPEED_SCALE_MIN = 0.9,         -- lower clamp for game-speed scaling factor
	GAME_SPEED_SCALE_MAX = 2.5,         -- upper clamp for game-speed scaling factor
	CURVE_TYPE = "easeInOut",           -- easy curve knob: "linear" | "easeIn" | "easeOut" | "easeInOut" | "smooth"
	CURVE_PRESETS = {
		linear = { style = "Linear", direction = "InOut" },
		easeIn = { style = "Quad", direction = "In" },
		easeOut = { style = "Quad", direction = "Out" },
		easeInOut = { style = "Quad", direction = "InOut" },
		smooth = { style = "Sine", direction = "InOut" },
	},
	INITIAL_SCREEN_SIZE = 50,           -- minimum pixel size floor (actual size computed from camera projection)
	SHRINK_SCALE = 0,                   -- final size as fraction of initial (0 = shrink to nothing)
	EASING_STYLE = "Quad",              -- legacy fallback if CURVE_TYPE is missing/invalid
	EASING_DIRECTION = "Out",           -- legacy fallback if CURVE_TYPE is missing/invalid
	FLY_DISPLAY = "\u{1F953}",         -- emoji shown during fly animation
	TARGET_OFFSET_X = 0,               -- scale offset: fraction of target width (positive = right from center)
	TARGET_OFFSET_Y = 0,               -- scale offset: fraction of target height (positive = down from center)
}

--============================================================================
-- GAME OVER — "Bacon earned this run" line
--============================================================================
CurrencyConfig.GAME_OVER = {
	FORMAT = "+%d %s",                 -- e.g. "+5 Bacon"
	FONT = Enum.Font.GothamBold,
	TEXT_SIZE = 16,
	TEXT_COLOR = Color3.fromRGB(255, 200, 120),
}

return CurrencyConfig
