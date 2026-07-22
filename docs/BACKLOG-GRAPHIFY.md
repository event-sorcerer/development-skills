# BACKLOG-GRAPHIFY — tasks for SPEC-GRAPHIFY.md

Status: APPROVED 2026-07-20 — seeded to the board. Task prefix **GL**. Epic order is impact-first (spec §12). §16 defaults accepted: C1–C3 approved, C4 deferred (GL-043 not seeded). Points follow the seed-board complexity rubric; every task cites its spec §s.

## E0 — Learning-loop foundations (GL-001–009) — spec §7

Blocked by: nothing.

- **GL-001** (P0, 3pt) `outcomes.jsonl` data layer + `brain.sh outcome` command. §7 R7.1, R7.3. AC: `brain.sh outcome dev some-slug useful --task Zugruul/development-skills#99` appends a schema-valid line atomically; `corrected` without `--note` exits non-zero with usage; unknown slug/role exits non-zero; absence of the file is never an error on read paths.
- **GL-002** (P0, 2pt) `RecallOutcome` event emission. §7 R7.2. AC: recording an outcome appends a `RecallOutcome` event to `.claude/brain-events.jsonl`; feed-write failure warns and does not fail the command; event schema is append-extended only (§13).
- **GL-003** (P0, 5pt) Outcome multiplier in recall ranking + contested markers. §7 R7.4, R7.5, R7.7. AC: golden-fixture regression proves a note with zero outcomes ranks byte-identically to today; net-`useful` note ranks above its no-outcome twin; contested note renders `⚠ contested`; malformed `outcomes.jsonl` warns once and disables weighting.
- **GL-004** (P1, 2pt) Outcome tallies in `brain.sh status` + retro prune signal. §7 R7.6. AC: status shows per-note tally; a repeatedly-`dead_end`, never-`useful` note appears in `prune` candidate output.
- **GL-005** (P0, 2pt) Shrink guard on brain-mutating commands. §13 invariant (graphify lesson §5.2.1). AC: a `prune --apply` that would remove >30% (configurable) of links requires an explicit `--force`; test simulates the destructive case.
- **GL-006** (P1, 1pt) Orchestrator protocol update: record outcomes at task close. §7 preamble. AC: `build-next`/`implement-task` reference docs instruct outcome recording for briefed recalls; docs updated in the same PR as behavior (§13).

## E1 — Ranking signals: recency, staleness, confidence (GL-010–019) — spec §8

Blocked by: E0 (GL-003 ranking harness reused).

- **GL-010** (P0, 3pt) Recency decay on the retro clock. §8 R8.1. AC: note untouched for K retros decays by configured factor; defaults keep top-1 stable on frozen corpora (regression fixture); config keys documented in the project-config schema.
- **GL-011** (P0, 3pt) Staleness flags in recall output. §8 R8.2, R8.5. AC: note whose glob matches a file committed after `created` renders `⟳ stale — re-verify`; per-(note, HEAD) cache proves one git subprocess per recall; no-git environment omits flags silently.
- **GL-012** (P1, 2pt) Confidence frontmatter + mint flag. §8 R8.3. AC: `mint --confidence direct` persists; missing field reads as `inferred`; retrospective skill doc sets `direct` for incident-sourced notes.
- **GL-013** (P1, 2pt) Self-describing recall headers. §8 R8.4. AC: full-body tier renders `[direct, 3× useful]`-style header combining confidence + tally; tiered rendering budget math still honored (existing tests stay green).

## E2 — Graph interrogation (GL-020–029) — spec §9

Blocked by: E1 (headers/staleness reused in explain cards).

