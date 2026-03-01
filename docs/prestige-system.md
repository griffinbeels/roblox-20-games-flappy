# Prestige System

## Module responsibilities
- `src/shared/ConditionEvaluator.luau`: shared condition DSL evaluator used by missions and prestige unlocks.
- `src/shared/RuntimeTuning.luau`: runtime source of truth for active speed cap and gravity values.
- `src/shared/PrestigeConfig.luau`: config-first balancing for remotes, UI constants, tracking thresholds, tuning bands, and level requirements.
- `src/server/PrestigeService.luau`: authoritative persistence, run stat tracking, tuning validation, prestige unlock checks, and state pushes.
- `src/client/PrestigeManager.luau`: client cache + remote facade that mirrors server state and forwards run/tuning/prestige intents.
- `src/client/PrestigeUI.luau`: modal UI for tuning controls, requirement visibility, apply/reset/recommended actions, and prestige attempts.

## Profile data shape
Server persisted payload:

```lua
{
	version = number,
	progression = {
		level = number,
		lastPrestigeAt = number?,
	},
	tuning = {
		selected = {
			speedCapMultiplier = number,
			gravity = number,
			jumpPowerMultiplier = number,
		},
	},
	stats = {
		total_runs = number,
		best_score = number,
		best_score_at_speed_threshold = number,
		best_score_at_gravity_threshold = number,
		last_score = number,
	},
}
```

## Remote contracts
- `GetPrestigeState` (`RemoteFunction`):
  - Request: none
  - Response: `{ state = <prestigeState> }`
- `PrestigeStateUpdated` (`RemoteEvent`):
  - Push payload: `{ state = <prestigeState>, context = { type = string, ... }? }`
- `PrestigeReportRun` (`RemoteEvent`):
  - Request: `(eventName, payload)`
  - Events: `run_started`, `run_finished`, `run_abandoned`
- `SetPrestigeTuning` (`RemoteFunction`):
  - Request: `{ speedCapMultiplier = number, gravity = number }`
  - Response: `{ success, changed?, clamped?, reasonCode?, message?, state }`
- `AttemptPrestige` (`RemoteFunction`):
  - Request: none
  - Response: `{ success, newLevel?, levelTitle?, reasonCode?, message?, state }`

## Extension points
- Add or rebalance requirements in `PrestigeConfig.LEVELS`.
- Add or rebalance tuning limits in `PrestigeConfig.TUNING_BANDS`.
- Add new condition operators in `ConditionEvaluator` once, then reuse in missions and prestige.
- Keep gameplay readers pointed at `RuntimeTuning` (not direct constants) when adding new tunable mechanics.
