---
tags: [debugging, shell]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#90 retro"
graduated: false
created: 2026-07-08
---

`2>/dev/null` on a function/command call makes distinct failure classes indistinguishable at the call site — the #90 lookup bug wasn't in detection logic but one layer upstream, in a redirect that looked like defensive cleanup and threw away the only evidence separating "no such issue" from "rate-limited". Grep for `2>/dev/null` FIRST whenever a report says "silently did the wrong thing"; capture stderr and classify, never discard.

Related: [[circular-fixture-detector]] [[trace-state-mutation-not-named-trigger]]
