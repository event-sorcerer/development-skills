---
tags: [process, feedback]
paths: ["**"]
strength: 1
source: "user directive 2026-07-08"
graduated: false
created: 2026-07-08
---

Session end is an iteration boundary: when feedback is enabled, closing a session (user /clear, finish, goal cleared) REQUIRES (1) a kind: session-feedback document into .claude/feedbacks/feed.yaml — session-level lessons per-iteration entries missed — triaged, committed, pushed; then (2) the close-out report in the default format in .claude/identities/orchestrator/ROLE.md: merged-this-session, in-flight with lane+branch+SHAs+uncommitted-state+next-action, board state, warnings, closing line. The close-out is the only handoff a cleared successor gets.

Related: [[orchestrator-cd-prefix-own-commands]]
