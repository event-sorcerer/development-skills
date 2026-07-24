"""Observability / traces subsystem (SPEC-ASSISTANT.md Sec5a, Sec10.1, Sec10.2,
Sec10.6, Sec10.7, E4, AST-040, issue #326, docs/design/ast-E4.md).

Per Sec10.1/Sec17.7 emitting an event is O(1) and NEVER blocks a turn: `emit`
below only puts an item on a `queue.Queue` (drop + stderr on overflow/failure,
the exact posture `engine.py`'s `_enqueue_distill` already uses for the
distiller, Sec9.5). Per Sec5a/Sec10.2 there is exactly ONE writer thread for
ALL assistants' traces -- the engine's existing `traces` worker slot
(AST-010's `WORKER_NAMES` registry) runs `run_writer` below instead of its v1
heartbeat no-op; per-root sqlite connections are opened and held ONLY by that
thread, so sqlite's single-writer discipline is respected without any
cross-thread handle ever existing.

`emit`/`run_writer` deliberately take the queue as an explicit argument
(`emit(q, root, event)`, not a hidden module-global `emit(root, event)`) --
this matches `distill.py`'s own `run_worker(q, stop_event, ...)` convention
(explicit queue in, no module-level engine singleton) and keeps this module
free of process-wide state a test would have to reset between runs. Callers
(engine.py's instrumentation call sites) pass `self.queues["traces"]`.

Schema (`events` table, one per-root `traces.sqlite`): `seq` (INTEGER,
writer-assigned, monotonic per root, seeded from `MAX(seq)` at open --
Sec10.1's "monotonic, not wall-clock-perfect" ordering requirement; emitters
stay lock-free because nothing but the writer thread ever assigns a seq),
`ts` (ISO-8601 UTC, stamped by `emit` at enqueue time -- the moment the event
actually happened, not when the writer got around to it), `session_id`,
`turn_id`, `span_id`, `parent_span_id` (Sec10.6: an error event links to its
turn via `turn_id`, and MAY carry its own `span_id`/`parent_span_id` like any
other event -- there is no separate error table), `kind` (dotted:
`turn.start`/`turn.end`/`recall.summary`/`provider.call`/`provider.error`/
`distill.batch`/...), `skill`, `modality`, `status`, and a `payload` JSON
column for everything that is not one of the indexed first-class columns.
Every first-class column is indexed so `query()`'s filters are always
index-backed -- Sec10.2 explicitly rules out `json_extract` for time-range/
correlation queries.

Durability (Sec10.7): traces are PRUNABLE history (a later AST-041 retention
pass may delete old rows) -- this module never treats `traces.sqlite` as a
must-survive file the way `store.py` treats `session.jsonl`. WAL mode + a
`busy_timeout` pragma on every connection mean a crash loses at most the
queued-not-yet-drained tail (already-committed rows survive); schema
creation is idempotent (`CREATE TABLE/INDEX IF NOT EXISTS`) so opening an
already-initialized `traces.sqlite` a second time is a no-op, never an
error.

`traces.sqlite` lives at `<root>/.claude/assistant/traces.sqlite` -- the SAME
directory `store.py`'s `session.jsonl`/`session-state.json` already use, and
that directory is ALREADY gitignored wholesale (`scripts/local-state.manifest`:
`ignore\t.claude/assistant/`, AST-005/AST-014) -- no new manifest entry is
needed for this file specifically; it falls under the existing directory
entry, and this docstring records that decision so a later reader does not
go looking for a missing per-file line.

Library:
    emit(q, root, event) -> None
        Enqueue-only; NEVER raises into the caller. `event` is a dict with at
        least `"kind"`; `session_id`/`turn_id`/`span_id`/`parent_span_id`/
        `skill`/`modality`/`status`/`payload` are optional (stored as NULL /
        `{}` when absent). `ts` is stamped here if the caller did not supply
        one.
    run_writer(q, stop_event, poll_timeout=..., max_drain=...) -> None
        The `traces` worker loop body (engine.py's start() binds this into
        the AST-010 `traces` slot). Runs on its own thread only.
    query(root, since=None, turn=None, limit=200) -> list[dict]
        Read-only path for endpoints/terminal (AST-043/AST-045 consume
        this). `since` is a `seq` cursor (rows with `seq > since`), not a
        timestamp -- matches "resume after the last seq I've already seen"
        polling, and stays an indexed-integer-column comparison.
"""
import json
import os
import queue as queue_module
import sqlite3
import sys
from datetime import datetime, timezone

