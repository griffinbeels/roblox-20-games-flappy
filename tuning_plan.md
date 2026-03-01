# Tuning Plan (Speed + Pipes + Prestige Progression)

## Goal
Make each prestige feel like a meaningful learning step:

1. The player feels a clear difference between low and high speed-ramp settings.
2. Pipe spacing and gap variance remain readable/fair at every speed.
3. Each prestige trains the skills needed for the next prestige.
4. Progression pacing feels fast enough to iterate, but not grindy or random.

## Important Current Semantics (Read This First)

The user-facing `speedCapMultiplier` field is now a **speed ramp multiplier** (legacy field name kept for compatibility).

- It scales how fast speed ramps up.
- It does **not** directly control the runtime speed multiplier cap anymore.
- The runtime speed multiplier cap is now hidden in `GameConfig.SPEED.INTERNAL_MULTIPLIER_CAP`.

Current speed behavior (simplified):

- Runtime multiplier ramp (before hidden cap): `m(t) = INITIAL_MULTIPLIER + INCREASE_RATE * rampSetting * t`
- Actual forward speed: `max(baseForwardSpeed * m(t), challengeFloorRamp(t))`, then clamped by `MAX_FORWARD_SPEED`

## Critical Progression Blocker (Fix or Account For During Tuning)

Prestige speed graduation still uses the legacy `speedCapMultiplier` tuning band max as the target source (now "ramp setting"), while run validation also checks `maxSpeedMultiplierReached` (runtime multiplier, hidden-capped).

Why this matters:

- Higher prestige tuning bands can allow `speedCapMultiplier` values above the hidden runtime multiplier cap.
- If `INTERNAL_MULTIPLIER_CAP` stays lower than prestige speed graduation targets, some prestige speed-graduation requirements can become impossible.

Current examples to watch:

- `PrestigeConfig.TUNING_BANDS[2+]` allow `speedCapMultiplier.max > 2.5`
- `GameConfig.SPEED.INTERNAL_MULTIPLIER_CAP` is `2.5`

ASAP recommendation:

1. Decide whether prestige speed graduation should target:
   - ramp setting mastery (selected ramp at max), or
   - actual runtime speed multiplier mastery, or
   - actual forward speed mastery (best long-term option)
2. Align `PrestigeConfig.getSpeedGraduationTargetForLevel(...)` and server validation with that definition before deep balancing.

If you skip this, later prestige tuning can feel "wrong" because unlock requirements may not match what the player can physically achieve.

## Current Tuning Surface (What You Can Tune Today)

## A) Speed Tuning (`src/shared/GameConfig.luau`)

### Core ramp + caps

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `SPEED.INITIAL_MULTIPLIER` | Starting runtime speed multiplier | How "hot" the run starts |
| `SPEED.INCREASE_RATE` | Base multiplier ramp/sec (scaled by selected ramp setting) | Main pacing of acceleration |
| `SPEED.RAMP_RATE_MULTIPLIER_DEFAULT` | Default selected ramp setting | Default run vibe before tuning |
| `SPEED.MAX_MULTIPLIER` | Legacy/exposed slider range default | Tuning UI range baseline (legacy semantics) |
| `SPEED.INTERNAL_MULTIPLIER_CAP` | Hidden runtime multiplier cap | How much the multiplier-based phase can grow |
| `SPEED.MAX_FORWARD_SPEED` | Absolute final speed cap (after all scaling) | Hard top-end challenge ceiling |

### Challenge-floor ramp (extra pressure ramp)

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `SPEED.CHALLENGE_FLOOR_RAMP.ENABLED` | Toggle extra long-run speed floor | Enables late-run pressure on "slow" settings |
| `START_DELAY` | Delay before floor ramp starts | Early-run breathing room |
| `DURATION` | Time span of floor easing (before ramp-setting scaling) | How quickly long-run pressure appears |
| `EASING` | Curve shape | How sudden vs gradual the pressure feels |
| `TARGET_SPEED` | Floor target forward speed | Late-run pressure target |

Important interaction:

- The challenge-floor ramp now also scales with the selected speed ramp setting.
- `2.5x` ramp setting advances the floor roughly 2.5x faster than `1.0x`.

## B) Pipe Tuning (`src/shared/PipeConfig.luau`)

### Gap size (difficulty over distance)

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `GAP_MIN` | Smallest allowed gap | Hard-floor difficulty |
| `GAP_MAX` | Starting gap size | Early comfort/readability |
| `GAP_SHRINK_RATE` | Gap shrink per stud traveled | Long-run difficulty curve |

