# TASKS.md — Flappy Blox Backlog

Conventions:
- **DoD = Definition of Done** (what “finished” means).
- Priorities: **P0 = core correctness**, **P1 = core feel**, **P2 = new content**, **P3 = expansions**.
- Keep tasks small enough to finish in 1–3 sessions; split if needed.
- Do not mark the task as complete until the user has signed off.

---

## P0 — Core correctness & robustness (must fix)

### Input / Controls
- [x] T-0001: Centralize jump input binding into JumpInput module
  - DoD: All jump input checks use `JumpInput.isJump()`; UI labels use `JumpInput.getKeyLabel()`.
  - Done: Created `src/client/JumpInput.luau`; updated PlayerController, GameController, ReadyUI, GameOverUI.

### Multiplayer Enhancement
- [x] T-0002: Add "ghosts" representing other players in the server.
    - DOD: For every other player in the server (besides you), display a transparent ghost character that represents their position on the map. This changes in real time according to the other player's sessions.
    - Notes: make sure that this is as performant as possible. Make sure that the opacity of the other players is low.
    - Done: Created `GhostConstants.luau`, `GhostService.luau` (server relay), `GhostManager.luau` (client rendering). Uses UnreliableRemoteEvents at 15Hz, 70% transparency, CFrame interpolation. Added `getVelocityY()` to PlayerController. Wired into server init and GameController.

### Background/Foreground parallax
- [x] T-0021: Background parallax pass (mountains/lava theme baseline)
  - DoD: Background has at least 2 parallax layers that scroll at different speeds and look cohesive.
  - Done: Extracted all parallax config into standalone `ParallaxConfig.luau` with SKY_PRESETS, LAYER_PRESETS, FLOOR_PRESETS and a one-line active config. Added tiling Texture for sky with IMAGE_SIZE auto-aspect-ratio, FOLLOW_RATIO drift with clamping, TEXTURE_OFFSET_V. Scenery layers auto-derive HEIGHT from IMAGE_SIZE. Mesh floor has lastCenterGX early-exit. Simplified module: removed legacy Decal fallback, removed unused _speedMgr param, cached sky Y/Z. Updated docs.

- [ ] T-0022: Foreground parallax layer (between camera and player)
  - DoD: Foreground parallax exists and does not obscure gameplay unfairly.

### Movement Functionality
- [ ] T-0009: Add functionality to click to jump
  - DoD: Instead of only pressing spacebar, allow the user to be able to CLICK to jump as well.
  - NOTES: ONLY FOR PC. Do not do anything about this for mobile.

### Spawning / Scaling / Layout Robustness
- [ ] T-0003: Pipe spawning works across screen sizes / aspect ratios
  - DoD: Pipes spawn and remain playable/visible on common aspect ratios (16:9, 21:9, 4:3) and typical FOV/camera setups.
  - Notes: Avoid UI/camera assumptions that break gameplay.

- [ ] T-0004: Extend bottom pipes downward below the floor (prevent “floor gap” visuals)
  - DoD: Bottom pipe geometry always extends below the visible floor plane so no gaps appear, even with camera shifts.

- [ ] T-0005: Fix pipe asset scaling so textures aren’t stretched
  - DoD: Pipe textures/materials look correct (no stretching); scaling uses proper mesh sizes/tiling/material settings.
  - Notes: Prefer separate mesh variants or correct UV/material tiling instead of uniform scaling.

- [ ] T-0006: Experiment with building an obstacle using studs / the original blocky Roblox vibe, rather than textures.
    - DoD: A pipe object that is able to be scaled up and down without it looking weird. It should be split into the pipe base, and the pipe tip. The pipe base expands to make the gap positioning work, and the pipe pip is added at the end.
---

### UI/UX Scaling 
- [ ] T-0006: Fix Leaderboard UI and implement as a physical BillboardGUI in the spawn area.
    - DoD: Leaderboard scales correctly for all screen sizes; Leaderboard implemented as BillboardGUI that appears as a physical object in game.
    - Notes: This should be implemented as if it was a literal leaderboard in the world. When the player moves off screen, the leaderboard will also move off screen.
- [ ] T-0007: Overhaul the game over screen. This should scale according to the player's screen size and should make sense no matter how it's viewed. 
    - DoD: Scaling works as expected for all screen sizes. The UI/UX looks clean and appealing.

