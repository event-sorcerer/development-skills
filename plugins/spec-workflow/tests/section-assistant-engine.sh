#!/usr/bin/env bash
# section-assistant-engine.sh -- AST-010: assistant engine package skeleton +
# route table + lifecycle wiring (SPEC-ASSISTANT.md §5a, issue #308). Sourced
# by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant engine (AST-010: route table + worker lifecycle, SPEC-ASSISTANT.md §5a) =="

AE_SCRIPTS="$PLUGIN/scripts"
NV="$PLUGIN/scripts/neural-view.py"

# ae_repo <dir> <name> -- a marker'd repo with a structurally valid, enabled
# assistant: section (mirrors section-assistant-default.sh's ad_repo).
ae_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$main]" \
        '    systemPrompt: |' \
        "        You are $main." \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        '                bin: codex' \
        >"$dir/.claude/project.yaml"
}

# --------------------------------------------------------------- unit: no server
echo "-- unit: route dispatch + worker registry (no server) --"
_ae_unit_state="$(mktemp -d)"
_ae_unit_repo_a="$(mktemp -d)"
_ae_unit_repo_b="$(mktemp -d)"
ae_repo "$_ae_unit_repo_a" jarvis
mkdir -p "$_ae_unit_repo_b/.claude"
printf '%s\n' '# neural-network' >"$_ae_unit_repo_b/.claude/.neural-network"   # marker, no assistant: section -- not a candidate

unit_out="$(SCRIPTS_DIR="$AE_SCRIPTS" REPO_A="$_ae_unit_repo_a" REPO_B="$_ae_unit_repo_b" STATE="$_ae_unit_state" python3 - <<'PY'
import os, sys, threading
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

baseline = {t.ident for t in threading.enumerate()}

# review r2 regression: repos_holder is a MUTABLE list the getter reads live
# (mirrors neural-view.py, where rescan_loop reassigns the module-level
# REPOS after boot) -- starts with only the non-candidate repo so the
# effect of a later mutation on /assistant/status is unambiguous.
repos_holder = [("b", os.environ["REPO_B"])]
e = engine.AssistantEngine(lambda: repos_holder, os.environ["STATE"])

# unmatched route -> None (caller 404s)
print("UNMATCHED", e.handle("GET", "/assistant/nope") is None)

# start() launches exactly the 4 mandated subsystem workers
e.start()
names = sorted(n for n, _, _ in e.workers)
print("WORKER_NAMES", names)
after_start = {t.ident for t in threading.enumerate()} - baseline
print("THREADS_AFTER_START", len(after_start))

status_code, payload, ctype = e.handle("GET", "/assistant/status")
print("STATUS_CODE", status_code)
print("CTYPE", ctype)
print("ENGINE_FIELD", payload["engine"])
print("SELECTED", payload["selected"])
print("ASSISTANTS_BEFORE", payload["assistants"])
print("WORKERS_ALIVE", all(w["alive"] for w in payload["workers"]))
print("WORKERS_COUNT", len(payload["workers"]))

# review r2 regression: mutate the SAME list object the getter closes over
# (no engine reconstruction) -- the engine must read the live list, not a
# constructor-time snapshot.
repos_holder.append(("a", os.environ["REPO_A"]))
_, payload2, _ = e.handle("GET", "/assistant/status")
print("ASSISTANTS_AFTER", payload2["assistants"])

# idempotence: start() again must not spawn duplicate workers
e.start()
print("WORKER_COUNT_AFTER_RESTART", len(e.workers))

e.stop()
print("THREADS_AFTER_STOP", len({t.ident for t in threading.enumerate()} - baseline))
print("ALL_JOINED", all(not t.is_alive() for _, t, _ in e.workers if t is not None) if e.workers else True)