### Gap Y placement (vertical challenge)

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `GAP_Y_MIN`, `GAP_Y_MAX` | Base gap center bounds | Overall vertical playable band |
| `GAP_Y_MAX_DELTA` | Base max Y jump between consecutive gaps | Fairness / smoothness |
| `GAP_Y_SPEED_VARIANCE.enabled` | Toggle speed-adaptive Y variance | Slow=wild, fast=tight mode |
| `slowForwardSpeed`, `fastForwardSpeed` | Speed range for blending slow/fast variance profiles | Where the variance transition happens |
| `GAP_Y_SPEED_VARIANCE.easing` | Blend curve for slow->fast variance | Transition feel |
| `slow.min/max/maxDelta` | Gap Y bounds + delta at slow speeds | Slow-run novelty / exploration |
| `fast.min/max/maxDelta` | Gap Y bounds + delta at fast speeds | High-speed readability / fairness |

### Horizontal spacing (most important for speed feel)

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `SPACING_FLOOR`, `SPACING_CEILING` | Absolute min/max spacing clamps | Global safety rails |
| `SPACING_SPEED_POINTS` | Speed->spacing curve control points | Core readability scaling with speed |
| `SPACING_SPEED_INTERP_EXPONENT` | Shape within curve segments | How spacing grows between points |
| `SPACING_SAMPLE_EXPONENT` | Random bias inside min/max range | "Dense bias" vs "wide bias" |
| `SPACING_MIN_FORWARD_SPEED_RATIO` | Dynamic floor: `minSpacing >= forwardSpeed * ratio` | Time-to-react guarantee at current speed |
| `SPACING_CAP_START_RELIEF.enabled` | Early-run spacing relief for high-cap contexts | Prevents dense starts on high-speed contexts |
| `referenceCap`, `fullEffectCap` | When relief begins/full strength | Relief scaling window |
| `maxVirtualSpeedBoost` | How much virtual speed gets added to spacing axis | Relief strength |
| `capExponent` | Relief scaling curve | Relief sensitivity |
| `fadeToZeroByCapProgress` | When relief fades out | How long early relief lasts |
| `fadeExponent` | Fade shape | Relief dropoff feel |

### Spawn/ready-state presentation (affects first impression)

| Knob | What it does | Primary feel impact |
| --- | --- | --- |
| `FIRST_PIPE_MIN`, `FIRST_PIPE_MAX` | Distance to first pipe | Start pressure / onboarding feel |
| `PRE_SPAWN_COUNT` | Number of pre-spawned pipe pairs | Ready-state preview quality |
| `SPAWN_AHEAD_PADDING` | How far ahead pipes spawn | Pop-in safety |
| `DESPAWN_BEHIND_PADDING` | How far behind they recycle | Stability / perf margin |
| `FALLBACK_SPAWN_AHEAD`, `FALLBACK_DESPAWN_BEHIND` | Camera-failure fallback distances | Debug resilience |
| `MAX_POOL_SIZE` | Pool size per style | Perf/memory only (not feel) |

Notes:

- Pre-spawned pipes now simulate the selected speed ramp + challenge-floor ramp.
- Ready-state pipes now refresh after prestige tuning is applied (while in READY).

## C) Prestige Progression Tuning (`src/shared/PrestigeConfig.luau`)

These are not pipe knobs, but they define how the tuned feel is introduced across prestiges.

### Tuning unlock ranges (per prestige)

`PrestigeConfig.TUNING_BANDS[level]`

Each band controls slider limits for:

- `speedCapMultiplier` (legacy field name; now speed ramp multiplier)
- `gravity`
- `jumpPowerMultiplier`

What to tune here:

- The max ramp multiplier unlocked at each prestige
- The gravity/jump ranges unlocked at each prestige
- Step sizes (`step`) for precision

### Prestige requirements (explicit tiers)

`PrestigeConfig.LEVELS`

What to tune:

- `stats.best_score` targets
- speed graduation score targets (per prestige)
- high-gravity score targets
- `requirementText` / progress labels for clarity

Current explicit examples:

- Prestige I: score 20
- Prestige II: score 35 + speed graduation 18
- Prestige III: score 55 + speed graduation 32 + high gravity 24
- Prestige IV: score 80 + speed graduation 50 + high gravity 40

### Generated (infinite) prestige scaling

`buildGeneratedLevel(...)` currently increases targets by:

- `best score` +15 per prestige
- `speed graduation` +8 per prestige
- `high gravity` +7 per prestige

What to tune here:

- Slope of the infinite progression
- Whether speed/gravity requirements scale too fast or too slow relative to new speed system

## D) Runtime Baselines (Reference Values)

