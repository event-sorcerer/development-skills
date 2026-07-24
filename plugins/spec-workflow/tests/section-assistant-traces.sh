#!/usr/bin/env bash
# section-assistant-traces.sh -- AST-040: event emitter + traces.sqlite
# writer (SPEC-ASSISTANT.md Sec10.1/Sec10.2/Sec10.6/Sec10.7, E4, issue #326,
# docs/design/ast-E4.md). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant traces (AST-040: event emitter + traces.sqlite writer, SPEC-ASSISTANT.md Sec10.1/Sec10.2/Sec10.6/Sec10.7) =="

AT_SCRIPTS="$PLUGIN/scripts"

at_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- unit: schema idempotent create + WAL mode on --"
schema_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time, sqlite3
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-schema-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1"})
time.sleep(0.6)
stop.set()
t.join(timeout=3)

db_path = os.path.join(root, ".claude", "assistant", "traces.sqlite")
print("DB_EXISTS", os.path.exists(db_path))
conn = sqlite3.connect(db_path)
mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
print("JOURNAL_MODE", mode)
conn.execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY)")  # idempotent no-op guard sanity
conn.close()

# reopening the writer against the SAME root must not fail (idempotent DDL)
q2 = queue.Queue()
stop2 = threading.Event()
t2 = threading.Thread(target=observability.run_writer, args=(q2, stop2))
t2.start()
observability.emit(q2, root, {"kind": "turn.start", "turn_id": "t2"})
time.sleep(0.6)
stop2.set()
t2.join(timeout=3)
print("REOPEN_OK", True)
PY
)"
check "traces schema: traces.sqlite created under <root>/.claude/assistant/" "DB_EXISTS True" "$schema_out"
check "traces schema: WAL mode is on" "JOURNAL_MODE wal" "$schema_out"
check "traces schema: reopening the writer against an existing db is idempotent" "REOPEN_OK True" "$schema_out"

# ------------------------------------------------------------------------
echo "-- unit: emit -> writer drain -> events visible via query --"
drain_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-drain-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1", "session_id": "s1", "payload": {"n": 1}})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t1", "session_id": "s1", "status": "ok"})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root)
    if len(rows) >= 2:
        break
    time.sleep(0.2)

stop.set()
t.join(timeout=3)

print("ROW_COUNT", len(rows))
print("KINDS", [r["kind"] for r in rows])
print("PAYLOAD_ROUNDTRIP", rows[0]["payload"] == {"n": 1} if rows else None)
print("SESSION_ID_STORED", rows[0]["session_id"] == "s1" if rows else None)
PY
)"
check "emit->drain: both events land in traces.sqlite" "ROW_COUNT 2" "$drain_out"
check "emit->drain: kinds preserved in seq order" "KINDS ['turn.start', 'turn.end']" "$drain_out"
check "emit->drain: JSON payload round-trips through the payload column" "PAYLOAD_ROUNDTRIP True" "$drain_out"
check "emit->drain: session_id stored on the first-class column" "SESSION_ID_STORED True" "$drain_out"

# ------------------------------------------------------------------------
echo "-- unit: seq is monotonic per root, including after a writer reopen --"
seq_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-seq-")

def run_batch(n, start_i):
    q = queue.Queue()
    stop = threading.Event()
    t = threading.Thread(target=observability.run_writer, args=(q, stop))
    t.start()
    for i in range(start_i, start_i + n):
        observability.emit(q, root, {"kind": "turn.start", "turn_id": "t%d" % i})
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if len(observability.query(root, limit=1000)) >= start_i + n:
            break
        time.sleep(0.2)
    stop.set()
    t.join(timeout=3)

run_batch(3, 0)
rows1 = observability.query(root, limit=1000)
seqs1 = [r["seq"] for r in rows1]
print("SEQS_FIRST_OPEN", seqs1)
print("MONOTONIC_FIRST", seqs1 == sorted(seqs1) and len(set(seqs1)) == len(seqs1))

# reopen (a NEW run_writer thread/queue over the SAME root) -- seq must
# continue from where it left off, never reset to 1.
run_batch(2, 3)
rows2 = observability.query(root, limit=1000)
seqs2 = [r["seq"] for r in rows2]
print("SEQS_AFTER_REOPEN", seqs2)
print("CONTINUES_AFTER_REOPEN", seqs2 == sorted(seqs2) and len(set(seqs2)) == len(seqs2) and max(seqs1) < min(s for s in seqs2 if s not in seqs1))
PY
)"
check "seq: monotonic within one writer session" "MONOTONIC_FIRST True" "$seq_out"
check "seq: reseeded from MAX(seq) after reopen -- continues, never resets" "CONTINUES_AFTER_REOPEN True" "$seq_out"

