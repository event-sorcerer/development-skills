# Design — mem/E3: Retrieval upgrade (embeddings + PPR)
Grounded in: SPEC-MEMORY §9 (§9.1–§9.5), §7.1 (manifest), §12 (additive-only, capability isolation)

## Components
`capability.sh` (MEM-030) — install/healthcheck/embed/path for the `embeddings` capability: an isolated venv + pinned ONNX bge-small model living under `${CAPABILITY_HOME:-~/.claude/capabilities}/embeddings` (or `--dir` override). Core scripts never import its deps directly.
`brain.py index <role>` (MEM-031) — incremental SQLite vector index at `.claude/identities/<role>/brain/index.sqlite3`, keyed by (slug, content-hash); calls the embeddings capability for changed notes only, degrades to a no-op when the capability is unavailable.
`brain.py recall <role>` hybrid seeding (MEM-032) — unions today's keyword/glob seed set with top-K embedding neighbors read from the index; unchanged ranking/budget/tiers.
`brain.py recall --ppr` (MEM-033, flagged) — replaces 2-hop spread with stdlib Personalized PageRank over `links.json`; off by default.
`recall-eval` (MEM-034) — hermetic fixture + hit@K/MRR report, CI-advisory only.

## Data models
`index.sqlite3` (one file per role, gitignored via §7.1 manifest — already registered as `ignore\t.claude/identities/*/brain/index.sqlite3`):
- table `notes`: `slug TEXT PRIMARY KEY, content_hash TEXT NOT NULL, vector TEXT NOT NULL (JSON array, 384 floats), updated_at TEXT NOT NULL (ISO8601)`.
- `content_hash` = sha256 of the note's BODY only (post-frontmatter text), not the full file — frontmatter fields that churn on every recall/fire (`strength`, `last-fired-at`) must never force a re-embed of unchanged prose.
- Derived layer only: safe to delete at any time; `index --rebuild` regenerates it from `notes/*.md` alone, matching an incremental build from empty (rebuild-equals-incremental, per acceptance criteria).

## Interfaces / contracts
`brain.py <root> index <role> [--rebuild]`:
1. Enumerate `notes/*.md`; compute each note's body hash.
2. `--rebuild`: drop/recreate the `notes` table first, then proceed as step 3 for every note (bypasses the hash-compare short-circuit by construction, since the table starts empty).
3. Compare each note's hash to the stored row (absent on rebuild/first run); unchanged hash = skip (hash-stable no-op). Collect changed/new note bodies.
4. If any changed notes: invoke the capability via `capability.sh embed embeddings` (repo-relative path, sibling of `brain.py`'s scripts dir; overridable for tests via `BRAIN_EMBED_CMD` env var, same stdin/stdout contract) — one text-per-line on stdin, one JSON float-array per line on stdout, order-preserved. Non-zero exit / command not found = capability unavailable: print one stderr notice, leave those notes' rows untouched (no error, no partial/garbage vector), exit 0.
5. Upsert successfully-embedded notes' `(slug, content_hash, vector, updated_at)`.
6. Delete rows for slugs with no corresponding note file (stale cleanup) — safe because the table is fully derived.

`recall` (MEM-032, not yet built) reads `index.sqlite3` read-only if present; its total absence is a normal, error-free state — `index` is opt-in and its absence must never surface as a recall failure. This is a regression guard tested by MEM-031 itself (recall works identically whether or not `index` has ever run).

## Key sequences
1. **Fresh build**: `index <role>` on a role with no `index.sqlite3` → creates it, embeds every note (capability healthy) or embeds nothing but still creates an empty/valid db (capability absent) → idempotent re-run is a full no-op (all hashes match).
2. **Incremental update**: one note's body edited → next `index` run re-embeds only that note; all others hash-match and are skipped.
3. **Rebuild**: `index --rebuild` after N incremental updates → resulting table is byte-for-byte equivalent (modulo `updated_at`) to running fresh-build once over the current note set.

## Decisions
Vector stored as JSON text, not a BLOB — stdlib `sqlite3` has no native vector type; JSON keeps the file human-inspectable/debuggable and avoids a binary-packing format decision this task doesn't need to make (cosine similarity over a 384-length Python list is cheap enough for MEM-032's top-K scan).
Hash the note BODY, not the full file — frontmatter (`strength`, `last-fired-at`, links) changes far more often than prose; hashing the whole file would re-embed on every fire/link event, defeating "incremental update on changed note only."
Capability invocation goes through the exact `capability.sh embed <name> [--dir DIR]` contract MEM-030 defines (stdin lines → stdout JSON-array lines, exit 3 = unavailable) rather than importing anything from the capability's venv — keeps `brain.py` stdlib-only per the core invariant, and means MEM-031 doesn't need MEM-030 merged first: on main today (capability.sh absent), every `index` run simply takes the graceful-absence branch, exactly as it will once MEM-030 lands and the capability is merely uninstalled.
`BRAIN_EMBED_CMD` override exists solely so MEM-031's tests can stub a deterministic fake embedder without depending on the real ONNX runtime or on MEM-030's branch/worktree.

## Out of scope for this epic
Actually calling a real ONNX model (MEM-030, separate task, separate branch) — E3 tasks are independently buildable against the documented `capability.sh` contract.
Hybrid recall ranking/seeding logic (MEM-032) — this doc only defines the index MEM-032 will read from.
PPR (MEM-033) and recall-eval (MEM-034) — later tasks in this epic, no dependency on MEM-031's internals beyond the index file format above.
