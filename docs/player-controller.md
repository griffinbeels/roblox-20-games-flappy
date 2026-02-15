# PlayerController Design Doc

> **File:** `src/client/PlayerController.luau`
> **Config:** `src/shared/Constants.luau` under `Constants.PLAYER`

## Overview

The PlayerController takes over the player's Roblox avatar and turns it into a side-scrolling flappy-bird character. It replaces all default Roblox movement with custom physics: constant gravity pulls the player down, pressing Space gives an instant upward impulse, and the character moves forward automatically at increasing speed.

The character flies in a **superman pose** -- body horizontal, belly down, head pointing in the travel direction (+X), arms stretched above the head.

## Architecture

PlayerController is a **singleton module** (not instanced). It uses module-level locals for all state. Key references:

- `character`, `humanoidRootPart`, `humanoid` -- the player's avatar
- `bodyPosition` (BodyPosition) -- legacy force object, mostly disabled; only used as a last-resort anti-clip near the floor
- `bodyGyro` (BodyGyro) -- keeps the character in the horizontal flying orientation
- `currentVelocity` (Vector3) -- the authoritative velocity; applied directly to `HumanoidRootPart.Velocity` each frame

## Positioning

All player positioning derives from **one config value**:

```
Constants.PLAYER.START_POSITION = Vector3.new(X, Y, Z)
```

| State | Position used |
|-------|-------------|
| **Reset / Init** | `START_POSITION` directly |
| **Ready (pre-game hover)** | `START_POSITION + Vector3.new(0, HOVER_Y_OFFSET, 0)` |
| **Playing** | Physics-driven from wherever ready state left off |

The hover config (`HOVER_Y_OFFSET`, `HOVER_AMPLITUDE`, `HOVER_SPEED`) all live under `Constants.PLAYER` -- there is no separate `READY` table. All player config is in one place.

### Why this matters

Previously `READY.PLAYER_Y` was an absolute Y coordinate that silently overrode `START_POSITION.Y`. This meant changing `START_POSITION` had no visible effect. The fix was making all ready-state positioning **relative** to `START_POSITION`.

## Body Orientation (getFlyingCFrame)

```lua
CFrame.lookAt(pos, pos + Vector3.new(1, 0, 0)) * CFrame.Angles(math.rad(-90) + tilt, 0, 0)
```

1. `lookAt` faces the character along +X (the travel direction)
2. The -90 degree X rotation tips the character from upright to horizontal (belly down)
3. `tilt` adds slight pitch based on vertical velocity (nose up when rising, nose down when falling)

The BodyGyro maintains this orientation continuously. During gameplay, tilt is `clamp(velocityY / 200, -0.4, 0.4)`.

## Animation System (Flying Pose)

### The problem

Roblox's built-in animation system writes to `Motor6D.Transform` every frame. Even after disabling the `Animate` script and stopping all animation tracks, the `Animator` instance continues resetting transforms. Setting `.Transform` in `Heartbeat` gets overwritten before rendering.

### The solution (three layers)

1. **Disable the Animate script** (`animate.Disabled = true`) -- stops new animations from being queued
2. **Destroy the Animator instance** (`humanoid:FindFirstChildOfClass("Animator"):Destroy()`) -- this is the component that actually writes to `.Transform` each frame. Destroying it is the only reliable way to stop overrides.
3. **Apply transforms in RenderStepped** -- `RenderStepped` fires during the render phase, after any remaining animation evaluation, so our transforms get the final word

### Joint setup

Motor6D references are **cached** once per character to avoid searching descendants every frame:

