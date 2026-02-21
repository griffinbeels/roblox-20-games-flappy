# Prestige System Implementation Plan

Goal: implement System A so players can fine-tune speed and gravity, with prestige unlocking wider tuning limits over time.

Execution rule: complete tasks in order. After each task, run the listed Roblox Studio check before moving to the next task.

Design principles for long-term iteration:
- Keep gameplay rules in config, not hardcoded in services/UI.
- Keep condition evaluation reusable across systems.
- Keep server authoritative for progression and tuning validation.
- Keep client modules thin: cache state, render UI, forward intents.
- Keep module boundaries explicit so tuning logic can be swapped later.

## Ordered Task List

### [ ] T1 (P0) Create shared condition engine module
Prerequisites: none
Deliverables:
- Add `src/shared/ConditionEvaluator.luau`.
- Move generic condition logic out of `src/server/MissionService.luau` into the shared module without behavior changes.
- Refactor `MissionService` to consume `ConditionEvaluator`.
Studio check:
- Launch game and complete one easy mission.
- Confirm mission progress/completion still works exactly as before.

### [ ] T2 (P0) Add runtime tuning abstraction layer
Prerequisites: T1
Deliverables:
- Add `src/shared/RuntimeTuning.luau` with stable API for speed/gravity values and clamp helpers.
- Include base defaults sourced from existing config values so gameplay is unchanged initially.
- Add comments describing which modules should read from this layer.
Studio check:
- Launch game and run 2 rounds.
- Confirm movement, speed progression, and pipe pacing feel unchanged.

### [ ] T3 (P0) Define prestige config schema
Prerequisites: T2
Deliverables:
- Add `src/shared/PrestigeConfig.luau`.
- Define `REMOTES`, datastore constants, UI constants, ready-button config, tuning bands, and level definitions.
- Define per-level unlock conditions using the condition DSL.
- Document config schema at top of file so future edits are low risk.
Studio check:
- Launch game and confirm no runtime errors from requiring `PrestigeConfig`.

### [ ] T4 (P0) Implement PrestigeService state and persistence skeleton
Prerequisites: T3
Deliverables:
- Add `src/server/PrestigeService.luau`.
- Persist profile with versioned shape: progression, tuning selection, tracked stats.
- Create `GetPrestigeState` and `PrestigeStateUpdated` remotes.
- Wire service init in `src/server/init.server.luau`.
Studio check:
- Join, leave, and rejoin.
- Confirm prestige state loads without errors and remains stable across reconnect.

### [ ] T5 (P0) Implement client PrestigeManager
Prerequisites: T4
Deliverables:
- Add `src/client/PrestigeManager.luau`.
- Mirror existing manager patterns: init, request state, cached state, listeners.
- Handle server push updates and local callback fan-out.
Studio check:
- Launch game and confirm state request/updates arrive on client (no warnings/errors).

### [ ] T6 (P0) Track prestige-relevant run stats
Prerequisites: T5
Deliverables:
- Add event/report pipeline in `PrestigeService` for stats used by prestige conditions.
- Track at minimum: best score, best score at/above speed threshold, best score at/above gravity threshold, and total runs.
- Reuse `ConditionEvaluator` for evaluating unlock conditions against profile stats.
Studio check:
- Play several runs with different outcomes.
- Confirm tracked stats change as expected (using output/logging or temporary debug UI).

### [ ] T7 (P0) Add prestige attempt flow (server-authoritative)
Prerequisites: T6
Deliverables:
- Add `AttemptPrestige` remote path in `PrestigeService`.
- Evaluate next level unlock condition server-side only.
- On success, increment prestige and update allowed tuning limits.
- Return structured result payloads for success/failure reasons.
Studio check:
- With test-friendly thresholds, trigger a success and a failure case.
- Confirm only valid attempts level up.