### Cleanup / Fixes
- [ ] T-0008: Fix the Lava texture and make sure it's not creating a weird wall in the background...
    - DoD: The lava floor texture is no longer broken. Broken meaning creating a weird wall of texture in the background.

## P1 — Game feel, UI/UX, and presentation (high impact)

### Start / Game / Game Over UI (8-bit style + motion)
- [ ] T-0100: Global UI typography pass (classic 8-bit font everywhere)
  - DoD: All UI text (start, score, game over, leaderboard) uses the 8-bit font consistently.

- [ ] T-0101: Start Screen layout pass
  - DoD:
    - Title “Flappy Blox” floats.
    - Player character shown floating in start position under title.
    - Instruction reads “PRESS [JumpKey] TO PLAY” using the actual jump key binding.
    - Leaderboard shown using same 8-bit font.

- [ ] T-0102: In-Game score UI improvements
  - DoD: Score display is larger and shows only the number (no “SCORE:” label), using 8-bit font.

- [ ] T-0103: Game Over screen entrance animation
  - DoD:
    - Game over box + play button slide up from bottom.
    - “Game Over” text slides down from top.
    - All text uses 8-bit font.

- [ ] T-0104: New high score celebration (UI-focused, “over-the-top”)
  - DoD:
    - If new record achieved, the new high score is visually dominant (clear highlight + celebratory animation).
    - Celebration is unmistakable vs normal game over.
  - Notes: Coordinate with SFX/music tasks for a combined “moment”.

### “UI is part of the world” start-to-play transition
- [ ] T-0110: Start screen / leaderboard does not instantly hide; it moves off-screen with world motion
  - DoD:
    - When the run begins, the start/leaderboard UI slides/moves left as the player moves right.
    - Movement rate is tied to player/world movement speed.
    - Feels like a world object rather than an overlay.
  - Implementation idea (optional): Put the start/leaderboard UI on an in-world object using BillboardGui.

- [ ] T-0111: “Press [JumpKey] to start” screen has motion (world is already moving)
  - DoD: Before obstacles spawn, the environment scrolls so it feels like motion; no pipes yet.

### Camera
- [ ] T-0120: Make camera system customizable (offset/angle)
  - DoD: Camera offset can be tuned (e.g., shift up, reduce “from below” feeling) via a single config location.
  - Notes: Ensure this does not break pipe visibility or spawning logic.

### Pacing / Difficulty feel
- [ ] T-0130: Re-audit pipe spacing logic vs player speed
  - DoD:
    - As speed increases, spacing approaches the intended “spacing ceiling” consistently.
    - The ceiling itself can increase with speed (controlled, readable progression).
  - Notes: Define explicit formulas/curves in one place.

### Animation / VFX feel
- [ ] T-0140: Flying animation overhaul (superhero flight pose)
  - DoD:
    - Character oriented belly-down toward the floor.
    - Arms stretched forward past the head (not neutral at sides).
    - Pose reads clearly during gameplay.

- [ ] T-0141: Jump “poof/air” effect on jump input
  - DoD: Pressing jump triggers a subtle, readable VFX burst at the character.

- [ ] T-0142: Trail effect behind character
  - DoD: Character leaves a cool trail during flight; performance remains stable.

### Achievements
- [ ] T-0143: Add an achievement system compatible with Roblox.
    - DoD: Use Roblox's built in achievement system to be able to award badges for whenever the users accomplish different milestones (e.g., 1 point, 10 points, 25, 50, 75, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, rank 1 on leaderboard, rank 10 on leaderboard, die 10 times in a row without getting more than 5 points, etc). It should be extremely extensible and support adding any arbitrary conditions and achievements in the future.
---

## P1 — Audio (high impact)

### Sound effects (SFX)
- [ ] T-0200: Add screen transition “woosh” SFX
  - DoD: Woosh plays on transitions (start → play, game over → restart, game over screen appearing).

- [ ] T-0201: Start game SFX
  - DoD: Start uses a clear cue (e.g., “GO!” or starting gun).

- [ ] T-0202: Game over SFX
  - DoD: A distinct game over appearance cue plays (woosh + optional impact sting).

- [ ] T-0203: New high score celebration SFX
  - DoD: Celebration sound plays only when record is broken and pairs with the UI celebration.

- [ ] T-0204: Button click SFX
  - DoD: All clickable UI buttons play a consistent click sound.

