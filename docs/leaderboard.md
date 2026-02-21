# Leaderboard System

> **Client UI:** `src/client/LeaderboardUI.luau`
> **Server Service:** `src/server/LeaderboardService.luau`
> **Config:** `src/shared/GameConfig.luau` → `GameConfig.LEADERBOARD`
> **Wired in:** `src/client/GameController.luau`, `src/server/init.server.luau`

READ THIS before modifying the leaderboard UI, adding columns, changing layout, or touching score persistence.

## Overview

The leaderboard is a **BillboardGui on a physical Part** in the game world (not a ScreenGui overlay). It sits to the left of the player at the spawn position. When the player starts flying, the camera moves right and the stationary billboard naturally scrolls off-screen. It stays visible across all game states (never explicitly hidden).

All entries (up to `MAX_ENTRIES` = 100) are fetched at once from the server and displayed inside a **ScrollingFrame**. Mouse wheel scrolls on desktop, touch drag on mobile. The player's own row is highlighted and auto-scrolled into view on show.

The UI is **fully data-driven** from `GameConfig.LEADERBOARD`. Layout, columns, colors, fonts, and text are all config — the client module contains no hardcoded values.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SERVER                                                 │
│                                                         │
│  LeaderboardService.init()                              │
│    ├── refreshLeaderboardCache()  ← synchronous first   │
│    │     └── OrderedDataStore:GetSortedAsync()           │
│    ├── Creates GetLeaderboardPage RemoteFunction        │
│    ├── Creates SubmitScore / GetPersonalBest remotes     │
│    └── task.spawn periodic refresh (every 30s)          │
│                                                         │
│  Data stores:                                           │
│    OrderedDataStore("FlappyBirdRanked")  → ranked list  │
│    DataStore("FlappyBirdScores")         → personal bests│
│                                                         │
│  In-memory caches:                                      │
│    leaderboardCache[]   → sorted array of top entries   │
│    playerRankIndex{}    → userId → rank position        │
│    cachedBests{}        → userId → best score           │
└────────────────────────────┬────────────────────────────┘
                             │ RemoteFunction / RemoteEvents
┌────────────────────────────▼────────────────────────────┐
│  CLIENT                                                 │
│                                                         │
│  LeaderboardUI.init()                                   │
│    ├── Creates Part + BillboardGui in workspace         │
│    ├── Creates ScrollingFrame for entry list            │
│    ├── Pre-creates MAX_ENTRIES rows with columns        │
│    └── task.spawn(ensureRemote)                         │
│                                                         │
│  LeaderboardUI.show()                                   │
│    ├── Enables billboard                                │
│    └── task.spawn(fetchAll) → InvokeServer()            │
│                                                         │
│  fetchAll()                                             │
│    ├── ensureRemote() — waits for remote if needed      │
│    ├── InvokeServer() — returns all entries at once     │
│    ├── Populates rows via COLUMN_UPDATERS[type]         │
│    ├── Sets CanvasSize based on entry count             │
│    └── Auto-scrolls to player's highlighted row         │
└─────────────────────────────────────────────────────────┘
```

## Init Timing (Critical)

The server loads the DataStore cache **before** creating the `GetLeaderboardPage` remote. This prevents a race condition where the client finds the remote and calls `InvokeServer` while the cache is still empty.

```
Server init sequence:
  1. Create Remotes folder
  2. Create GetPersonalBest + SubmitScore remotes
  3. refreshLeaderboardCache()          ← blocks until DataStore loads
  4. Create GetLeaderboardPage remote   ← client can now find it
  5. Start periodic refresh loop

Client init sequence:
  1. LeaderboardUI.init()               ← creates billboard + ScrollingFrame, spawns ensureRemote()
  2. ... other inits ...
  3. startReady() → LeaderboardUI.show()
  4. fetchAll() → ensureRemote()        ← WaitForChild("GetLeaderboardPage")
  5. InvokeServer()                     ← cache is guaranteed populated
```

If you reorder the server init, you **must** keep `refreshLeaderboardCache()` before the `GetLeaderboardPage` remote creation. Otherwise the client will get empty data on first load.

## Data Flow

### Score submission
```
Player dies → GameController.gameOver()
  → ScoreManager.submitFinalScore()
    → SubmitScore:FireServer(score)
      → LeaderboardService.savePlayerBest()
        ├── DataStore:UpdateAsync() (atomic, highest-wins)
        ├── OrderedDataStore:SetAsync()
        └── updateCacheInPlace()  ← instant in-memory update
