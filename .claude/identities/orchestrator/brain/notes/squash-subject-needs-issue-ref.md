---
tags: [board, git, audit]
paths: ["**"]
strength: 1
source: "MEM-031 session-close audit, 2026-07-18"
graduated: false
created: 2026-07-18
---

board.sh audit's commit-scan only checks the commit SUBJECT line for a #N reference, not the body — a squash-merge subject like "feat(mem031): embedding index (...)" with "Closes #139" only in the body still counts as a discrepancy. Always put (#N) directly in the squash-merge commit's SUBJECT line (as already done correctly for the sibling ui-hub fix commit in the same session), not just the body's "Closes #N".
