---
tags: [python, robustness, preflight, errors]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #306 review r2"
graduated: false
created: 2026-07-22
---

Advisory-only scripts (preflight, status probes) must catch the OSError CLASS around every filesystem read and every state write — ConfigError-style domain exceptions do not cover PermissionError/read-only mounts, and an uncaught traceback in a skill-load hook is worse than the failure it hides. Pattern: reads → enumerated FAIL line; state/cache writes → degrade silently, still report the verdict.

Related: [[tracked-config-atomic-writes]] [[lock-key-canonicalize]]
