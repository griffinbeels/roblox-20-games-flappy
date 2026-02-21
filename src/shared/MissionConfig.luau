--[[
	MissionConfig.luau

	Config-first mission system:
	- EVENTS: how tracked events mutate mission stats
	- MISSIONS: unlock order, conditions, progress meters, and rewards

	Condition DSL:
	  compare: { type = "compare", path = "stats.best_score", op = ">=", value = 25 }
	  all:     { type = "all", conditions = { ... } }
	  any:     { type = "any", conditions = { ... } }
	  not:     { type = "not", condition = { ... } }
]]

local CurrencyConfig = require(script.Parent.CurrencyConfig)

local MissionConfig = {}

MissionConfig.VERSION = 1
MissionConfig.DATASTORE_NAME = "FlappyBirdMissions"
MissionConfig.AUTOSAVE_INTERVAL = 60
MissionConfig.COMPLETION_SAVE_DELAY = 2
MissionConfig.AUTOSAVE_SPREAD_DELAY = 0.05

MissionConfig.REMOTES = {
	GET_STATE = "MissionGetState",
	REPORT_EVENT = "MissionReportEvent",
	STATE_UPDATED = "MissionStateUpdated",
}

--============================================================================
-- UI
--============================================================================

MissionConfig.UI = {
	-- Full-screen overlay
	OVERLAY_COLOR = Color3.new(0, 0, 0),
	OVERLAY_TRANSPARENCY = 0.4,

	-- Container (centered modal)
	CONTAINER_WIDTH = 460,
	CONTAINER_HEIGHT = 520,
	CONTAINER_BG_COLOR = Color3.fromRGB(28, 36, 44),
	CONTAINER_BG_TRANSPARENCY = 0.05,
	CONTAINER_CORNER_RADIUS = UDim.new(0, 12),

	-- Header
	HEADER_HEIGHT = 50,
	TITLE_TEXT = "MISSIONS",
	TITLE_FONT = Enum.Font.GothamBlack,
	TITLE_COLOR = Color3.fromRGB(255, 220, 100),
	TITLE_SIZE = 28,
	TITLE_STROKE_COLOR = Color3.fromRGB(80, 50, 10),
	TITLE_STROKE_TRANSPARENCY = 0.4,
	CLOSE_BUTTON_SIZE = 36,
	CLOSE_BUTTON_COLOR = Color3.fromRGB(200, 60, 60),
	CLOSE_BUTTON_FONT = Enum.Font.GothamBlack,

	-- Summary line
	SUMMARY_FONT = Enum.Font.GothamBold,
	SUMMARY_SIZE = 14,
	SUMMARY_COLOR = Color3.fromRGB(210, 210, 210),

	-- List
	LIST_PADDING = 8,
	SCROLLBAR_THICKNESS = 5,
	SCROLLBAR_COLOR = Color3.fromRGB(200, 180, 140),

	-- Mission cards
	CARD_HEIGHT = 126,
	CARD_BG_IN_PROGRESS = Color3.fromRGB(52, 60, 72),
	CARD_BG_COMPLETED = Color3.fromRGB(48, 76, 58),
	CARD_BG_LOCKED = Color3.fromRGB(54, 54, 54),
	CARD_CORNER_RADIUS = UDim.new(0, 8),
	TITLE_FONT_CARD = Enum.Font.GothamBold,
	TITLE_SIZE_CARD = 17,
	DESC_FONT = Enum.Font.Gotham,
	DESC_SIZE = 14,
	PROGRESS_FONT = Enum.Font.GothamBold,
	PROGRESS_SIZE = 13,
	REWARD_FONT = Enum.Font.GothamBold,
	REWARD_SIZE = 13,
	STATUS_FONT = Enum.Font.GothamBold,
	STATUS_SIZE = 12,

	-- Progress bar
	PROGRESS_BAR_BG = Color3.fromRGB(30, 30, 30),
	PROGRESS_BAR_FILL = Color3.fromRGB(255, 200, 90),
	PROGRESS_BAR_HEIGHT = 10,

	-- UIScale reference
	REFERENCE_HEIGHT = 800,
	MIN_SCALE = 0.45,
	MAX_SCALE = 1.2,
}