TRACES_DIR_REL = os.path.join(".claude", "assistant")  # same dir as store.py's SessionStore
TRACES_FILE_NAME = "traces.sqlite"

# How long run_writer's queue.get() blocks between stop_event checks -- same
# rationale as distill.py's DEFAULT_POLL_TIMEOUT_SECONDS: small enough that
# stop() (5s join timeout, engine.py) always observes the thread exit
# promptly, large enough that an idle writer does not spin.
DEFAULT_POLL_TIMEOUT_SECONDS = 0.5

# Bounds how many additional already-queued items one drain cycle will pull
# via get_nowait() after the first blocking get() succeeds -- batches a
# burst into one commit per root without letting a single drain run forever
# and starve stop_event checks under a truly enormous backlog.
DEFAULT_MAX_DRAIN = 500

_COLUMNS = (
    "seq", "ts", "session_id", "turn_id", "span_id", "parent_span_id",
    "kind", "skill", "modality", "status", "payload",
)

_SCHEMA_DDL = (
    "CREATE TABLE IF NOT EXISTS events ("
    "seq INTEGER PRIMARY KEY, "
    "ts TEXT, "
    "session_id TEXT, "
    "turn_id TEXT, "
    "span_id TEXT, "
    "parent_span_id TEXT, "
    "kind TEXT, "
    "skill TEXT, "
    "modality TEXT, "
    "status TEXT, "
    "payload TEXT"
    ")"
)

_INDEX_DDL = [
    "CREATE INDEX IF NOT EXISTS ix_events_seq ON events(seq)",
    "CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts)",
    "CREATE INDEX IF NOT EXISTS ix_events_session_id ON events(session_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_turn_id ON events(turn_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_span_id ON events(span_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_parent_span_id ON events(parent_span_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_kind ON events(kind)",
    "CREATE INDEX IF NOT EXISTS ix_events_skill ON events(skill)",
    "CREATE INDEX IF NOT EXISTS ix_events_modality ON events(modality)",
    "CREATE INDEX IF NOT EXISTS ix_events_status ON events(status)",
]