# idempotence: stop() again must not raise
e.stop()
print("DOUBLE_STOP_OK", True)
PY
)"
rc=$?
check_rc "engine unit script exits 0" 0 "$rc"
check "engine unit: unmatched route returns None" "UNMATCHED True" "$unit_out"
check "engine unit: worker registry has the four mandated subsystems" \
    "WORKER_NAMES ['distiller', 'index', 'tasks', 'traces']" "$unit_out"
check "engine unit: start() launches exactly 4 live threads" "THREADS_AFTER_START 4" "$unit_out"
check "engine unit: status route returns 200" "STATUS_CODE 200" "$unit_out"
check "engine unit: status content-type is JSON" "CTYPE application/json" "$unit_out"
check "engine unit: status engine field is ok" "ENGINE_FIELD ok" "$unit_out"
check "engine unit: status selected is null (no selection logic in AST-010)" "SELECTED None" "$unit_out"
check "engine unit: status counts zero before the candidate repo is added" "ASSISTANTS_BEFORE 0" "$unit_out"
check "engine unit: status workers all report alive" "WORKERS_ALIVE True" "$unit_out"
check "engine unit: status workers count is 4" "WORKERS_COUNT 4" "$unit_out"
check "engine unit: status reads the LIVE repos list (getter, not a ctor-time snapshot) after mutation" \
    "ASSISTANTS_AFTER 1" "$unit_out"
check "engine unit: start() is idempotent (no duplicate workers)" "WORKER_COUNT_AFTER_RESTART 4" "$unit_out"
check "engine unit: stop() joins every worker (no leaked threads)" "THREADS_AFTER_STOP 0" "$unit_out"
check "engine unit: stop() actually joins each worker thread" "ALL_JOINED True" "$unit_out"
check "engine unit: stop() is idempotent (second call does not raise)" "DOUBLE_STOP_OK True" "$unit_out"
rm -rf "$_ae_unit_state" "$_ae_unit_repo_a" "$_ae_unit_repo_b"

# --------------------------------------------------------------- integration: real server
echo "-- integration: real server on a scratch port --"
_ae_root="$(mktemp -d)"          # scan-fixture repo (--dir)
_ae_state="$(mktemp -d)"         # server state (pid/port)
_ae_scan_empty="$(mktemp -d)"    # empty scan base so real ~/Development repos never leak in
ae_repo "$_ae_root" friday

export NEURAL_VIEW_STATE="$_ae_state" NEURAL_VIEW_SCAN="$_ae_scan_empty"
lifecycle_start "assistant engine: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ae_root"'

status_body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/status")"
check "assistant/status: engine ok" '"engine": "ok"' "$status_body"
check "assistant/status: 4 workers reported" '"name": "distiller"' "$status_body"
check "assistant/status: traces worker reported" '"name": "traces"' "$status_body"
check "assistant/status: tasks worker reported" '"name": "tasks"' "$status_body"
check "assistant/status: index worker reported" '"name": "index"' "$status_body"
check "assistant/status: workers report alive true" '"alive": true' "$status_body"
check "assistant/status: assistants counts the fixture candidate" '"assistants": 1' "$status_body"
check "assistant/status: selected is null" '"selected": null' "$status_body"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/status")"
check "assistant/status: HTTP 200" "200" "$code"

nf_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/no-such-route")"
check "assistant: unmatched /assistant/* route 404s" "404" "$nf_code"

# regression: pre-existing routes must still serve byte-identically
graph_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "regression: /graph still serves (200)" "200" "$graph_code"
page_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/")"
check "regression: / still serves (200)" "200" "$page_code"

# POST is also mounted for the engine (future turn/selection routes), and
# still 404s for anything not under /assistant/*.
post_code="$(curl -s -o /dev/null -X POST -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/no-such-route")"
check "assistant: unmatched POST /assistant/* route 404s" "404" "$post_code"
post_other_code="$(curl -s -o /dev/null -X POST -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/not-assistant")"
check "regression: unrelated POST route still 404s (unchanged behavior)" "404" "$post_other_code"

