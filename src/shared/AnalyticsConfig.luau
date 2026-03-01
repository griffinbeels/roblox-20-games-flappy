--[[
	AnalyticsConfig.luau

	Central registry of analytics event names and progression identifiers.
	All analytics calls reference constants from here to avoid string duplication and typos.
]]

local AnalyticsConfig = {}

-- Custom event names (used with LogCustomEvent)
AnalyticsConfig.EVENTS = {
	GAME_START = "GameStart",
	GAME_OVER = "GameOver",
	JUMP = "Jump",
	PLAY_AGAIN = "PlayAgain",
	RETURN_TO_LOBBY = "ReturnToLobby",
	OPTION_CHANGED = "OptionChanged",
	PRESTIGE_TUNING_APPLIED = "PrestigeTuningApplied",
	PRESTIGE_ATTEMPT = "PrestigeAttempt",
	PRESTIGE_SUCCESS = "PrestigeSuccess",
	PRESTIGE_RUN_OUTCOME = "PrestigeRunOutcome",
}

-- Progression names (used with LogProgressionEvent)
AnalyticsConfig.PROGRESSION = {
	RUN = "FlappyRun", -- each game run is a progression attempt
}

return AnalyticsConfig