```

### Leaderboard fetch
```
LeaderboardUI.show()
  → task.spawn(fetchAll)
    → GetLeaderboardPage:InvokeServer()
      → Server returns all cached entries (up to MAX_ENTRIES)
      → Returns { entries[], playerRank, totalEntries }
    → Client populates pre-created rows via COLUMN_UPDATERS[type]
    → Sets CanvasSize to fit entries
    → Auto-scrolls to player's row (via task.defer)
```

### Scrolling
```
Mouse wheel / touch drag on ScrollingFrame
  → Roblox handles scroll natively (no remote calls)
```

## Config Reference (`GameConfig.LEADERBOARD`)

### Top-level

| Key | Type | Purpose |
|-----|------|---------|
| `CACHE_REFRESH_INTERVAL` | number | Seconds between server cache refreshes |
| `MAX_ENTRIES` | number | Max entries cached from OrderedDataStore |
| `TEXT_MIN_SIZE` / `TEXT_MAX_SIZE` | number | UITextSizeConstraint bounds for all labels |

### `PART` — invisible anchor in workspace

| Key | Type | Purpose |
|-----|------|---------|
| `POSITION` | Vector3 | World position of billboard anchor |
| `SIZE` | Vector3 | Part size (small, invisible) |
| `NAME` | string | Part name (also used by GameController cleanup) |
| `TRANSPARENCY` | number | 1 = fully invisible |

### `BILLBOARD` — BillboardGui properties

| Key | Type | Purpose |
|-----|------|---------|
| `SIZE` | UDim2 | Studs-based size (e.g. 30x40) |
| `MAX_DISTANCE` | number | Max render distance |
| `ALWAYS_ON_TOP` | boolean | false = real world object feel |

### `CONTAINER` — background panel

| Key | Type | Purpose |
|-----|------|---------|
| `BG_COLOR` | Color3 | Background color |
| `BG_TRANSPARENCY` | number | 0 = opaque, 1 = invisible |
| `CORNER_RADIUS` | UDim | Rounded corners |
| `PADDING_X` | number | Horizontal padding fraction (each side) |

### `SCROLL` — scrollable area

| Key | Type | Purpose |
|-----|------|---------|
| `START_Y` | number | Top of scroll area (fraction of container) |
| `END_Y` | number | Bottom of scroll area (fraction of container) |
| `BAR_THICKNESS` | number | Scrollbar width in pixels |
| `BAR_COLOR` | Color3 | Scrollbar color |
| `BAR_TRANSPARENCY` | number | Scrollbar transparency |
| `TOP_PADDING` | number | Padding above first row (fraction of scroll frame) |
| `BOTTOM_PADDING` | number | Padding below last row (fraction of scroll frame) |

### `TITLE`, `PLAYER_RANK`, `EMPTY_MESSAGE`

Each is a sub-table with position (`Y`), size (`HEIGHT`), font, color, and text fields. See the inline comments in `GameConfig.luau` for all fields.

### `ROWS` — row layout and appearance

| Key | Type | Purpose |
|-----|------|---------|
| `WIDTH` | number | Row width (fraction of scroll frame) |
| `HEIGHT` | number | Row height (fraction of container) |
| `GAP` | number | Vertical gap between rows (fraction of container) |
| `BG_COLOR` / `BG_TRANSPARENCY` | | Default row background |
| `HIGHLIGHT_COLOR` / `HIGHLIGHT_TRANSPARENCY` | | Current player's row |
| `COLUMN_GAP` | number | Horizontal gap between columns |
| `COLUMN_PAD_LEFT` / `COLUMN_PAD_RIGHT` | number | Padding inside row |

### `COLUMNS` — data-driven column definitions

Array of tables, auto-laid-out left to right within each row. Each entry specifies a `type` (defaults to `"text"`), a `key` mapping to the leaderboard entry field, and type-specific rendering properties.

Available entry fields from server: `rank`, `displayName`, `score`, `userId`.

## Column Type System

The client uses a **creator/updater registry** to render columns. Each type has two functions:

| Table | Purpose | Signature |
|-------|---------|-----------|
| `COLUMN_CREATORS[type]` | Builds the UI element once | `(colDef, parent, xCursor, width) → Instance` |
| `COLUMN_UPDATERS[type]` | Populates element per data row | `(element, colDef, entry)` |

### Built-in types

**`"text"`** (default) — TextScaled TextLabel
```lua
{
    key = "displayName",        -- field on leaderboard entry
    width = 0.52,               -- fraction of row width
    align = Enum.TextXAlignment.Left,
    font = Enum.Font.GothamBold,
    color = Color3.fromRGB(230, 220, 200),
    prefix = "",                -- optional: prepended to value
    suffix = "",                -- optional: appended to value
}
```

**`"image"`** — ImageLabel with aspect ratio lock
```lua
{
    type = "image",
    key = "userId",             -- value passed to image resolver
    imageType = "avatar_headshot", -- resolver name (see below)
    width = 0.10,
    cornerRadius = UDim.new(1, 0), -- optional: circle
    aspectRatio = 1,            -- optional: default 1 (square)
    bgColor = Color3.new(0,0,0),   -- optional
    bgTransparency = 1,        -- optional
}
```

### Image resolvers (`IMAGE_RESOLVERS` table)

| Name | Input | Output |
|------|-------|--------|
| `avatar_headshot` | userId | `rbxthumb://type=AvatarHeadShot&id=ID&w=150&h=150` |
| `avatar_bust` | userId | `rbxthumb://type=AvatarBust&id=ID&w=150&h=150` |
| `asset` | assetId | `rbxassetid://ID` |