MissionConfig.READY_BUTTON = {
	-- ReadyUI stacks ready buttons vertically to the right of the leaderboard.
	-- STUDS_OFFSET is treated as legacy fallback (Z only by default).
	BILLBOARD_SIZE = UDim2.new(8, 0, 8, 0),
	STUDS_OFFSET = Vector3.new(0, 0, 0),
	ROW_ORDER = 1, -- lower order appears higher in the right-side stack
	LOCAL_OFFSET = Vector3.new(0, 0, 0),
	BG_COLOR = Color3.fromRGB(120, 205, 255),
	BG_TRANSPARENCY = 0.1,
	CORNER_RADIUS = UDim.new(0.15, 0),
	TEXT = "\u{1F3AF}", -- dartboard
	LABEL = "MISSIONS",
	LABEL_FONT = Enum.Font.GothamBlack,
	LABEL_COLOR = Color3.fromRGB(20, 35, 50),
}

--============================================================================
-- EVENT DEFINITIONS
-- source:
--   "client" => only accepted from MissionReportEvent
--   "server" => only accepted via MissionService.reportServerEvent
--
-- update fields:
--   path      : destination path on profile table (example: "stats.runs_started")
--   op        : "add" | "max" | "min" | "set" | "set_now"
--   value     : constant value (optional when using `from`)
--   from      : payload path (example: "score")
--   integer   : floors numeric values before applying
--   clampMin  : minimum numeric value
--   clampMax  : maximum numeric value
--
-- event fields:
--   cooldown  : minimum seconds between accepted events of this type per user
--   startRun  : marks a run as active
--   finishRun : marks a run as inactive (ignored if no active run)
--============================================================================

MissionConfig.EVENTS = {
	run_started = {
		source = "client",
		cooldown = 0.5,
		startRun = true,
		updates = {
			{ path = "stats.runs_started", op = "add", value = 1 },
			{ path = "stats.last_run_started_at", op = "set_now" },
		},
	},

	run_finished = {
		source = "client",
		cooldown = 0.5,
		finishRun = true,
		updates = {
			{ path = "stats.runs_finished", op = "add", value = 1 },
			{ path = "stats.last_run_finished_at", op = "set_now" },
		},
	},

	run_abandoned = {
		source = "client",
		cooldown = 0.5,
		finishRun = true,
		updates = {
			{ path = "stats.runs_abandoned", op = "add", value = 1 },
		},
	},

	leaderboard_opened = {
		source = "client",
		cooldown = 0.25,
		updates = {
			{ path = "stats.leaderboard_views", op = "add", value = 1 },
			{ path = "flags.seen_leaderboard", op = "set", value = true },
		},
	},

	shop_opened = {
		source = "client",
		cooldown = 0.25,
		updates = {
			{ path = "stats.shop_opens", op = "add", value = 1 },
			{ path = "flags.opened_shop", op = "set", value = true },
		},
	},

	score_submitted = {
		source = "server",
		updates = {
			{
				path = "stats.total_score_submitted",
				op = "add",
				from = "score",
				integer = true,
				clampMin = 0,
				clampMax = 10000,
			},
			{
				path = "stats.best_score",
				op = "max",
				from = "score",
				integer = true,
				clampMin = 0,
				clampMax = 10000,
			},
			{
				path = "stats.last_submitted_score",
				op = "set",
				from = "score",
				integer = true,
				clampMin = 0,
				clampMax = 10000,
			},
		},
	},

	bacon_earned = {
		source = "server",
		updates = {
			{
				path = "stats.total_bacon_earned",
				op = "add",
				from = "amount",
				integer = true,
				clampMin = 0,
				clampMax = CurrencyConfig.MAX_SUBMIT_PER_RUN,
			},
			{
				path = "stats.best_bacon_single_run",
				op = "max",
				from = "amount",
				integer = true,
				clampMin = 0,
				clampMax = CurrencyConfig.MAX_SUBMIT_PER_RUN,
			},
		},
	},

	shop_purchase = {
		source = "server",
		updates = {
			{ path = "stats.shop_purchases", op = "add", value = 1 },
			{ path = "flags.made_shop_purchase", op = "set", value = true },
		},
	},

	shop_equip = {
		source = "server",
		updates = {
			{ path = "stats.shop_equips", op = "add", value = 1 },
			{ path = "flags.equipped_shop_item", op = "set", value = true },
		},
	},
}

--============================================================================
-- MISSION DEFINITIONS
--============================================================================

