# Design — cdx/E0: Codex packaging & plugin-root resolution
Grounded in: SPEC-CODEX-COMPAT.md §5 (architecture), §6.1–§6.7, §2 G1–G3

## Components
`scripts/lib/plugin-root.sh` — bash resolver: sourced by every shell script in `plugins/spec-workflow/scripts/` that currently interpolates `${CLAUDE_PLUGIN_ROOT}`. Exposes a single function, `spec_workflow_plugin_root`, that prints the resolved absolute plugin root on stdout. (CDX-001)
`scripts/lib/plugin_root.py` — Python equivalent: exposes `resolve_plugin_root() -> pathlib.Path`, same precedence chain, for the plugin's stdlib-Python scripts. (CDX-001)
`.codex-plugin/plugin.json` (×2, one per plugin) — Codex packaging manifests. (CDX-003, not this task's code but shares this epic's design)
`.agents/plugins/marketplace.json` — Codex marketplace manifest. (CDX-004, same note)
Migration of existing scripts/skills off direct `CLAUDE_PLUGIN_ROOT` interpolation is CDX-002, a separate task consuming this one's resolver — out of scope for CDX-001 itself.

## Data models
No persistent data — the resolver is a pure function of (environment variables, the resolver script's own on-disk location, filesystem sentinel checks). No caching across invocations (each script re-resolves; the cost is a handful of `dirname`/`stat` calls per §13 non-functional).

## Interfaces / contracts
Bash: `plugin-root.sh` defines `spec_workflow_plugin_root()`; a script sources it (`. "$(dirname "${BASH_SOURCE[0]}")/lib/plugin-root.sh"`) then calls `root="$(spec_workflow_plugin_root)"`. On success: prints the absolute plugin root to stdout, exits 0. On failure (invalid override — §6.4): prints an actionable error to stderr, exits non-zero — callers must not treat empty stdout as "no root, fall back to cwd."
Python: `plugin_root.py` defines `resolve_plugin_root() -> pathlib.Path`, raising `PluginRootError` (a `RuntimeError` subclass) with an actionable message on the same failure condition; callers must not catch-and-ignore it.
Precedence (both implementations, identical order — SPEC §5/§6.3/§6.4):
1. `SPEC_WORKFLOW_PLUGIN_ROOT` env var, if set — validated against the sentinel (below); invalid → error, never silently skipped.
2. `CLAUDE_PLUGIN_ROOT` env var, if set — same validation, same error-on-invalid behavior (this is the Claude fast path; it stays byte-for-byte backward compatible in behavior, just now validated).
3. Script-relative discovery: starting from the resolver's own physical file location (`BASH_SOURCE[0]` / `__file__`, resolved through symlinks — `pwd -P` / `Path.resolve()`), walk up ancestor directories until one contains `.claude-plugin/plugin.json` or `.codex-plugin/plugin.json` (the sentinel). That ancestor is the plugin root.
4. No sentinel found anywhere above the resolver's location → actionable error (never silently falls back to CWD — SPEC §12).

## Key sequences
1. A script needing its plugin root sources/imports the resolver and calls it once near the top of its `main`.
2. Resolver checks env vars in order; each set-but-invalid override fails fast (§6.4) rather than falling through — this is the one behavior a naive port could get backwards, so it is red-test-first (an override pointing at `/tmp/not-a-plugin` must error, not silently walk up from the script location instead).
3. With no (valid) override, the resolver locates itself on disk and walks up to the sentinel — this is what makes CDX-001 work identically whether the script sits in the source checkout, a marketplace-cached copy, or an installed plugin tree, and irrespective of CWD (SPEC §12, §14 test list a–d).

## Decisions
Sentinel-based discovery over fixed-depth discovery — WHY: a fixed `../..` assumption from `scripts/lib/` breaks the moment any script is invoked from a different nesting depth (e.g. a future `scripts/lib/vendor/` addition) or from a repo-relative symlink; sentinel discovery is depth-independent and self-documenting (finding review round 1 flagged this ambiguity).
Fail loud on an invalid explicit override rather than falling through to script-relative discovery — WHY: a stale/misconfigured `CLAUDE_PLUGIN_ROOT` left over from a different install would otherwise resolve to the *wrong* plugin silently; SPEC §6.4/§12 make this a named invariant, not just a preference.
One resolver per language, not a bash-calls-python (or vice versa) shim — WHY: keeps the hot path dependency-free per-language (no cross-language subprocess spawn on every script invocation) and matches `specs[].invariants`' bash-3.2/stdlib-only constraints independently for each.
Plugin root cached in-process only via the caller's own local variable, not written to disk/env by the resolver — WHY: keeps the resolver a pure function with zero side effects, simplest to test hermetically (SPEC §14).

## Out of scope for this epic
Actually migrating the 24 existing `CLAUDE_PLUGIN_ROOT`-referencing scripts/skills to call this resolver — that is CDX-002, which depends on this task's shipped resolver but is a separate, independently gated task.
`.codex-plugin/plugin.json` content and the Codex marketplace manifest (CDX-003/CDX-004) — packaging metadata, not code; no shared component with the resolver beyond both living under the "E0" umbrella.
Fixing the 5 angle-bracket skill descriptions (CDX-005) — unrelated deliverable sharing this epic's number range only.

## CDX-006 — `AGENTS.md` + `CLAUDE.md` pointer (§6.5, §15 OQ-2)

**§6.5 exact text**: "THE SYSTEM SHALL provide a canonical `AGENTS.md` at the repository root consumed by Codex, with root `CLAUDE.md` reduced to a one-line pointer to it (§15 OQ-2 governs whether either is hand-maintained or generated)."

**OQ-2, already resolved** (§15): "hand-maintained `AGENTS.md` canonical + one-line `CLAUDE.md` pointer (no CI generation step this release)." No generation script needed — this is a pure content-authoring task.

**Current state**: neither `AGENTS.md` nor `CLAUDE.md` exists at the repo root yet (confirmed: `ls` returns nothing for both). This is pure creation, not "reduction" of an existing file.

**Content sources — real repo knowledge, not boilerplate** (per the established `skip-not-crash-on-missing-external-tool-dependency` dev-brain lesson's own note: "populate free-text fields from real repo knowledge... not boilerplate"):
- Repo purpose: `.claude/project.yaml`'s `project.description` ("Claude Code plugin marketplace; spec-workflow (the autonomous build-loop plugin) develops itself here — dogfood.") and `README.md`'s opening line.
- Dogfood note: same project.yaml description — this repo builds itself via its own spec-workflow plugin, autonomously, via the build-next loop.
- Codex-support pointer: `README.md`'s existing "Codex support (in progress)" section (line 35-37) already states current status accurately — point at it, don't duplicate it.
- Spec pointers: `SPEC.md` (spec-workflow's own contract) and `SPEC-CODEX-COMPAT.md` (this dual-host compatibility spec) — both root-level, both directly relevant to a Codex-side agent.
- Validation path: the actual gate command from `.claude/project.yaml`'s `commands.gate` (`bash plugins/spec-workflow/tests/run-tests.sh && shellcheck -x plugins/spec-workflow/scripts/*.sh plugins/spec-workflow/scripts/lib/*.sh plugins/spec-workflow/tests/*.sh && claude plugin validate plugins/spec-workflow`) — the one command that actually proves a change is correct in this repo, quoted verbatim, not paraphrased.

**`AGENTS.md` structure** (concise — this is a pointer/orientation doc, not a full spec):
1. One-paragraph repo purpose (plugin marketplace; spec-workflow dogfoods itself here).
2. Dogfooding note: this repo is built BY the `spec-workflow` plugin it ships, autonomously, via `/spec-workflow:build-next` — an agent working in this repo may literally be an instance of that same loop.
3. Pointers: `SPEC.md` (spec-workflow contract), `SPEC-CODEX-COMPAT.md` (this compatibility spec), `docs/BACKLOG-CODEX-COMPAT.md` (task backlog), `.claude/project.yaml` (machine-readable config).
4. The verified validation/gate command, quoted verbatim from `.claude/project.yaml`.
5. A one-line pointer to `README.md` for install/usage instructions (don't duplicate them here).

**`CLAUDE.md`**: exactly one line (plus maybe a title), pointing at `AGENTS.md` — per OQ-2's resolution, no duplicated content, no divergence risk.

**Test — new, no existing precedent for asserting root-file content/existence.** Mirror the `REPO="$(cd "$PLUGIN/../.." && pwd)"` pattern (established in `section-codex-marketplace.sh`, `section-repo-hygiene.sh` from MEM-004) to reach the real repo root from a test section; assert `AGENTS.md` exists and contains the required elements (pointers to SPEC.md/SPEC-CODEX-COMPAT.md, the gate command, a dogfood mention); assert `CLAUDE.md` exists, is short (a line-count ceiling, not exact byte match — content may reasonably vary slightly), and contains a pointer to `AGENTS.md`.

**Out of scope for CDX-006**: any CI generation step (OQ-2 explicitly says none this release); README/plugin/script/manifest/test(other than the new content-assertion test)/workflow changes beyond the two root files and their test — README already links the Codex backlog, no cross-reference edit needed unless the DoD's "if needed" clause turns out to require one (verify, don't assume).

**A note on an untrusted issue comment**: issue #178 carries a comment from a `NONE`-permission commenter soliciting paid work with a private payment link. Per this repo's own comment-trust discipline (only OWNER/MEMBER/COLLABORATOR comments are directives), that comment is NOT acted upon — this design section was derived from the actual spec/backlog text only, independent of and before reading that comment's suggested "constraints." Flagged to the human separately; not a basis for any decision here.