# ------------------------------------------------------------------------
echo "-- unit: query filters by since (seq cursor) and turn, index-backed --"
qfilter_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-qfilter-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

observability.emit(q, root, {"kind": "turn.start", "turn_id": "tA"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tA"})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "tB"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tB"})

deadline = time.monotonic() + 5.0
all_rows = []
while time.monotonic() < deadline:
    all_rows = observability.query(root, limit=1000)
    if len(all_rows) >= 4:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

by_turn = observability.query(root, turn="tA")
print("TURN_FILTER_COUNT", len(by_turn))
print("TURN_FILTER_ALL_TA", all(r["turn_id"] == "tA" for r in by_turn))

first_seq = all_rows[0]["seq"]
since_rows = observability.query(root, since=first_seq)
print("SINCE_FILTER_COUNT", len(since_rows))
print("SINCE_FILTER_EXCLUDES_FIRST", all(r["seq"] > first_seq for r in since_rows))
PY
)"
check "query: turn filter returns only that turn's events" "TURN_FILTER_COUNT 2" "$qfilter_out"
check "query: turn filter never mixes in another turn's rows" "TURN_FILTER_ALL_TA True" "$qfilter_out"
check "query: since=<seq> excludes everything at or before that seq" "SINCE_FILTER_COUNT 3" "$qfilter_out"
check "query: since filter is a strict > comparison" "SINCE_FILTER_EXCLUDES_FIRST True" "$qfilter_out"

# ------------------------------------------------------------------------
echo "-- unit: emitter never raises when the queue is full --"
overflow_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, queue, io, contextlib
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

q = queue.Queue(maxsize=1)
q.put_nowait({"root": "r", "event": {"kind": "filler"}})  # queue is now full

stderr_buf = io.StringIO()
raised = False
with contextlib.redirect_stderr(stderr_buf):
    try:
        observability.emit(q, "/some/root", {"kind": "turn.start"})
    except Exception:
        raised = True

print("RAISED", raised)
print("STDERR_MENTIONS_DROP", "observability" in stderr_buf.getvalue() and "full" in stderr_buf.getvalue().lower())
PY
)"
check "emit: never raises on a full queue" "RAISED False" "$overflow_out"
check "emit: a dropped event is noted on stderr, not silently swallowed" "STDERR_MENTIONS_DROP True" "$overflow_out"

# ------------------------------------------------------------------------
echo "-- unit: distill.batch event emitted on distiller batch completion --"
distill_trace_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time, queue
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill, observability

root = tempfile.mkdtemp(prefix="at-distill-")
identities = os.path.join(root, ".claude", "identities")
os.makedirs(identities, exist_ok=True)

dq = queue.Queue()
tq = queue.Queue()
stop_d = threading.Event()
stop_t = threading.Event()
td = threading.Thread(target=distill.run_worker, args=(dq, stop_d),
                       kwargs={"batch_n": 2, "traces_queue": tq})
tt = threading.Thread(target=observability.run_writer, args=(tq, stop_t))
td.start()
tt.start()

def item(i):
    return {"root": root, "identities": identities,
            "exchange": {"user": "message %d about rocket telemetry" % i, "assistant": "ack"}}

dq.put(item(0))
dq.put(item(1))

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root)
    if any(r["kind"] == "distill.batch" for r in rows):
        break
    time.sleep(0.2)

stop_d.set()
td.join(timeout=3)
stop_t.set()
tt.join(timeout=3)

print("DISTILL_BATCH_EVENT_SEEN", any(r["kind"] == "distill.batch" for r in rows))
PY
)"
check "distill.batch: a real batch completion emits a distill.batch trace event" "DISTILL_BATCH_EVENT_SEEN True" "$distill_trace_out"

# ------------------------------------------------------------------------
echo "-- integration: engine wiring -- _chat emits turn.start/recall.*/provider.call/turn.end --"
_at_root="$(mktemp -d)"
at_repo "$_at_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine, observability

root = os.environ["ROOT"]

def stub_complete(context, **kwargs):
    return {"text": "reply about rocket telemetry", "usage": {"tokens": 12}, "timings": None}

adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "tell me about rocket telemetry"})
    print("CHAT_STATUS", status)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        kinds = [r["kind"] for r in rows]
        if "turn.end" in kinds:
            break
        time.sleep(0.2)
    kinds = [r["kind"] for r in rows]
    print("KINDS", kinds)
    print("HAS_TURN_START", "turn.start" in kinds)
    print("HAS_PROVIDER_CALL", "provider.call" in kinds)
    print("HAS_TURN_END", "turn.end" in kinds)

    turn_ids = {r["turn_id"] for r in rows if r.get("turn_id")}
    print("SINGLE_TURN_ID", len(turn_ids) == 1)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring: a chat turn emits turn.start" "HAS_TURN_START True" "$engine_out"