### [ ] T8 (P0) Add tuning set/apply flow (server-authoritative)
Prerequisites: T7
Deliverables:
- Add `SetPrestigeTuning` remote path.
- Validate and clamp requested tuning against current prestige limits.
- Persist selected tuning and include it in state payloads.
- Keep selected tuning independent from unlock conditions for easy future rebalance.
Studio check:
- Set extreme values inside range and outside range.
- Confirm inside values persist and outside values are rejected/clamped.

### [ ] T9 (P0) Integrate runtime tuning into gameplay modules
Prerequisites: T8
Deliverables:
- Update `src/client/PlayerController.luau` to read active gravity from runtime tuning.
- Update `src/client/SpeedManager.luau` to read active speed cap from runtime tuning.
- Update `src/client/PipeManager.luau` pre-spawn estimation to use active speed cap source.
- Keep default behavior identical when player has no prestige tuning set.
Studio check:
- Run at least 3 rounds with different tuning values.
- Confirm gameplay changes are felt and no instability/regressions occur.

### [ ] T10 (P1) Build Prestige modal UI
Prerequisites: T9
Deliverables:
- Add `src/client/PrestigeUI.luau` using modal lifecycle pattern (`init/show/hide/destroy`).
- Include controls for speed cap and gravity, plus next-prestige requirement display.
- Include explicit apply/save action and attempt-prestige action.
- Show validation feedback from server responses.
Studio check:
- Open/close modal repeatedly.
- Change values, save, and verify values are preserved after respawn/rejoin.

### [ ] T11 (P1) Add Ready-screen Prestige button and controller wiring
Prerequisites: T10
Deliverables:
- Extend `src/client/ReadyUI.luau` with prestige button registration and hover helpers.
- Use `PrestigeConfig.READY_BUTTON` for button visuals/placement.
- Wire `GameController` interactions and modal exclusivity with Shop/Missions.
- Ensure input guards block jumps when hovering/opening prestige UI.
Studio check:
- In READY state, confirm button appears beside Shop/Missions.
- Confirm only one modal can be open at a time and controls still feel correct.

### [ ] T12 (P1) UX safety and fun polish
Prerequisites: T11
Deliverables:
- Apply tuning only outside active runs (READY/menu), not mid-run.
- Add clear "current vs saved" indicators.
- Add one-click reset to default and one-click recommended preset.
- Add clear prestige-ready indicator and success celebration hook.
Studio check:
- Try edge cases: change tuning during/around start, cancel modal, retry.
- Confirm UX is understandable and hard to misuse.

### [ ] T13 (P1) Analytics instrumentation for balancing loop
Prerequisites: T12
Deliverables:
- Add analytics events for tuning changes, prestige attempts, prestige success, and run outcomes with active tuning.
- Keep event constants centralized in `src/shared/AnalyticsConfig.luau`.
Studio check:
- Trigger each key action once and verify events are emitted (logs/dev endpoint).

### [ ] T14 (P1) Config-first balancing pass
Prerequisites: T13
Deliverables:
- Tune initial prestige bands and requirement curves only via `PrestigeConfig`.
- Ensure early prestiges are reachable and later tiers demand mastery.
- Add short rationale comments beside each tier for future rebalance context.
Studio check:
- Full playtest loop from fresh profile through at least first 2 prestiges.
- Confirm progression feels motivating and not grindy.

### [ ] T15 (P0) Regression hardening and documentation
Prerequisites: T14
Deliverables:
- Add/update docs: module responsibilities, data shapes, remote contracts, and extension points.
- Run regression sweep across missions, shop, currency, leaderboard, and respawn flows.
- Remove temporary debug hooks used during implementation.
Studio check:
- Perform full smoke test of old systems and new prestige system in same session.
- Confirm no pre-existing feature regressed.

## Post-Implementation Iteration Checklist

Use this loop for future updates without risky refactors:
- Edit requirements in `PrestigeConfig` only.
- Edit tuning bands in `PrestigeConfig` only.
- Avoid direct gameplay constant reads where runtime tuning should apply.
- Keep server payloads backward-compatible with profile versioning.
- Add new unlock condition types only in `ConditionEvaluator`, then reuse everywhere.
