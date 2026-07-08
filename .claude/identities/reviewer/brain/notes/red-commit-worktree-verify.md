---
tags: [review, tdd, git]
paths: ["plugins/spec-workflow/**"]
strength: 2
source: "PR#83 (#71) retro — recurrence"
graduated: false
created: 2026-07-07
---

Verify a red-first TDD claim by running the full suite at the red commit inside an isolated `git worktree add` — never `git checkout <sha> -- <path>` into the current tree. Diff the failure set against HEAD's green run: exactly-the-new-checks failing rules out both a vacuous test and a hidden pre-existing regression.

Related: [[recompute-hashes-never-eyeball]]
