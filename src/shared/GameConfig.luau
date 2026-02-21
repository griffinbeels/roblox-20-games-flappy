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
	INCREASE_RATE = 0.25,    -- Speed increase per second
	MAX_MULTIPLIER = 2.5,   -- Cap on speed increase
}

--============================================================================
-- MEDAL THRESHOLDS
-- Score required for each medal tier on the Game Over screen.
--============================================================================
GameConfig.MEDALS = {
	BRONZE = 10,
	SILVER = 40,
	GOLD = 70,
}

--============================================================================
-- LEADERBOARD
-- Global leaderboard billboard in the game world.
--
-- HOW TO MODIFY:
--   Position/size   → PART, BILLBOARD tables
--   Title text      → TITLE table
--   Row appearance  → ROWS table
--   Add/remove cols → COLUMNS array  (auto-laid-out left to right)
--   Scroll area     → SCROLL table
--   Bottom label    → PLAYER_RANK table
--   Empty state     → EMPTY_MESSAGE table
--============================================================================
GameConfig.LEADERBOARD = {
	CACHE_REFRESH_INTERVAL = 30, -- seconds between server cache refreshes
	MAX_ENTRIES = 100,            -- max entries to cache from OrderedDataStore
	REFETCH_DELAY = 3,            -- seconds before client re-fetches to pick up background-resolved names

	-- Billboard Part (invisible anchor in workspace)
	PART = {
		POSITION = Vector3.new(-25, 25, 0),
		SIZE = Vector3.new(1, 1, 1),
		NAME = "LeaderboardBillboard",
		TRANSPARENCY = 1,
	},

	-- BillboardGui
	BILLBOARD = {
		SIZE = UDim2.new(30, 0, 40, 0),  -- studs-based for resolution independence
		MAX_DISTANCE = 200,
		ALWAYS_ON_TOP = false,
	},

	-- Viewport-adaptive placement/scaling so leaderboard + attached ready buttons
	-- stay on-screen across desktop/mobile resolutions.
	ADAPTIVE_LAYOUT = {
		ENABLED = true,
		REFERENCE_WIDTH = 1366,
		REFERENCE_HEIGHT = 768,
		MIN_SCALE = 0.85,
		MAX_SCALE = 1.00,
		SCREEN_CENTER_X = 0.22, -- center of leaderboard from left edge (0..1)
		LOCK_SCREEN_Y = false,  -- keep world Y from PART.POSITION unless true
		SCREEN_CENTER_Y = 0.58, -- used only when LOCK_SCREEN_Y = true
		BUTTON_SCALE_MULTIPLIER = 1.00, -- additional scale for Shop/Missions buttons
	},

	-- Ready button column layout (world-space stack to the right of leaderboard)
	READY_BUTTON_LAYOUT = {
		VERTICAL_GAP_STUDS = 1.5,  -- vertical spacing between buttons in the stack
		SIDE_MARGIN_STUDS = 1.5,   -- horizontal gap from leaderboard right edge to button stack
		COLUMN_Y_OFFSET_STUDS = 0, -- global Y nudge for the whole stack (anchored to leaderboard top)
	},

	-- Text size constraints (for all TextScaled labels)
	TEXT_MIN_SIZE = 8,
	TEXT_MAX_SIZE = 12,

	-- Container (the background panel that fills the billboard)
	CONTAINER = {
		BG_COLOR = Color3.fromRGB(30, 25, 15),
		BG_TRANSPARENCY = 0.15,
		CORNER_RADIUS = UDim.new(0.10, 0),
		PADDING_X = 0.05, -- horizontal padding (fraction of width, applied to each side)
	},

	-- Title
	TITLE = {
		TEXT = "LONGEST RUNS",
		FONT = Enum.Font.GothamBlack,
		COLOR = Color3.fromRGB(255, 180, 50),
		STROKE_COLOR = Color3.fromRGB(80, 50, 10),
		STROKE_TRANSPARENCY = 0.4,
		Y = 0.01,       -- vertical position (fraction of container)
		HEIGHT = 0.08,   -- height (fraction of container)
	},

	-- Scrollable area (between title and player-rank label)
	SCROLL = {
		VISIBLE_ROWS = 9,  -- how many rows visible at once (2 above player + player + 2 below)
		START_Y = 0.10,   -- top of scroll area (fraction of container)
		END_Y = 0.90,     -- bottom of scroll area (fraction of container)
		BAR_THICKNESS = 6, -- scrollbar width in pixels
		BAR_COLOR = Color3.fromRGB(200, 180, 140),
		BAR_TRANSPARENCY = 0.5,
		TOP_PADDING = 0.01,    -- padding inside scroll area (fraction of visible frame)
		BOTTOM_PADDING = 0.01,
		WHEEL_ROWS = 1,        -- rows scrolled per mouse wheel tick
		MOMENTUM_DECAY = 0.94, -- velocity decay per frame at 60fps (higher = longer coast)
		MOMENTUM_MIN_VELOCITY = 10, -- px/sec below which momentum stops
	},

	-- Row layout (inside the ScrollingFrame)
	-- Row height is derived from SCROLL.VISIBLE_ROWS; GAP_RATIO controls spacing.
	ROWS = {
		WIDTH = 0.95,      -- row width (fraction of scroll frame); rows are centered horizontally
		GAP_RATIO = 0.12,  -- fraction of each row slot used for gap (0 = no gap)
		CORNER_RADIUS = UDim.new(0.1, 0),
		BG_COLOR = Color3.fromRGB(40, 35, 25),
		BG_TRANSPARENCY = 0.5,
		HIGHLIGHT_COLOR = Color3.fromRGB(255, 215, 0),     -- current player's row
		HIGHLIGHT_TRANSPARENCY = 0.7,
		COLUMN_GAP = 0.01, -- horizontal gap between columns
		COLUMN_PAD_LEFT = 0.02, -- left padding before first column
		COLUMN_PAD_RIGHT = 0.02, -- right padding after last column
		TEXT_HEIGHT_RATIO = 0.55, -- fraction of row pixel height used for text size (uniform across all columns)
	},

	--[[
		COLUMNS — data-driven column definitions.
		Each entry creates one UI element per row, auto-positioned left to right.
		The `type` field selects the renderer (see LeaderboardUI.luau for the
		full list of supported types and how to add new ones).

		Shared fields (all types):
		  type   (string?) — "text" (default) | "image"
		  key    (string)  — field name on the leaderboard entry
		  width  (number)  — fraction of row width reserved for this column

		"text" fields:
		  align  (Enum)    — TextXAlignment (Left, Center, Right)
		  font   (Enum)    — Font enum
		  color  (Color3)  — text color
		  prefix (string?) — prepended to the displayed value
		  suffix (string?) — appended to the displayed value

		"image" fields:
		  imageType    (string)  — resolver name: "avatar_headshot", "avatar_bust", "asset"
		  cornerRadius (UDim?)   — rounds corners (UDim.new(1,0) = circle)
		  aspectRatio  (number?) — width:height ratio, default 1 (square)
		  bgColor      (Color3?) — background behind the image
		  bgTransparency (number?) — background transparency, default 1

		To add a column, append a table.  To add a column TYPE, see the
		COLUMN_CREATORS / COLUMN_UPDATERS tables in LeaderboardUI.luau.
	]]
	COLUMNS = {
		-- Uncomment the block below to add player avatar icons:
		-- {
		-- 	type = "image",
		-- 	key = "userId",
		-- 	imageType = "avatar_headshot",
		-- 	width = 0.10,
		-- 	cornerRadius = UDim.new(1, 0),
		-- },
		{
			key = "rank",
			width = 0.20,
			align = Enum.TextXAlignment.Left,
			font = Enum.Font.GothamBold,
			color = Color3.fromRGB(255, 180, 50),
			prefix = "#",
		},
		{
			key = "displayName",
			width = 0.52,
			align = Enum.TextXAlignment.Left,
			font = Enum.Font.GothamBold,
			color = Color3.fromRGB(230, 220, 200),
		},
		{
			key = "score",
			width = 0.25,
			align = Enum.TextXAlignment.Right,
			font = Enum.Font.GothamBlack,
			color = Color3.new(1, 1, 1),
		},
	},

	-- Player rank label (bottom of billboard)
	PLAYER_RANK = {
		Y = 0.92,
		HEIGHT = 0.06,
		FONT = Enum.Font.GothamBold,
		COLOR = Color3.fromRGB(200, 180, 140),
		DEFAULT_TEXT = "Play to get ranked!",
		FORMAT = "Your Rank: #%d", -- %d is replaced with the rank number
	},

	-- Empty state (shown when no scores exist)
	EMPTY_MESSAGE = {
		TEXT = "No scores yet",
		FONT = Enum.Font.GothamBold,
		COLOR = Color3.fromRGB(180, 160, 130),
		Y = 0.35,
		HEIGHT = 0.2,
	},
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
