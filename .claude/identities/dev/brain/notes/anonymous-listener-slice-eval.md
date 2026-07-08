---
tags: [tests, templates, frontend]
paths: ["plugins/spec-workflow/tests/**", "plugins/spec-workflow/templates/**"]
strength: 1
source: "PR#83 (#71) retro"
graduated: false
created: 2026-07-08
---

To test anonymous addEventListener callbacks (no named function to regex-extract): slice the source between two grep-verified-UNIQUE literal substrings, eval the block against a stub environment (fake canvas/THREE, handlers captured by event type), and drive real synthetic events end-to-end. More faithful than evaling individual arrow functions out of context.

Related: [[template-extract-anchor-check]] [[trace-state-mutation-not-named-trigger]]
