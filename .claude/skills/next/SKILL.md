---
name: next
description: Picks the highest-priority unblocked task from TASKS.md and carries it through to completion.
---

When invoked:

1) Read TASKS.md.
2) Choose exactly one task:
   - Highest priority section first (P0 > P1 > P2)
   - Unchecked
   - Has a clear DoD
   - Not blocked by another task (if dependencies are mentioned, skip)
3) Output:
   - Selected task ID + title
   - DoD (verbatim or cleanly restated)
   - 3–6 step implementation plan
4) Implement the task.
5) Update TASKS.md:
   - Check off the completed task
   - Add follow-ups (as new tasks) if discovered
6) Stop.