_ae_pid="$(cat "$_ae_state/pid")"
python3 "$NV" stop >/dev/null
_ae_freed=0
for _ in $(seq 1 30); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$NEURAL_VIEW_PORT") 2>/dev/null; then _ae_freed=1; break; fi
    sleep 0.1
done
if [[ "$_ae_freed" -eq 1 ]]; then echo "ok   assistant engine: SIGTERM stop frees the port cleanly"
else echo "FAIL assistant engine: SIGTERM stop frees the port cleanly — port still held"; fails=$((fails + 1)); fi
if kill -0 "$_ae_pid" 2>/dev/null; then echo "FAIL assistant engine: server process still alive after stop"; fails=$((fails + 1))
else echo "ok   assistant engine: server process no longer alive after stop"; fi

unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ae_root" "$_ae_state" "$_ae_scan_empty"

echo "-- engine: DISTILLER_QUEUE_MAXSIZE overflow is drop-oldest (issue #389) --"
_ae_dq_state="$(mktemp -d)"
dq_out="$(SCRIPTS_DIR="$AE_SCRIPTS" STATE="$_ae_dq_state" python3 - <<'PY'
import os, sys, queue as queue_module
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

repos = lambda: []
state_dir = os.environ["STATE"]
e = engine.AssistantEngine(repos, state_dir)
# no e.start() -- nothing drains queues["distiller"], so the queue's own
# contents after N _enqueue_distill calls reflect ONLY the overflow policy,
# never a race with a real worker thread.
e.queues["distiller"] = queue_module.Queue(maxsize=5)

for i in range(5):
    e._enqueue_distill("root", "u%d" % i, "a%d" % i, [])
print("FULL_LEN", e.queues["distiller"].qsize())

# 3 more pushes past maxsize=5 -- drop-oldest means u0/u1/u2 are evicted,
# u3..u7 remain (still exactly maxsize items).
for i in range(5, 8):
    e._enqueue_distill("root", "u%d" % i, "a%d" % i, [])

remaining = []
while True:
    try:
        remaining.append(e.queues["distiller"].get_nowait())
    except queue_module.Empty:
        break
users = [item["exchange"]["user"] for item in remaining]
print("OVERFLOW_LEN", len(users))
print("OVERFLOW_USERS", users)

# --- documented race-degrades-to-drop-newest branch (see _enqueue_distill's
# docstring): a raced eviction where another producer's get_nowait/put_nowait
# slips in between this call's own two calls degrades to silently dropping
# THIS item. Deterministically reproduced with a fake queue whose put_nowait
# always raises Full (simulating an already-full queue) and whose get_nowait
# always raises Empty (simulating the raced eviction: something else already
# took the oldest slot) -- so the retry put_nowait also raises Full, and the
# item is dropped without _enqueue_distill raising.
class _AlwaysFullQueue:
    def put_nowait(self, item):
        raise queue_module.Full
    def get_nowait(self):
        raise queue_module.Empty

e.queues["distiller"] = _AlwaysFullQueue()
try:
    e._enqueue_distill("root", "raced-user", "raced-assistant", [])
    print("RACE_RAISED", False)
except Exception:
    print("RACE_RAISED", True)
PY
)"
rc=$?
check_rc "distiller overflow script exits 0" 0 "$rc"
check "queue fills to exactly maxsize before any overflow" "FULL_LEN 5" "$dq_out"
check "overflow keeps exactly maxsize items (drop-oldest, never grows unbounded)" "OVERFLOW_LEN 5" "$dq_out"
check "overflow evicts the oldest and keeps the newest 5" "OVERFLOW_USERS ['u3', 'u4', 'u5', 'u6', 'u7']" "$dq_out"
check "a raced eviction degrades to silently dropping the item, never raises (Sec9.5)" "RACE_RAISED False" "$dq_out"

rm -rf "$_ae_dq_state"
