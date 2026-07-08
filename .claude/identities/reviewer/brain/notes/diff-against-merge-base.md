---
tags: [review, git, concurrency]
paths: ["**"]
strength: 1
source: "#75 review retro"
graduated: false
created: 2026-07-08
---

When main has diverged past a branch's base, `origin/main..HEAD` shows phantom deletions — measure the branch's true diff from `git merge-base HEAD origin/main`. For scratch-worktree checks, pass the explicit target SHA by value, never the bare word HEAD — HEAD resolves from the current cwd's checkout and silently grabs the wrong ref when cwd drifts in a multi-lane session (a false-clean merge check nearly resulted).

Related: [[explicit-cd-every-command]] [[red-commit-worktree-verify]]