- **GL-020** (P0, 3pt) `brain.sh explain <role> <slug>`. §9 R9.1. AC: card shows body, confidence, tally, staleness, community (placeholder until GL-030), links with weight/last-fired, top co-activated notes; unknown slug exits non-zero.
- **GL-021** (P1, 2pt) `brain.sh path <role> <a> <b>`. §9 R9.2. AC: BFS shortest path over `links.json`; disconnected pair prints "no path" and exits 0; deterministic tie-break.
- **GL-022** (P1, 2pt) Ground ask-brain/ask-identity answers in `explain`. §9 R9.3. AC: ask skills cite notes via explain-card excerpts instead of ad-hoc pastes; brain privacy invariant untouched.

## E3 — Neural-view structure (GL-030–039) — spec §10

Blocked by: E0 (contested state), E2 (explain feeds hover).

- **GL-030** (P1, 5pt) Stdlib label-propagation communities in `/graph`. §10 R10.1. AC: deterministic assignment (seeded ordering test); single-community degradation on tiny graphs; payload adds `community` without breaking existing viewer.
- **GL-031** (P1, 3pt) Community rendering + labels in the viewer. §10 R10.2. AC: cluster coloring, top-tags label in hover + sidebar; no CDN/build-step additions (vendored three.js unchanged).
- **GL-032** (P2, 2pt) Contested-note visual state from `RecallOutcome` events. §10 R10.3. AC: contested notes render distinct live when events arrive; absence of outcome events renders exactly today's view.
- **GL-033** (P1, 3pt) `brain.sh report` digest. §10 R10.4. AC: stdout-only report with god/contested/stale/orphan notes + community summary; never writes into the repo; covered by a fixture-corpus test.

## E4 — Consolidation + retro friction (GL-040–049) — spec §6, §11 — **approval-gated**

Approval granted 2026-07-20: C1–C3 approved; C4 deferred, so **GL-043 is not seeded** (revisit after C1–C3 land).

- **GL-040** (P1, 2pt) Merge `pr-review-model` into `auto-merge` (C1). §6. AC: `auto-merge model ...` covers the old surface; SKILL.md removed; `merge-mode.sh` and its tests untouched; CDX skill-matrix docs updated same PR.
- **GL-041** (P1, 2pt) Merge `find-task` into `create-inbound` (C2). §6. AC: `--search-only` mode reproduces find-task output; `similar.py` untouched; docs updated.
- **GL-042** (P1, 3pt) Merge `ask-brain`+`ask-identity` into `ask` (C3). §6. AC: both invocation forms work; neural-view "Talk" deep links updated in the same PR; ROLE.md/reference cross-links updated.
- **GL-043** (P2, 3pt) Optional: consolidate `concurrency`/`ui-mode`/`checkpoint` into `mode` (C4). §6. AC: only if approved; all three surfaces reachable; backing scripts untouched.
- **GL-044** (P1, 2pt) If-stale cheap retro opening. §11 R11.1–R11.2. AC: retro no-ops in one command when nothing is pending and no outcomes since last retro-mark; existing retro path unchanged otherwise.

## E5 — Knowledge-graph seeding (GL-050–059) — spec § via delta (added 2026-07-22, human-requested; capture: #292)

- **GL-050** (P0, 5pt) `/knowledge-base-seed` skill — explore the project (specs, backlogs, design docs, READMEs, script/source layout, git history, board epics) and seed a comprehensive knowledge graph as zettel notes into a new `knowledge` identity brain, using the existing brain.py machinery only. Provenance frontmatter (`source: seed` + source path/commit); idempotent re-seed (evolve/supersede, never duplicate, never delete); shrink-guarded; orchestrator-mediated like every brain; rendered by neural-view without viewer changes. Spec: the SAME PR adds the requirement section via `docs/spec-deltas/GL-050.md` (never a direct spec edit). AC detail on the issue.

## Coverage check

Every requirement §7 R7.1–R7.7 → GL-001..006; §8 R8.1–R8.5 → GL-010..013; §9 R9.1–R9.3 → GL-020..022; §10 R10.1–R10.4 → GL-030..033; §11 → GL-044; §6 → GL-040..043; §13 shrink guard → GL-005. Headroom left in every range for discovered work.
