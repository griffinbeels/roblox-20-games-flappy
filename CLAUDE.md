# Flappy Bird - Roblox

A side-scrolling flappy bird game built with Rojo for Roblox Studio.

## Project Structure

- `src/client/` -- Client-side modules (PlayerController, CameraController, PipeManager, UI, etc.)
- `src/server/` -- Server-side modules (LeaderboardService, respawn handling)
- `src/shared/` -- Shared config modules (PlayerConfig, CameraConfig, WorldConfig, GameConfig, PipeConfig, ParallaxConfig, TrailConfig, GhostConfig)
- `docs/` -- Design documentation

## Key Documentation

- **[Player Controller](docs/player-controller.md)** -- How player positioning, physics, and the flying animation system work. READ THIS before modifying PlayerController, animation code, or player start position.
- **[Parallax Background](docs/parallax-background.md)** -- How the background parallax system works: natural 3D parallax, scenery tile recycling, sky backdrop, floor modes, and how to add textures. READ THIS before modifying ParallaxBackground, background layers, or scenery config.
- **[Options UI](docs/options-ui.md)** -- How the in-game options menu works, how to add new toggles, and the ghost toggle wiring.
- **[Effect Registry](docs/effect-registry.md)** -- How the effect system works and how to add new player effects (trail, ghost, etc.). READ THIS before adding a new visual effect.
- **[Analytics](docs/analytics.md)** -- How the analytics system works, event categories, currently tracked events, and how to add new ones. READ THIS before adding new analytics events or modifying tracking.
- **[Leaderboard](docs/leaderboard.md)** -- How the billboard leaderboard works: server data flow, client rendering, config-driven columns/layout, column type registry, init timing, and how to add columns or new element types. READ THIS before modifying LeaderboardUI, LeaderboardService, or leaderboard config.

## Configuration

Each game system has its own config file in `src/shared/`:

- **`PlayerConfig.luau`** -- Player physics: gravity, jump force, forward speed, hover behavior, start position, collision hitbox
- **`CameraConfig.luau`** -- Side-scrolling camera: offset, height, distance, look-at
- **`WorldConfig.luau`** -- Play area boundaries (MIN_Y/MAX_Y) and floor geometry
- **`GameConfig.luau`** -- Game states, speed progression, medal thresholds, leaderboard settings, start button
- **`PipeConfig.luau`** -- Pipe gap, spacing, styles, spawn logic, and difficulty progression
- **`ParallaxConfig.luau`** -- Sky, scenery layers, and floor visual presets
- **`TrailConfig.luau`** -- Trail effect style presets (Smoke, Rainbow, etc.)
- **`GhostConfig.luau`** -- Ghost player transparency
- **`CurrencyConfig.luau`** -- Bacon currency: earn rates, DataStore name, UI styling, game over display
- **`ShopConfig.luau`** -- Cosmetic shop: categories, items, prices, UI constants, DataStore name

## Coding Rules

- **No magic numbers in client/server code.** All tunable constants (sizes, speeds, tolerances, thresholds) must live in the appropriate `src/shared/*Config.luau` file and be required from there. Never hard-code numeric constants directly in game logic modules.
- **Pipes must never have `CanCollide = true`.** All pipe parts (Part-mode and Model-mode) must be non-collidable. Death on pipe contact is handled entirely by the AABB collision detector in `CollisionDetector.luau`, not by Roblox physics. This ensures collision works identically regardless of pipe model/texture.

## Development Environment

- **Rojo is always running externally.** Assume the user has Rojo serving in a separate VS Code terminal. File changes sync to Roblox Studio automatically — do not attempt to start, stop, or manage Rojo.

## Task workflow
- The source of truth for work is TASKS.md.
- At the start of a session: read TASKS.md and propose the single best next task (highest priority, unblocked).
- After completing a task: mark it done in TASKS.md and add any new follow-up tasks discovered.
- Do not start multiple tasks at once.