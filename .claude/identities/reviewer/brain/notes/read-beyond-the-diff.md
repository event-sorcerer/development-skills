---
tags: [review, scope]
paths: ["**"]
strength: 2
source: "#89 review retro — recurrence (semantic rightness)"
graduated: false
created: 2026-07-08
---

The diff shows WHAT changed, never whether it's RIGHT: classifying pre-existing vs new requires reading code outside the diff; judging a text transformation (e.g. ref qualification) requires checking the record's own context (whose ref was it?). Establishing a negative ("no foreign refs were mangled") requires a full-file scan, not a sample.

Related: [[outcome-language-marks-unverified-seams]]
