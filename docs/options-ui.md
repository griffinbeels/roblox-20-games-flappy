# Options UI Design Doc

> **File:** `src/client/OptionsUI.luau`
> **Wired in:** `src/client/GameController.luau`

## Overview

OptionsUI provides an in-game settings menu accessible via a small gear icon in the top-right corner. It is always visible across all game states (menu, ready, playing, game over). Currently it contains a single toggle for ghost visibility; new toggles can be added with one function call.

## UI Layout

```
                                 [top-right corner]
                                        ┌─────┐
                                        │  ⚙  │  ← GearButton (36x36)
                                        └─────┘
                                 ┌──────────────────┐
                                 │ Show Ghosts   ON  │  ← toggle row
                                 │ (future)     OFF  │
                                 └──────────────────┘
                                    ↑ OptionsPanel (180x48, hidden by default)
```

- **GearButton**: `TextButton` at `UDim2.new(1, -46, 0, 10)`. Toggles panel visibility on click.
- **OptionsPanel**: `Frame` anchored to top-right, positioned below the gear button. Dark semi-transparent background (`Color3.fromRGB(20, 20, 20)` at 80% opacity). Starts hidden.
- **Toggle rows**: Each row has a `TextLabel` (setting name) and a `TextButton` showing ON (green) or OFF (red).

The ScreenGui uses `DisplayOrder = 10` so it renders above all other game UI.

## API

### `OptionsUI.init()`

Creates the ScreenGui, gear button, dropdown panel, and all toggle rows. Call once during startup. The UI is immediately visible (gear button always shown).

### `OptionsUI.getOption(name: string) -> boolean`

Returns the current value of a named option. Returns `nil` if the option doesn't exist.

```lua
if OptionsUI.getOption("ShowGhosts") then ...
```

### `OptionsUI.onOptionChanged(name: string, callback: (boolean) -> ())`

Registers a callback that fires whenever the named option is toggled. Multiple callbacks per option are supported.

```lua
OptionsUI.onOptionChanged("ShowGhosts", function(enabled)
    GhostManager.setEnabled(enabled)
end)
```

### `OptionsUI.show()` / `OptionsUI.hide()`

Enables/disables the entire ScreenGui. Not currently used (the UI stays visible), but follows the standard module pattern for consistency.

### `OptionsUI.destroy()`

Destroys the ScreenGui and clears all internal state (toggle buttons, callbacks).

## Adding a New Toggle

1. Add a default value to the `options` table at the top of OptionsUI:

```lua
local options = {
    ShowGhosts = true,
    NewOption = false,  -- add here
}
```

2. Add a `createToggleRow` call in `OptionsUI.init()`, after the existing rows:

```lua
createToggleRow(panel, "NewOption", "Display Label", 2)
```

3. Increase the panel height to fit the new row (each row is 32px + 4px padding):

```lua
panel.Size = UDim2.new(0, 180, 0, 84)  -- was 48, add 36 per row
```

4. Wire the callback in GameController (or wherever appropriate):

```lua
OptionsUI.onOptionChanged("NewOption", function(enabled)
    SomeModule.setSomething(enabled)
end)
```

## Ghost Toggle Wiring

The ghost toggle connects OptionsUI to GhostManager through GameController:

```
OptionsUI (click)
    → fires onOptionChanged("ShowGhosts", enabled)
        → GameController callback
            → GhostManager.setEnabled(enabled)
                → updates Transparency on all ghost BaseParts
                → toggles GhostNametag BillboardGui.Enabled
```

### GhostManager.setEnabled(enabled)

- **`false`**: Sets all ghost BasePart transparency to `1` (invisible), disables nametag BillboardGuis
- **`true`**: Restores transparency to `GHOST_TRANSPARENCY` (0.8), re-enables nametags
- Stores the `enabled` state so newly spawned ghosts respect it
- Non-collision properties (`CanCollide`, `CanQuery`, `CanTouch`) are unaffected by the toggle

## Lifecycle

OptionsUI is initialized eagerly in `GameController.init()` alongside other hub/UI modules (not lazy-loaded with game systems). This ensures the gear icon is visible immediately, even before the player starts a game.

The ghost toggle callback is wired in `GameController.initGameSystems()` because it depends on GhostManager, which is lazy-loaded.

```
GameController.init()
    ├── OptionsUI.init()          ← UI created, gear visible
    └── GameController.initGameSystems()
            ├── GhostManager.init()
            └── OptionsUI.onOptionChanged("ShowGhosts", ...)  ← wired here
```