These determine what the above knobs actually mean numerically.

`src/shared/PlayerConfig.luau`

- `BASE_FORWARD_SPEED = 40`
- `GRAVITY = 250`
- `JUMP_FORCE = 60`

This matters because:

- `SPACING_MIN_FORWARD_SPEED_RATIO = 0.5` means `minXGap >= 0.5 * currentForwardSpeed`
- At `160 studs/s`, that floor alone pushes `gapXRange.min` to at least `80`

## How To Read The Current Debug Logs (So Tuning Decisions Are Correct)

Use `/debugspeed` in Studio.

Key fields:

- `speed`: actual forward speed (includes challenge-floor ramp)
- `multiplier`: runtime multiplier (hidden-capped); this is **not** the selected ramp setting
- `spacingMul`: effective spacing speed proxy used by spacing curve
- `gapXRange`: effective horizontal spacing min/max for the latest spawned pipe
- `gapYRange`: effective vertical gap bounds for the latest spawned pipe
- `age`: how old the latest spacing sample is

Important interpretation rules:

1. `gapXRange` and `gapYRange` are from the **latest spawn sample**, not a live recomputation every second.
2. `speed` is live, so if `age > 0`, exact ratios will look slightly off.
3. `multiplier` will plateau at the hidden runtime cap even if the selected ramp setting differs.

## Recommended Tuning Strategy (ASAP, High Leverage First)

## Phase 0 (Blockers / Semantics) - 15 to 30 min

Goal: prevent tuning around invalid progression assumptions.

1. Decide what prestige "speed graduation" really means after the ramp-semantics change.
2. Align progression targets/validation to that definition (ramp setting vs runtime multiplier vs forward speed).
3. Add debug log fields for future tuning clarity (recommended):
   - selected ramp setting
   - hidden internal multiplier cap
   - challenge-floor progress alpha or current floor speed

## Phase 1 (Global Speed Curve Feel) - 30 to 60 min

Goal: make `1.0x` feel clearly slower than `2.5x` without breaking long-run challenge.

Tune in this order:

1. `GameConfig.SPEED.INCREASE_RATE`
2. `GameConfig.SPEED.INTERNAL_MULTIPLIER_CAP`
3. `GameConfig.SPEED.CHALLENGE_FLOOR_RAMP.DURATION`
4. `GameConfig.SPEED.CHALLENGE_FLOOR_RAMP.TARGET_SPEED`
5. `GameConfig.SPEED.CHALLENGE_FLOOR_RAMP.EASING`

Best-practice targets:

- Low ramp (`1.0x`) should have a clear "learning" window before high pressure.
- High ramp (`2.5x`) should compress that window, not just start slightly faster.
- The challenge-floor ramp should preserve differences instead of flattening them too early.

Quick calibration method:

1. Pick milestone speeds to compare (example: `100`, `130`, `160` studs/s).
2. Record the time each ramp setting reaches them.
3. Ensure the time ratios roughly match your intended ramp multipliers.

## Phase 2 (Horizontal Readability / Pipe Spacing) - 30 to 60 min

Goal: speed increases remain readable and fun, not "too fast + too dense."

Tune in this order:

1. `SPACING_MIN_FORWARD_SPEED_RATIO` (reaction-time floor)
2. `SPACING_SPEED_POINTS` (core feel curve)
3. `SPACING_CEILING` (top-end headroom)
4. `SPACING_SAMPLE_EXPONENT` (density bias)
5. `SPACING_CAP_START_RELIEF` (only if early high-ramp feels too cramped)

Best-practice guidance:

- Start by picking a target "reaction time per pipe" feel.
- `SPACING_MIN_FORWARD_SPEED_RATIO` approximates minimum reaction-time seconds.
- Examples:
  - `0.50` -> about 0.5s minimum travel time
  - `0.65` -> about 0.65s minimum travel time
  - `0.80` -> about 0.8s minimum travel time (safer, slower-feeling)

Current practical note:

- Because `SPACING_MIN_FORWARD_SPEED_RATIO` is already `0.5`, once speed climbs high, the spacing floor can dominate your curve.
- If `gapXRange.min` is often equal to `forwardSpeed * ratio`, tune the ratio first before editing many curve points.

## Phase 3 (Vertical Variety / Fairness) - 20 to 45 min

Goal: slow runs feel expressive and varied, fast runs feel stable and learnable.

Tune in this order:

