---
name: gate
description: Run the project quality gate (commands.gate in .claude/project.json). Mandatory green before a task moves to In review and before merge. Use it to decide whether work may advance.
---

# Quality gate

The single command that decides whether work may advance — from `.claude/project.json`:

```bash
jq -r .commands.gate .claude/project.json    # then run that command, e.g.: pnpm gate
```

## Rules
- **Green is mandatory** before moving any task to *In review*. A red gate never advances; fix or report the blocker.
- **TDD:** the failing test must be committed *before* the implementation.
- If `methodology.isolationSuite` is set, changes touching protected resources must add cases there — treat missing coverage as a gate failure.
- Fix lint properly; never disable rules to pass (exceptions only where the repo's CLAUDE.md documents them).

## Fast inner loop
While iterating, use `commands.gateFast` from config if set (e.g. per-package watch tests). Always run the full gate before *In review*.
