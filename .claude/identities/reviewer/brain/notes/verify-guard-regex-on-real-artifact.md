---
tags: [testing, code-review, tsv]
paths: ["plugins/spec-workflow/tests/**"]
strength: 3
source: "MEM-031 code-quality review round 1, 2026-07-18"
graduated: false
created: 2026-07-07
---

A test guard built on a regex/extraction can silently no-op against the real artifact it claims to cover (minified syntax, wrong anchors, empty match). Before crediting the guard as coverage, run its exact extraction against the actual file and confirm the matched content's length/shape — an empty or truncated match means the test passes vacuously.

Recurrence (MEM-031 review): a TSV-row assertion (`check_absent ... $'alpha\t\t' "$tbl"`) targeted the wrong COLUMN — it could only ever match an empty content_hash, never an empty vector, so it passed even against completely broken vector storage. Same failure family as a bad regex extraction: the test LOOKS like it covers the field it names, but never actually reads that field. Fix pattern: isolate the exact field/column being asserted (cut -fN, or a structured parse) rather than a substring/pattern match that could accidentally target an adjacent field.

Related: [[recompute-hashes-never-eyeball]] [[red-commit-worktree-verify]]
