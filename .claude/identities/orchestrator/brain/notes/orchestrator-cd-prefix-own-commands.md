---
tags: [orchestration, worktrees, git]
paths: ["**"]
strength: 1
source: "third own cwd slip (#79, #92, #66 retro commits landed in live lanes)"
graduated: false
created: 2026-07-08
---

The orchestrator's OWN shell drifts exactly like the agents' — three retro/config commits landed on live lanes' branches mid-review this session. Every brain.sh/git/telemetry command the orchestrator runs must start with `cd <main checkout absolute path> && `, ESPECIALLY the mint-then-commit sequences that follow lane verification calls. Repair recipe when it happens: cherry-pick the stray commit to main from the MAIN checkout, then reset the lane to its true HEAD from INSIDE the lane (never a compound that could reset the wrong tree), then notify the affected reviewer.

Related: [[board-comment-bodies-via-file]] [[pre-diagnose-before-brief]]