MissionConfig.MISSIONS = {
	{
		id = "onboarding_takeoff",
		title = "First Takeoff",
		description = "Start your first run.",
		condition = { type = "compare", path = "stats.runs_started", op = ">=", value = 1 },
		progress = { path = "stats.runs_started", target = 1 },
		rewards = {
			{ type = "bacon", amount = 20 },
		},
	},
	{
		id = "onboarding_finish_run",
		title = "One Full Run",
		description = "Finish one run.",
		requires = { "onboarding_takeoff" },
		condition = { type = "compare", path = "stats.runs_finished", op = ">=", value = 1 },
		progress = { path = "stats.runs_finished", target = 1 },
		rewards = {
			{ type = "bacon", amount = 25 },
		},
	},
	{
		id = "onboarding_leaderboard",
		title = "Know The Competition",
		description = "Open the leaderboard.",
		requires = { "onboarding_takeoff" },
		condition = { type = "compare", path = "stats.leaderboard_views", op = ">=", value = 1 },
		progress = { path = "stats.leaderboard_views", target = 1 },
		rewards = {
			{ type = "bacon", amount = 25 },
		},
	},
	{
		id = "onboarding_shop_visit",
		title = "Window Shopper",
		description = "Open the shop once.",
		requires = { "onboarding_takeoff" },
		condition = { type = "compare", path = "stats.shop_opens", op = ">=", value = 1 },
		progress = { path = "stats.shop_opens", target = 1 },
		rewards = {
			{ type = "shop_item", itemId = "trail_smoke", duplicateBacon = 100 },
		},
	},
	{
		id = "onboarding_purchase",
		title = "First Upgrade",
		description = "Buy one item from the shop.",
		requires = { "onboarding_shop_visit" },
		condition = { type = "compare", path = "stats.shop_purchases", op = ">=", value = 1 },
		progress = { path = "stats.shop_purchases", target = 1 },
		rewards = {
			{ type = "bacon", amount = 50 },
		},
	},
	{
		id = "score_10",
		title = "Rookie Pilot",
		description = "Reach 10 points in a run.",
		requires = { "onboarding_finish_run" },
		condition = { type = "compare", path = "stats.best_score", op = ">=", value = 10 },
		progress = { path = "stats.best_score", target = 10 },
		rewards = {
			{ type = "bacon", amount = 60 },
		},
	},
	{
		id = "score_25",
		title = "Pipe Reader",
		description = "Reach 25 points in a run.",
		requires = { "score_10" },
		condition = { type = "compare", path = "stats.best_score", op = ">=", value = 25 },
		progress = { path = "stats.best_score", target = 25 },
		rewards = {
			{ type = "shop_item", itemId = "pipe_classic_green", duplicateBacon = 60 },
		},
	},
	{
		id = "score_50",
		title = "Gap Master",
		description = "Reach 50 points in a run.",
		requires = { "score_25" },
		condition = { type = "compare", path = "stats.best_score", op = ">=", value = 50 },
		progress = { path = "stats.best_score", target = 50 },
		rewards = {
			{ type = "shop_item", itemId = "floor_dark_gray", duplicateBacon = 120 },
		},
	},
	{
		id = "score_100",
		title = "Gap Sage",
		description = "Reach 100 points in a run.",
		requires = { "score_50" },
		condition = { type = "compare", path = "stats.best_score", op = ">=", value = 100 },
		progress = { path = "stats.best_score", target = 100 },
		rewards = {
			{ type = "shop_item", itemId = "floor_dark_gray", duplicateBacon = 120 },
		},
	},
	{
		id = "bacon_single_run_10",
		title = "Bacon Rush",
		description = "Earn 10 Bacon in one run.",
		requires = { "onboarding_finish_run" },
		condition = { type = "compare", path = "stats.best_bacon_single_run", op = ">=", value = 10 },
		progress = { path = "stats.best_bacon_single_run", target = 10 },
		rewards = {
			{ type = "bacon", amount = 75 },
		},
	},
	{
		id = "finish_5_runs",
		title = "Persistent Learner",
		description = "Finish 5 runs.",
		requires = { "onboarding_finish_run" },
		condition = { type = "compare", path = "stats.runs_finished", op = ">=", value = 5 },
		progress = { path = "stats.runs_finished", target = 5 },
		rewards = {
			{ type = "bacon", amount = 100 },
		},
	},
	{
		id = "finish_10_runs",
		title = "Seasoned Learner",
		description = "Finish 10 runs.",
		requires = { "onboarding_finish_run" },
		condition = { type = "compare", path = "stats.runs_finished", op = ">=", value = 10 },
		progress = { path = "stats.runs_finished", target = 10 },
		rewards = {
			{ type = "bacon", amount = 200 },
		},
	},
}

local missionById = {}
for _, mission in ipairs(MissionConfig.MISSIONS) do
	missionById[mission.id] = mission
end

function MissionConfig.getMission(missionId)
	return missionById[missionId]
end

function MissionConfig.getEvent(eventName)
	return MissionConfig.EVENTS[eventName]
end

return MissionConfig