## How-To Guides

### Move or resize the billboard

Edit `GameConfig.LEADERBOARD`:
```lua
PART = { POSITION = Vector3.new(-20, 30, 0), ... },
BILLBOARD = { SIZE = UDim2.new(20, 0, 25, 0), ... },
```

### Add a column (e.g. avatar icons)

Uncomment or add an entry in `GameConfig.LEADERBOARD.COLUMNS`:
```lua
COLUMNS = {
    {
        type = "image",
        key = "userId",
        imageType = "avatar_headshot",
        width = 0.10,
        cornerRadius = UDim.new(1, 0),
    },
    -- existing rank, name, score columns...
}
```

### Add a new column type

1. Add a creator to `COLUMN_CREATORS` in `LeaderboardUI.luau`:
```lua
COLUMN_CREATORS.badge = function(colDef, parent, xCursor, width)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(width, 0, 1, 0)
    frame.Position = UDim2.new(xCursor, 0, 0, 0)
    -- ... build your UI element ...
    frame.Parent = parent
    return frame
end
```

2. Add an updater to `COLUMN_UPDATERS`:
```lua
COLUMN_UPDATERS.badge = function(element, colDef, entry)
    -- ... populate element from entry[colDef.key] ...
end
```

3. Use it in config:
```lua
{ type = "badge", key = "rank", width = 0.08 }
```

### Add an image resolver

Add one line to `IMAGE_RESOLVERS` in `LeaderboardUI.luau`:
```lua
IMAGE_RESOLVERS.group_icon = function(value)
    return string.format("rbxthumb://type=GroupIcon&id=%s&w=150&h=150", tostring(value))
end
```

### Change row highlight logic

Edit `fetchAll()` in `LeaderboardUI.luau`. The highlight currently checks `entry.userId == localPlayer.UserId`. To highlight top-3 differently, modify that block.

### Add a new data field from the server

1. Add the field in `LeaderboardService.init()` inside the `OnServerInvoke` handler's entry builder:
```lua
table.insert(entries, {
    rank = i,
    displayName = e.displayName,
    score = e.score,
    userId = e.userId,
    myNewField = e.myNewField,  -- add here
})
```

2. Reference it in a column config: `{ key = "myNewField", ... }`

### Populate test data (Studio)

Run in the command bar:
```lua
game.ReplicatedStorage.Remotes.PopulateTestData:FireServer()
```

To clear all data:
```lua
game.ReplicatedStorage.Remotes.ClearLeaderboard:FireServer()
```

## Cleanup

`GameController.cleanupLeftoverObjects()` destroys any Part named `GameConfig.LEADERBOARD.PART.NAME` on startup to prevent duplicate billboards from hot-reload or Studio restarts. If you rename the Part, update the cleanup check.

## Visibility Behavior

The billboard is **never explicitly hidden** during gameplay. `LeaderboardUI.show()` is called during `startReady()` to enable it and refresh data. It stays enabled across PLAYING, GAME_OVER, and back to READY states. The camera naturally pans it off-screen during gameplay.

`LeaderboardUI.hide()` exists as API but is not called by GameController. It is available for future use (e.g., lobby mode).
