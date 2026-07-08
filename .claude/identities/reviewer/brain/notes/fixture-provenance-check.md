---
tags: [review, fixtures, detection]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#77 review retro (+#90)"
graduated: false
created: 2026-07-08
---

Checklist for any error-text classifier: (1) was the exact matched string pasted from a REAL captured failure, with provenance — or authored in the same commit by the same hand as the regex? Same-hand = treat the match as UNVERIFIED. (2) Does the classifier have an independent way to confirm its diagnosis (follow-up probe to a stable endpoint) rather than one string match? The #77→#90 gap passed a rigorous review because every check ran against the fixture's own invented text.

Related: [[drive-real-helper-adversarially]] [[json-escaped-check-weakness]]
