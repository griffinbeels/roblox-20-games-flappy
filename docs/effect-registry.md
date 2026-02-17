# Effect Registry Design Doc

> **File:** `src/client/EffectRegistry.luau`
> **Wired in:** `src/client/GameController.luau`

## Overview

EffectRegistry is a singleton that manages player visual effects (Trail, Ghost, etc.) through a standard lifecycle interface. GameController calls bulk methods on the registry instead of individual effect modules, so adding a new effect requires only one line of registration — no edits to lifecycle call sites.

## Standard Effect Interface

Every effect module registered with the registry may implement any subset of these methods. The registry skips missing ones.

| Method | Called by | When | Purpose |
|--------|-----------|------|---------|
| `init()` | `EffectRegistry.initAll()` | `GameController.initGameSystems()` | One-time setup (create listeners, folders, etc.) |
| `start()` | `EffectRegistry.startAll()` | (not currently called — available for future use) | Begin the effect |
| `stop()` | `EffectRegistry.stopAll()` | `stopAllGameSystems()`, `returnToLobby()`, `reset()` | Disable the effect gracefully |
| `reset()` | `EffectRegistry.resetAll()` | `startReady()` (new round begins) | Destroy + recreate for a fresh state |
| `destroy()` | `EffectRegistry.destroyAll()` | `GameController.destroy()` | Remove all instances and connections permanently |

## Registered Effects

| Name | Module | Methods Implemented |
|------|--------|-------------------|
| `Trail` | `src/client/TrailManager.luau` | `init`, `start`, `stop`, `reset`, `destroy` |
| `Ghost` | `src/client/GhostManager.luau` | `init`, `destroy` |
| `Poof` | `src/client/PoofManager.luau` | `init`, `stop`, `reset`, `destroy` |

## Lifecycle Flow

```
GameController.init()
    └── GameController.initGameSystems()
            ├── EffectRegistry.register("Trail", TrailManager)
            ├── EffectRegistry.register("Ghost", GhostManager)
            ├── EffectRegistry.register("Poof", PoofManager)
            ├── EffectRegistry.initAll()        ← calls init() on each
            └── OptionsUI.onOptionChanged(...)  ← wires ghost toggle

GameController.startReady()
    └── EffectRegistry.resetAll()               ← calls reset() on each

stopAllGameSystems()                            ← called by gameOver, returnToLobby, reset, etc.
    └── EffectRegistry.stopAll()                ← calls stop() on each

GameController.destroy()
    └── EffectRegistry.destroyAll()             ← calls destroy() on each
```

## Adding a New Effect

### Step 1: Create the effect module

Create `src/client/MyEffect.luau`. Implement whichever lifecycle methods apply:

```lua
local MyEffectConfig = require(game:GetService("ReplicatedStorage").Shared.MyEffectConfig)

local MyEffect = {}

function MyEffect.init()
    -- One-time setup: create folders, connect events, etc.
end

function MyEffect.start()
    -- Begin the effect (optional — not all effects need this)
end

function MyEffect.stop()
    -- Pause/disable the effect gracefully
end

function MyEffect.reset()
    -- Destroy current instances and recreate for a fresh round
end

function MyEffect.destroy()
    -- Full cleanup: remove all instances, disconnect all connections
end

return MyEffect
```

### Step 2: Create a config file (if needed)

Create `src/shared/MyEffectConfig.luau` for any tunable constants. Per project coding rules, no magic numbers in client code.

### Step 3: Register in GameController

Add one line in `GameController.initGameSystems()`, alongside the existing registrations:

```lua
EffectRegistry.register("MyEffect", require(script.Parent.MyEffect))
```

That's it. The registry handles all lifecycle calls automatically.

### Step 4 (optional): Wire options toggle

If the effect needs a user-facing toggle in the options menu, wire it in `initGameSystems()`:

```lua
OptionsUI.onOptionChanged("ShowMyEffect", function(enabled)
    EffectRegistry.get("MyEffect").setEnabled(enabled)
end)
```

See [Options UI](options-ui.md) for how to add the toggle itself.

## API Reference

### `EffectRegistry.register(name: string, effectModule: table)`

Registers an effect module under the given name. Call during `initGameSystems()`.

### `EffectRegistry.get(name: string) -> table?`

Returns a registered effect module by name. Used for direct access to effect-specific methods like `setEnabled()`.

### `EffectRegistry.initAll()` / `startAll()` / `stopAll()` / `resetAll()` / `destroyAll()`

Iterates all registered effects and calls the corresponding method on each, skipping any that don't implement it.