1. `GAP_Y_SPEED_VARIANCE.slow.maxDelta`
2. `GAP_Y_SPEED_VARIANCE.slow.min/max`
3. `GAP_Y_SPEED_VARIANCE.fast.maxDelta`
4. `GAP_Y_SPEED_VARIANCE.fast.min/max`
5. `GAP_Y_SPEED_VARIANCE.slowForwardSpeed` / `fastForwardSpeed`
6. `GAP_Y_SPEED_VARIANCE.easing`

Best-practice guidance:

- Keep high-speed `maxDelta` low enough to preserve pattern reading.
- Let slow-speed range be wider than fast-speed range, but avoid full-screen whiplash unless intended.
- Tune `slow.maxDelta` first; it changes perceived chaos the most.

## Phase 4 (Gap Size Difficulty Curve) - 15 to 30 min

Goal: long runs get harder without feeling "cheap."

Tune:

1. `GAP_MAX`
2. `GAP_MIN`
3. `GAP_SHRINK_RATE`

Best-practice guidance:

- Use spacing and speed as the primary difficulty levers.
- Use gap shrink as a slower, secondary pressure source.
- If players die from alignment precision instead of decision speed, gap shrink is probably too aggressive.

## Phase 5 (Prestige Band Feel + Progression Pacing) - 45 to 90 min

Goal: each prestige unlocks a new tuning toy and a new mastery expectation.

Tune in `PrestigeConfig.TUNING_BANDS`:

1. Max ramp multiplier unlocked per prestige
2. Gravity max per prestige
3. Jump power max per prestige
4. Step sizes (coarse early, finer later)

Tune in `PrestigeConfig.LEVELS` and generated scaling:

1. Best-score targets
2. Speed graduation targets
3. High-gravity targets
4. Infinite scaling slopes (`+15/+8/+7`)

Best-practice progression rules:

- One new axis at a time.
- Early prestiges should unlock experimentation quickly.
- Mid prestiges should reward consistency and controlled risk.
- Late prestiges should require mastery, not only grind volume.

## Suggested "Crank It Out ASAP" Workflow (Single Session)

## Pass 1 (Fast baseline, 20 min)

1. Reset progression (`/resetallprogress` if needed).
2. Turn on `/debugspeed`.
3. Run `1.0x` and max ramp on Prestige 0.
4. Capture time-to-speed milestones and `gapXRange`/`gapYRange`.
5. Decide if speed separation is strong enough.

## Pass 2 (Global speed only, 20 to 30 min)

1. Tune only `GameConfig.SPEED` values.
2. Re-run the same two tests.
3. Stop when the timing difference feels obvious and logs confirm it.

## Pass 3 (Pipe readability, 20 to 30 min)

1. Tune `SPACING_MIN_FORWARD_SPEED_RATIO`.
2. Tune `SPACING_SPEED_POINTS`.
3. Tune `GAP_Y_SPEED_VARIANCE` fast profile.
4. Verify no "too fast + too close" segments.

## Pass 4 (Prestige pacing, 30 to 60 min)

1. Tune `TUNING_BANDS` ramp ranges to shape available risk/reward by prestige.
2. Tune explicit prestige score/mastery targets.
3. Check generated prestige scaling for continuity after Prestige IV.

## Tuning Checklist Per Prestige Tier

Use this checklist for each prestige level:

1. Does the newly unlocked ramp range create a noticeable new playstyle?
2. Does the default/recommended tuning feel sane for that prestige?
3. Is the current prestige speed mastery requirement clearly trainable in that tier?
4. Are deaths mostly from readable mistakes (timing/positioning), not spawn unfairness?
5. Does high-speed spacing remain readable (`gapXRange` and actual `spacing`)?
6. Does vertical variance tighten enough at speed (`gapYRange`, `maxDelta`)?
7. Is progression time acceptable for a skilled replaying tester?

## Immediate Tuning Recommendations (Based on Current Logs)

1. The ramp scaling appears to be working, but the debug log is misleading because it shows the hidden-capped runtime multiplier.
2. Add debug fields for `rampSetting` and `hiddenCap` before heavy balancing.
3. Revisit `INCREASE_RATE` and `CHALLENGE_FLOOR_RAMP.DURATION` together:
   - If `1.0x` still feels too fast, lower `INCREASE_RATE` and/or increase `DURATION`.
4. Fix prestige speed-graduation semantics before tuning high prestiges, otherwise later requirements may not reflect the new speed system.

## Change Log Template (Use During Tuning)

Copy/paste this while iterating:

```md
### Tuning Pass: YYYY-MM-DD HH:MM
- Goal:
- Changed:
- Hypothesis:
- 1.0x result:
- Max-ramp result:
- Debug log notes (speed / gapXRange / gapYRange / spacing):
- Decision (keep/revert/follow-up):
```