check "engine wiring: a chat turn emits provider.call" "HAS_PROVIDER_CALL True" "$engine_out"
check "engine wiring: a chat turn emits turn.end" "HAS_TURN_END True" "$engine_out"
check "engine wiring: every trace event for one turn shares one turn_id" "SINGLE_TURN_ID True" "$engine_out"
check "engine wiring: engine.stop() joins the (now real) traces worker cleanly" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
if [[ "$engine_out" != *"HAS_TURN_END True"* ]]; then echo "$engine_out" >&2; fi
rm -rf "$_at_root"

# ------------------------------------------------------------------------
echo "-- integration: a provider failure emits a first-class provider.error linked to its turn --"
_ate_root="$(mktemp -d)"
at_repo "$_ate_root" jarvis

err_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_ate_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine, observability

root = os.environ["ROOT"]

def failing_complete(context, **kwargs):
    raise adapters.NonzeroExit("provider exited 1")

adapters.register_adapter("openai", failing_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "hello"})
    print("CHAT_STATUS", status)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "provider.error" for r in rows):
            break
        time.sleep(0.2)

    error_rows = [r for r in rows if r["kind"] == "provider.error"]
    print("ERROR_EVENT_SEEN", len(error_rows) == 1)
    print("ERROR_LINKED_TO_TURN", bool(error_rows) and bool(error_rows[0].get("turn_id")))
    turn_ids = {r["turn_id"] for r in rows if r.get("turn_id")}
    print("ERROR_SHARES_TURN_ID_WITH_START", len(turn_ids) == 1)
finally:
    e.stop()
PY
)"
check "provider error: a 502 chat still records a first-class provider.error event" "ERROR_EVENT_SEEN True" "$err_out"
check "provider error: the error event carries a turn_id (Sec10.6 linkage)" "ERROR_LINKED_TO_TURN True" "$err_out"
check "provider error: the error's turn_id matches the turn's other events" "ERROR_SHARES_TURN_ID_WITH_START True" "$err_out"
rm -rf "$_ate_root"

# ------------------------------------------------------------------------
echo "-- integration: turns never block on the traces writer (bounded latency under load) --"
_atl_root="$(mktemp -d)"
at_repo "$_atl_root" jarvis

latency_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_atl_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine

root = os.environ["ROOT"]

def stub_complete(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

def timed_chat_calls(e, count):
    t0 = time.monotonic()
    for i in range(count):
        status, _payload, _ct = e.handle("POST", "/assistant/chat", body={"message": "hello %d" % i})
        if status != 200:
            return None
    return time.monotonic() - t0

state_dir_baseline = os.path.join(root, ".claude", "assistant-engine-state-baseline")
e_baseline = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_baseline)
e_baseline.start()
baseline_elapsed = timed_chat_calls(e_baseline, 10)
e_baseline.stop()

state_dir_loaded = os.path.join(root, ".claude", "assistant-engine-state-loaded")
e_loaded = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_loaded)
e_loaded.start()
backlog_q = e_loaded.queues["traces"]
for i in range(500):
    try:
        backlog_q.put_nowait({"root": root, "event": {"kind": "synthetic.backlog", "payload": {"i": i}}})
    except Exception:
        break

loaded_elapsed = timed_chat_calls(e_loaded, 10)
e_loaded.stop()

print("BASELINE_ELAPSED", baseline_elapsed)
print("LOADED_ELAPSED", loaded_elapsed)
print("LOADED_UNDER_BOUND", loaded_elapsed is not None and loaded_elapsed < 10.0)
print("LOADED_NOT_WORSE_THAN_10X_BASELINE",
      loaded_elapsed is not None and baseline_elapsed is not None
      and loaded_elapsed < max(baseline_elapsed * 10.0, 5.0))
PY
)"
check "latency: 10 turns complete quickly even while the traces writer chews a 500-item backlog" "LOADED_UNDER_BOUND True" "$latency_out"
check "latency: loaded-writer latency stays within a generous multiple of the idle baseline" "LOADED_NOT_WORSE_THAN_10X_BASELINE True" "$latency_out"
rm -rf "$_atl_root"

# ------------------------------------------------------------------------
echo "-- guard: traces.sqlite is registered in the local-state manifest mechanism --"
ls_policy="$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN/scripts/lib')
import local_state
print(local_state.policy_of('.claude/assistant/'))
")"
check "manifest: .claude/assistant/ (covers traces.sqlite) is policy=ignore" "ignore" "$ls_policy"
traces_src="$(cat "$AT_SCRIPTS/assistant/observability.py")"
check "observability.py: traces.sqlite lives under the already-ignored .claude/assistant/ dir" "TRACES_DIR_REL = os.path.join(\".claude\", \"assistant\")" "$traces_src"