- [ ] T-0205: Score increment SFX
  - DoD: Each score increment (passing a pipe OR collecting a coin, depending on scoring model) plays a short sound that isn’t annoying over time.

### Music
- [ ] T-0210: Add “fun music” (basic loop + state handling)
  - DoD:
    - Music plays during gameplay and/or menus as intended.
    - Music does not overlap itself on respawn/restart.
    - Volume respects settings (see Settings tasks).

---

## P1 — Screen transitions (visual polish)

- [ ] T-0300: Fade-to-black transitions between plays (respawn/game over → start)
  - DoD:
    - On game over or respawn, fade to black.
    - Return to start state cleanly.
    - No flicker; input state is controlled during transition.

---

## P2 — Gameplay mechanics (new content)

### Pipe variants / motion
- [ ] T-0400: Pipes that move up/down (new pipe type)
  - DoD: Introduce a pipe variant that moves vertically over time; difficulty is controllable.

- [ ] T-0401: Synchronized moving pipes (gap shifts up/down)
  - DoD: Top and bottom pipes move together so the gap moves up/down freely (gap size constant, position changes).

### Coins + scoring model + progression currency
- [ ] T-0500: Add collectible coin between pipes (guaranteed pickup path)
  - DoD:
    - A large coin appears centered in the gap between pipes.
    - Player path naturally intersects coin so it’s “basically guaranteed” if they pass correctly.
    - Coin collection is consistent and feels good.

- [ ] T-0501: Change scoring to coin-based (score increments on coin pickup)
  - DoD:
    - Score increases when coins are collected (not “magical” passing).
    - Score display updates instantly and matches collected coins.

- [ ] T-0502: Persist lifetime coins/points across runs
  - DoD:
    - After each run, lifetime currency increases by coins earned that run.
    - Value persists across sessions (DataStore or equivalent).
  - Notes: Must handle save failures gracefully.

### Powerups
- [ ] T-0600: Add powerups between pipes (system + 1–2 powerups)
  - DoD:
    - Powerup spawn system exists (rarity/spawn rules configurable).
    - Implement at least one powerup (e.g., Speed Up, Extra Life, Double Coins).
    - Powerup effects are clearly communicated in UI and end correctly.

---

## P2 — Art, themes, and parallax environments

### Visual theme variants (choose one to start)
- [ ] T-0710: Theme variant: City (pipes as buildings, floor as street, city background)
  - DoD: Replace pipes/floor/background with coherent city assets and consistent scale.

- [ ] T-0711: Theme variant: Lava + stalagmites (rock “pipes”, lava floor, mountainous background)
  - DoD: Coherent lava/rock theme with correct parallax and collisions.

- [ ] T-0712: Theme variant: Snow (snowy pipes + winter background)
  - DoD: Coherent snowy theme with readable obstacles.

---

## P3 — Meta progression, shop, cosmetics, and story

### Settings
- [ ] T-0800: Add settings UI toggles
  - DoD:
    - Toggle “Disable Sound” (master mute).
    - Toggle “Disable SFX” (SFX only).
    - Settings persist across sessions.

### Shop + cosmetics economy
- [ ] T-0900: Implement shop using lifetime coins
  - DoD:
    - Player can spend lifetime coins on at least 1 cosmetic item.
    - Purchases persist across sessions.
  - Examples: Pipe skin, floor skin, background theme, trail/jump effect variants, difficulty unlock.

- [ ] T-0901: Cosmetic unlocks: trail variants and jump VFX variants
  - DoD: Multiple unlockable variants exist and can be equipped.

### Achievements / badges
- [ ] T-1000: Add achievements + badges for score milestones
  - DoD:
    - Define milestone list (e.g., 10/25/50/100).
    - On reaching milestone, grant badge/achievement and show a clear notification.
    - Progress persists across sessions.

### Narrative / intro
- [ ] T-1100: Intro animation / cutscene (basic story setup)
  - DoD: A short intro sequence exists and can be skipped; it leads into the start screen.

- [ ] T-1101: Alternate “hero rescue” scoring concept (city theme)
  - DoD: Prototype concept where “people” are collected between buildings instead of coins; evaluate feel.

---

## Notes / Open questions (convert into tasks when decided)
- Scoring model decision: coin-based scoring replaces pass-by scoring (current plan), or supports both modes?
- Exact art direction: pick a baseline theme first (lava+mountains is current implied default).
- Powerup balance: define durations, spawn rates, and UI indicators.
