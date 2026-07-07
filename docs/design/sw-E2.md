# Design — sw/E2: Self-improvement completion
Grounded in: SPEC §8 (§8.1–§8.3), §2 G3; extended by issue #29 (feedback loop, becomes §8.4 via spec delta)

## Components
`gate.sh` failure capture (SW-020) — red-gate tail → lessons feed JSONL, input to retros.
`build-next` retro step (SW-021) — mandatory at PR close; skip requires stated reason.
`brain.py graduate-check` (SW-022) — strength-threshold graduation proposals.
`/feedback` skill (#29) — per-iteration structured process feedback: emit → filter → triage → route. Owns `skills/feedback/` + any stdlib helper; consumes `similar.py` for dedupe; writes the local feed.
Triage protocol (build-next step 7 extension) — routes each feedback item to backlog / brain-note / graduation / upstream / ignore; closes the loop by writing routing back to the feed.

## Data models
Lessons feed record (§8.1): `{ts, exit, tail}` JSONL, gitignored.
Feedback record (#29): yaml documents, `schemaVersion: 1, kind: loop-feedback`, `iteration{task, outcome, reviewRounds}`, `source{role, model}`, `items[]{category, area, component, severity, summary, detail, evidence, generalized, proposal{target, change}, routing{action, ref}}`. Invariant: `generalized` is the ONLY text permitted to leave the local feed; `detail`/`evidence`/`iteration.task` never do.
Config: `methodology.feedback` — `true` shorthand ≡ `{enabled: true, feed: .claude/feedback/feed.yaml, roles: [orchestrator], autoTriage: false}`.

## Interfaces / contracts
Feedback ≠ retro: feedback is per-ITERATION process signal (what slowed the loop, what a skill should do differently); retro is per-PR lesson MINTING into brains. The feed is an INPUT to the retro; triage happens at retro time so the two never duplicate — a feedback item routed `brain-note` is minted by the existing retro protocol, not by a second minting path.
Routing actions: `backlog` (plugin-actionable → issue on THIS repo's board, generalized text only, `from-feedback` marker) · `brain-note` (lesson) · `graduate` (recurring past threshold, §8.3 flow) · `upstream` (outside plugin control — surfaced to the human once, deduped after) · `ignore` (with reason). Dedupe before routing via `similar.py` over existing feed routes + board issues.
Feed paths gitignored (setup-project owns the gitignore block, same as other loop state).

## Key sequences
1. Iteration end (feedback enabled) → orchestrator emits its record (+ interviews configured roles) → records appended locally, every item either `generalized` or marked local-only.
2. Retro (step 7) → unrouted feed items triaged: similar.py dedupe → route → write `routing` back → triage counts included in the iteration report. Unrouted records block skipping the next triage.
3. Graduation: repeated `brain-note`/`backlog` routes on the same generalized theme raise note strength → `graduate-check` proposes ROLE.md rule / invariant / test destination (human-visible action, §8.3).

## Decisions
Feed format yaml-documents (not JSONL) — records are small, human-auditable, and PyYAML is already the sole permitted dependency; stdlib-only helper parses/appends.
Generalization enforced at EMIT time (the skill's contract), re-checked at triage — two passes because the emitting agent has the context to restate agnostically, the triaging orchestrator has the distance to catch leaks.
`autoTriage: false` default — routing creates board items; humans opted into that per-repo, mirroring autoMerge's explicit-consent pattern.

## Out of scope for this epic
The auto-merge permission/classifier fix (#25 — protocol change, not learning machinery).
Neural-view surfacing of feedback/brain state (#28/#30 — visualization).
