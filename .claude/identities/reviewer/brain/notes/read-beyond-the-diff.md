---
tags: [review, scope]
paths: ["**"]
strength: 1
source: "#67 review retro"
graduated: false
created: 2026-07-08
---

Classifying a finding as "new in this diff" vs "pre-existing property the diff inherits" requires reading code paths OUTSIDE the diff (where the state is written, who else consumes it). The diff alone either lets the issue slide as in-scope or over-flags it as a regression — expand context before assigning blame.

Related: [[outcome-language-marks-unverified-seams]]
