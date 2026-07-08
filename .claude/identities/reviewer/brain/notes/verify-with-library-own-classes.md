---
tags: [review, verification]
paths: ["plugins/spec-workflow/templates/**", "plugins/spec-workflow/scripts/**"]
strength: 1
source: "#72 review retro"
graduated: false
created: 2026-07-08
---

When a diff claims two representations are equivalent ("visually identical", "same edge set"), compute the equivalence with the library's own runtime — a throwaway script importing the actual vendored dependency, comparing counts/shapes — instead of eyeballing. Converts "it should look the same" into a falsifiable number.

Related: [[verify-guard-regex-on-real-artifact]] [[recompute-hashes-never-eyeball]]
