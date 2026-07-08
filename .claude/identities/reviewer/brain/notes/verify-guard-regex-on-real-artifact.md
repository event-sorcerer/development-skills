---
tags: [review, tests, regex]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#61 (#60) retro"
graduated: false
created: 2026-07-07
---

A test guard built on a regex can silently no-op against the real artifact it claims to cover (minified syntax variants, quote styles). Before crediting the guard as coverage, run its exact regex against the actual file and confirm match count > 0.

Related: [[recompute-hashes-never-eyeball]] [[diff-invariant-artifact-on-refactor]]
