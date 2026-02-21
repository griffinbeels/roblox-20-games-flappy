# Analytics System

How the analytics system works, event categories, currently tracked events, and how to add new ones.

## Architecture

```
Client: Analytics.luau  --(RemoteEvent)--> Server: AnalyticsService.luau --> Roblox AnalyticsService
```

Roblox's `AnalyticsService` only works **server-side** in published experiences. The system uses a thin client facade that fires structured payloads to the server via a `RemoteEvent` called `AnalyticsRemote` (created at runtime in `ReplicatedStorage.Remotes`). The server validates, rate-limits, and forwards them to the Roblox API.

All calls are wrapped in `pcall` — analytics will warn but never crash the game, including in Studio where `AnalyticsService` is unavailable.

### Files

| File | Location | Role |
|---|---|---|
| `AnalyticsConfig.luau` | `src/shared/` | Event name constants and progression identifiers |
| `Analytics.luau` | `src/client/` | Client facade — call these methods to log events |
| `AnalyticsService.luau` | `src/server/` | Server service — receives RemoteEvent, forwards to Roblox |

## Event Categories

The system supports five event categories, matching the Roblox `AnalyticsService` API:

### 1. Custom Events

General-purpose events for tracking player actions. Each event has a name, an optional numeric value, and optional custom fields (key-value pairs).

```lua
Analytics.logCustomEvent(eventName, value?, customFields?)

-- Examples:
Analytics.logCustomEvent("GameStart")
Analytics.logCustomEvent("GameOver", 12, { speed = 1.5 })
Analytics.logCustomEvent("OptionChanged", nil, { option = "ShowGhosts", enabled = true })
```

**When to use:** Any discrete player action or game moment you want to count or measure. This is the most common event type.

### 2. Progression Events

Track attempts at completing a progression (a game run, a level, a quest). Each progression has three phases: start, complete, and fail. Roblox uses these to calculate completion rates and average scores.

```lua
Analytics.logProgressionStart(name, level?)
Analytics.logProgressionComplete(name, level?, value?)
Analytics.logProgressionFail(name, level?, value?)

-- Examples:
Analytics.logProgressionStart("FlappyRun")
Analytics.logProgressionComplete("FlappyRun", nil, 42)  -- score = 42
Analytics.logProgressionFail("FlappyRun", nil, 3)       -- score = 3
```

**When to use:** Anything with a clear start and end where you want completion/failure metrics. The `value` parameter carries the score or other outcome metric.

### 3. Funnel Events

Track multi-step user flows where you want to measure drop-off at each step (e.g., onboarding, tutorial, purchase flow).

```lua
Analytics.logFunnelStep(funnelName, stepNumber, sessionId?)

-- Example:
Analytics.logFunnelStep("Onboarding", 1, "session-abc")
Analytics.logFunnelStep("Onboarding", 2, "session-abc")
```

**When to use:** Ordered sequences of steps where you care about how many players reach each step. Not currently wired but available for future use.

### 4. Economy Events

Track currency flow — earning and spending — for balancing an in-game economy.

```lua
Analytics.logEconomyEvent(flowType, currencyName, balance, itemName?)

-- Example:
Analytics.logEconomyEvent(
    Enum.AnalyticsEconomyFlowType.Source, "Coins", 150, "RunReward"
)
Analytics.logEconomyEvent(
    Enum.AnalyticsEconomyFlowType.Sink, "Coins", 100, "TrailPurchase"
)
```

**When to use:** When the game has a currency system and you want to track earning/spending. Not currently wired but available for future use (T-0900 shop system).

## Currently Tracked Events

| Event | Location in Code | Analytics Calls | What It Captures |
|---|---|---|---|
| Game starts | `GameController.startGame()` | `logCustomEvent("GameStart")` + `logProgressionStart("FlappyRun")` | Player began a run |
| Game over | `GameController.gameOver()` | `logCustomEvent("GameOver", score, {speed})` + `logProgressionComplete/Fail("FlappyRun", nil, score)` | Final score and speed at death. Uses `Complete` if score > 0, `Fail` if score = 0 |
| Play again | `GameController.gameOver()` → `handlePlayAgain()` | `logCustomEvent("PlayAgain")` | Player chose to retry |
| Return to lobby | `GameController.returnToLobby()` | `logCustomEvent("ReturnToLobby")` | Player left the game area |

## How to Add a New Event

### Step 1: Add the event name constant

In `src/shared/AnalyticsConfig.luau`, add a new entry to `AnalyticsConfig.EVENTS`:

```lua
AnalyticsConfig.EVENTS = {
    -- ... existing events ...
    MY_NEW_EVENT = "MyNewEvent",
}
```

### Step 2: Fire the event from client code

In the relevant client module, require `Analytics` and `AnalyticsConfig`, then call the appropriate method:

```lua
local Analytics = require(script.Parent.Analytics)
local AnalyticsConfig = require(ReplicatedStorage.Shared.AnalyticsConfig)

-- Simple event (just counting occurrences):
Analytics.logCustomEvent(AnalyticsConfig.EVENTS.MY_NEW_EVENT)

-- Event with a numeric value:
Analytics.logCustomEvent(AnalyticsConfig.EVENTS.MY_NEW_EVENT, 42)

-- Event with custom fields for segmentation:
Analytics.logCustomEvent(AnalyticsConfig.EVENTS.MY_NEW_EVENT, 42, {
    variant = "B",
    difficulty = "hard",
})
```

**No server changes are needed.** The server already handles all event types generically.

### Step 3: Add a new progression (optional)

If tracking a new progression (not just a one-off event), add a constant to `AnalyticsConfig.PROGRESSION`:

```lua
AnalyticsConfig.PROGRESSION = {
    RUN = "FlappyRun",
    TUTORIAL = "Tutorial",  -- new progression
}
```

Then call `logProgressionStart` / `logProgressionComplete` / `logProgressionFail` at the appropriate points.

## Choosing the Right Event Type

| I want to... | Use |
|---|---|
| Count how often something happens | `logCustomEvent` |
| Measure a value when something happens | `logCustomEvent` with `value` |
| Segment events by properties | `logCustomEvent` with `customFields` |
| Track success/failure rates of attempts | `logProgressionStart/Complete/Fail` |
| Measure drop-off in a multi-step flow | `logFunnelStep` |
| Track currency earned/spent | `logEconomyEvent` |

## Server-Side Details

- **Rate limiting:** The server enforces a minimum 0.05s interval between events per player. Events fired faster than this are silently dropped.
- **Validation:** Payloads must be tables with a string `type` field. Malformed payloads are ignored.
- **Cleanup:** Rate-limit tracking is cleaned up when a player leaves.
- **Studio behavior:** `AnalyticsService` is not available in Studio. Events will warn in the Output window but won't error or crash. This is expected — analytics only work in published experiences.

## A/B Testing Support (Future)

Custom fields on events can carry experiment variant IDs, enabling A/B test analysis:

```lua
Analytics.logCustomEvent("GameOver", score, {
    speed = currentSpeed,
    experiment = "gravity_test",
    variant = "low_gravity",
})
```

This pairs with T-1113 (A/B testing system) which will inject variant IDs into config overrides.
