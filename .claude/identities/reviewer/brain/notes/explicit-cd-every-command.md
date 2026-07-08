---
tags: [review, concurrency, worktrees]
paths: ["**"]
strength: 1
source: "#72 review retro"
graduated: false
created: 2026-07-08
---

In a multi-lane session the shell cwd can be repointed by concurrent lanes BETWEEN tool calls — a review's final "all green" gate run silently executed in a sibling worktree and was nearly reported as verification of the wrong branch. When an instruction hands you a worktree path, the explicit `cd <path> && ` prefix is load-bearing on EVERY command; cross-check `git diff --name-only` output against what you've been reading before trusting any run.

Related: [[red-commit-worktree-verify]]