| Joint | Base Transform | Oscillation |
|-------|---------------|-------------|
| RightShoulder | `CFrame.Angles(osc, 0, -180deg)` | X-axis (up/down flap) |
| LeftShoulder | `CFrame.Angles(osc, 0, +180deg)` | X-axis (up/down flap) |
| RightElbow | `CFrame.Angles(osc, 0, 0)` | Small flex |
| LeftElbow | `CFrame.Angles(-osc, 0, 0)` | Small flex (mirrored) |
| RightHip | `CFrame.Angles(osc, 0, 0)` | X-axis (up/down flap) |
| LeftHip | `CFrame.Angles(osc, 0, 0)` | X-axis (up/down flap) |
| RightKnee | `CFrame.Angles(osc, 0, 0)` | Small flex |
| LeftKnee | `CFrame.Angles(osc, 0, 0)` | Small flex |
| Wrists, Ankles | `CFrame.new()` (identity) | None |

The -180/+180 degree Z rotation on shoulders raises the arms above the head. Without it, arms hang at the sides.

### Wind oscillation

Limbs oscillate using sine waves to simulate flapping in the wind:

```lua
local armWave = math.sin(tick() * FLAP_SPEED)
local legWave = armWave  -- same phase (belly-down orientation flips the visual)
```

Arms and legs use the **same** sine value. Because the character is belly-down, the hip rotation visually opposes the shoulder rotation, creating the natural "arm up = leg down" pattern.

**Tuning constants** (hardcoded at top of file):
- `FLAP_SPEED = 8` -- oscillation frequency (rad/s)
- `ARM_FLAP_ANGLE = 15` -- shoulder amplitude (degrees)
- `ELBOW_FLAP_ANGLE = 10` -- elbow amplitude (degrees)
- `LEG_FLAP_ANGLE = 12` -- hip amplitude (degrees)
- `KNEE_FLAP_ANGLE = 8` -- knee amplitude (degrees)

### Cleanup

When the character respawns or returns to the lobby:
- `renderStepConnection` is disconnected
- `cachedMotor6Ds` is set to nil
- The `Animate` script is re-enabled (in `restoreNormalMovement`)

## Physics (Gameplay Loop)

Runs on `Heartbeat`:

1. **Gravity**: `currentVelocity.Y -= GRAVITY * dt`
2. **Floor raycast**: casts down from HumanoidRootPart to detect ground; clamps Y velocity to 0 if on ground
3. **Forward speed**: set from SpeedManager (increases over time)
4. **Boundary clamp**: Y is clamped to `[BOUNDARIES.MIN_Y, BOUNDARIES.MAX_Y]`
5. **Apply**: `humanoidRootPart.Velocity = currentVelocity`

**Jump**: instantly sets `currentVelocity.Y = JUMP_FORCE` and applies to `HumanoidRootPart.Velocity` for immediate response. No cooldown.

BodyPosition is almost always disabled (`MaxForce = 0`). It only activates as a tiny anti-clip force when the character is extremely close to the floor AND falling fast.

## State Lifecycle

```
init() --> reset() --> [GameController calls setReadyPosition()]
                            |
                      [Space pressed]
                            |
                      disableHover() + startUpdate()
                            |
                      [collision detected]
                            |
                      freeze() + disableInput()
                            |
                      [Play Again]
                            |
                      [respawn] --> setReadyPosition() (cycle repeats)
```

## Gotchas for Future Changes

1. **Never set arm/leg positions in Heartbeat** -- the animation system runs after Heartbeat but before rendering. Use RenderStepped.
2. **Always destroy the Animator** -- disabling the Animate script alone is not enough. The Animator persists and writes transforms.
3. **All player positioning must derive from `Constants.PLAYER.START_POSITION`** -- don't introduce absolute Y values elsewhere.
4. **The character is horizontal** -- "above the head" in world space is actually "+X direction" in character local space. Keep this in mind when reasoning about joint rotations.
5. **R15 vs R6** -- joint names differ. The code searches for both (`"RightShoulder"` and `"Right Shoulder"`). R15 has additional joints (elbow, wrist, knee, ankle) that R6 lacks.
6. **Motor6D cache must be cleared on respawn** -- set `cachedMotor6Ds = nil` whenever the character changes, then call `applyFlyingPose()` to rebuild it.