_INSERT_SQL = (
    "INSERT INTO events (seq, ts, session_id, turn_id, span_id, "
    "parent_span_id, kind, skill, modality, status, payload) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _db_path(root):
    return os.path.join(root, TRACES_DIR_REL, TRACES_FILE_NAME)


def emit(q, root, event):
    """Enqueue-only (Sec10.1/Sec17.7): never blocks, never raises into the
    caller. On a full or otherwise unusable queue this drops the event and
    writes a note to stderr -- the exact posture `engine.py`'s
    `_enqueue_distill` already uses for the distiller queue (design doc's
    "same posture as the distiller enqueue")."""
    try:
        ev = dict(event or {})
        ev.setdefault("ts", _now_iso())
        item = {"root": root, "event": ev}
        q.put_nowait(item)
    except queue_module.Full:
        sys.stderr.write(
            "observability: traces queue full, dropping event kind=%r\n"
            % (event or {}).get("kind")
        )
    except Exception as exc:  # never raise into a turn (Sec17.7)
        sys.stderr.write("observability: emit failed: %s\n" % exc)


def _open_conn(root):
    """Opens (and idempotently schema-creates) the ONE connection this
    writer thread will hold for `root`. WAL + busy_timeout so a slow reader
    never blocks this thread and this thread's writes never corrupt a
    concurrent read-only reader (Sec10.2)."""
    path = _db_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute(_SCHEMA_DDL)
    for ddl in _INDEX_DDL:
        conn.execute(ddl)
    row = conn.execute("SELECT MAX(seq) FROM events").fetchone()
    next_seq = (row[0] or 0) + 1
    return conn, next_seq


def _bucket(buffers, item):
    if not isinstance(item, dict):
        return
    root = item.get("root")
    event = item.get("event")
    if not root or not isinstance(event, dict) or "kind" not in event:
        return
    buffers.setdefault(root, []).append(event)


def _flush(conns, buffers):
    for root, events in buffers.items():
        if not events:
            continue
        try:
            if root not in conns:
                conns[root] = _open_conn(root)
            conn, next_seq = conns[root]
            rows = []
            for ev in events:
                rows.append((
                    next_seq,
                    ev.get("ts") or _now_iso(),
                    ev.get("session_id"),
                    ev.get("turn_id"),
                    ev.get("span_id"),
                    ev.get("parent_span_id"),
                    ev.get("kind"),
                    ev.get("skill"),
                    ev.get("modality"),
                    ev.get("status"),
                    json.dumps(ev.get("payload") or {}, sort_keys=True),
                ))
                next_seq += 1
            conn.execute("BEGIN IMMEDIATE")
            conn.executemany(_INSERT_SQL, rows)
            conn.execute("COMMIT")
            conns[root] = (conn, next_seq)
        except Exception as exc:  # park-and-continue -- never kill the writer thread
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            sys.stderr.write("observability writer: batch failed for %s: %s\n" % (root, exc))


def run_writer(q, stop_event, poll_timeout=DEFAULT_POLL_TIMEOUT_SECONDS,
                max_drain=DEFAULT_MAX_DRAIN):
    """The `traces` worker body engine.py's `start()` binds into the
    AST-010 `traces` slot, replacing the v1 heartbeat no-op. Drains `q` for
    items shaped `{"root": str, "event": dict}` (this module's `emit`),
    buffers PER ROOT within one drain cycle, and commits once per root per
    cycle (`executemany` -- Sec5a "batched commits").

    Runs entirely on ITS OWN thread: the per-root sqlite connections this
    function opens are NEVER touched by any other thread (Sec10.2's single-
    writer discipline). `q.get(timeout=poll_timeout)` bounds how long the
    loop can go without checking `stop_event`, so `engine.stop()`'s bounded
    join always succeeds promptly.

    Shutdown (bounded drain): once `stop_event` is set and the loop exits,
    whatever is STILL queued (never blocking -- `get_nowait` only) is
    drained and flushed once more before every held connection is closed --
    a crash loses at most the never-drained tail; an orderly stop() loses
    nothing already enqueued.
    """
    conns = {}
    try:
        while not stop_event.is_set():
            try:
                item = q.get(timeout=poll_timeout)
            except queue_module.Empty:
                continue
            buffers = {}
            _bucket(buffers, item)
            q.task_done()
            for _ in range(max_drain - 1):
                try:
                    item = q.get_nowait()
                except queue_module.Empty:
                    break
                _bucket(buffers, item)
                q.task_done()
            _flush(conns, buffers)
    finally:
        drained = {}
        while True:
            try:
                item = q.get_nowait()
            except queue_module.Empty:
                break
            _bucket(drained, item)
            q.task_done()
        if drained:
            _flush(conns, drained)
        for conn, _next_seq in conns.values():
            try:
                conn.close()
            except Exception:
                pass


def query(root, since=None, turn=None, limit=200):
    """Read path for endpoints/terminal (AST-043/AST-045). Opens a fresh
    read-only connection per call (this is a low-frequency, low-volume read
    path -- unlike the writer, no connection is held across calls). Returns
    `[]` (never raises) when `root` has no `traces.sqlite` yet -- a fresh
    assistant with no turns run is not an error.

    `since` filters to `seq > since` (a resume cursor, NOT a timestamp --
    see the module docstring); `turn` filters to `turn_id == turn`. Both
    filters, and the default ordering, are backed by the `seq`/`turn_id`
    indexes `_open_conn` creates -- never a `json_extract` scan (Sec10.2).
    """
    path = _db_path(root)
    if not os.path.exists(path):
        return []

    uri = "file:%s?mode=ro" % path.replace("?", "%3F").replace("#", "%23")
    conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    try:
        conn.execute("PRAGMA busy_timeout=5000")
        clauses = []
        params = []
        if since is not None:
            clauses.append("seq > ?")
            params.append(since)
        if turn is not None:
            clauses.append("turn_id = ?")
            params.append(turn)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        sql = (
            "SELECT %s FROM events %s ORDER BY seq ASC LIMIT ?"
            % (", ".join(_COLUMNS), where)
        )
        params.append(limit)
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as exc:
            # The writer's `sqlite3.connect(path)` creates the file's header
            # on disk before its own schema DDL runs (a real, if narrow,
            # window) -- a reader that opens in that window sees a file
            # that EXISTS but has no `events` table yet. That is exactly
            # equivalent to "no events for this root yet" from a caller's
            # perspective, not an error -- never raise, return no rows.
            if "no such table" not in str(exc):
                raise
            rows = []
    finally:
        conn.close()

    out = []
    for row in rows:
        rec = dict(zip(_COLUMNS, row))
        try:
            rec["payload"] = json.loads(rec["payload"]) if rec["payload"] else {}
        except ValueError:
            rec["payload"] = {}
        out.append(rec)
    return out
