---
tags: [review, python, verification]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#70 review retro"
graduated: false
created: 2026-07-08
---

importlib-load the changed helper straight out of the script and hand it adversarial inputs BEYOND the shipped test file (missing fields, alternate wordings, oversized lines, case variants) — that's what surfaced the "secondary rate limit" wording gap the suite could never show.

Related: [[verify-with-library-own-classes]] [[json-escaped-check-weakness]]
