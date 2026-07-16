#!/usr/bin/env bash
# section-brain-events.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain-event feed (E2/MEM-020: emit_event schema + atomic emitter) =="

BE_SCRIPTS="$PLUGIN/scripts"

# ---------------------------------------------------------------- schema fields
# emit_event(root, obj) appends ONE line to <root>/.claude/brain-events.jsonl
# carrying the v1 baseline {v, ts, repo, role, type} plus the caller's payload.
BE="$(mktemp -d)"
# project.yaml present -> repo derives from project.name
mkdir -p "$BE/.claude"
cat >"$BE/.claude/project.yaml" <<'YAML'
schemaVersion: 2
project:
    name: acme/widgets
    mainBranch: main
YAML
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "yaml-key-order"})
lines = open(os.path.join(root, ".claude", "brain-events.jsonl"), encoding="utf-8").read().splitlines()
assert len(lines) == 1, "expected exactly one line, got %d" % len(lines)
ev = json.loads(lines[0])
print("V=%r" % ev.get("v"))
print("TS_TYPE=%s" % type(ev.get("ts")).__name__)
print("REPO=%s" % ev.get("repo"))
print("ROLE=%s" % ev.get("role"))
print("TYPE=%s" % ev.get("type"))
print("SLUG=%s" % ev.get("slug"))
' "$BE" 2>&1)"
check "schema: v is integer 1"       "V=1"                 "$out"
check "schema: ts is a string"       "TS_TYPE=str"         "$out"
check "schema: repo from project.name" "REPO=acme/widgets" "$out"
check "schema: role carried through" "ROLE=dev"            "$out"
check "schema: type carried through" "TYPE=NoteMinted"     "$out"
check "schema: payload carried through" "SLUG=yaml-key-order" "$out"
rm -rf "$BE"

# repo fallback: no project.yaml -> basename of root
BE="$(mktemp -d)"
reponame="$(basename "$BE")"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "reviewer", "type": "RecallPerformed"})
ev = json.loads(open(os.path.join(root, ".claude", "brain-events.jsonl")).readline())
print("REPO=%s" % ev.get("repo"))
' "$BE" 2>&1)"
check "schema: repo falls back to root basename" "REPO=$reponame" "$out"
rm -rf "$BE"

# ------------------------------------------------- single write() call contract
# Atomicity rests on ONE write syscall per line (O_APPEND). Patch os.write to
# count invocations across a single emit_event and assert exactly one.
BE="$(mktemp -d)"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
calls = {"n": 0}
real_write = os.write
def counting_write(fd, data):
    calls["n"] += 1
    return real_write(fd, data)
os.write = counting_write
try:
    brain.emit_event(root, {"role": "dev", "type": "LinkFired", "key": "a->b"})
finally:
    os.write = real_write
print("WRITECALLS=%d" % calls["n"])
' "$BE" 2>&1)"
check "atomicity: exactly one os.write() call per emit" "WRITECALLS=1" "$out"
rm -rf "$BE"

# emitted line is newline-terminated (so appends never merge on one line)
BE="$(mktemp -d)"
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "a"})
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "b"})
data = open(os.path.join(root, ".claude", "brain-events.jsonl"), "rb").read()
print("ENDSNL=%s" % (data.endswith(b"\n")))
print("NLINES=%d" % data.count(b"\n"))
' "$BE" 2>&1)"
check "atomicity: each line newline-terminated" "ENDSNL=True" "$out"
check "atomicity: two emits -> two lines"       "NLINES=2"    "$out"
rm -rf "$BE"

# -------------------------------------------- warning-not-error on unwritable
# §8.1.1: an unwritable feed target must NOT raise; emit_event returns falsy and
# prints a warning, and the caller's own work continues unaffected.
BE="$(mktemp -d)"
# Make .claude a read-only regular file so <root>/.claude/brain-events.jsonl can
# neither be created nor its parent dir made -> the append is doomed.
printf '' >"$BE/.claude"
chmod 000 "$BE/.claude" 2>/dev/null || true
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root = sys.argv[1]
rv = brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "slug": "x"})
# caller keeps running -> this print MUST be reached
print("AFTER_EMIT_REACHED")
print("RETVAL=%r" % rv)
' "$BE" 2>&1)"
check "non-blocking: caller continues after failed emit" "AFTER_EMIT_REACHED" "$out"
check "non-blocking: emit_event returns falsy on failure" "RETVAL=False" "$out"
check "non-blocking: a warning is printed" "warning" "$out"
check_absent "non-blocking: no traceback propagated" "Traceback" "$out"
chmod 755 "$BE/.claude" 2>/dev/null || true
rm -rf "$BE"

# ------------------------------------------------------- concurrency stress test
# N real PROCESSES (not threads -- the GIL would mask an OS-level atomicity bug)
# append concurrently to the SAME file. Assert exactly N intact JSON lines, no
# interleaving, no loss.
BE="$(mktemp -d)"
BE_WORKER="$BE/worker.py"
cat >"$BE_WORKER" <<PY
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
import brain
root, idx = sys.argv[1], int(sys.argv[2])
# padded payload keeps each line well under PIPE_BUF (~4KB) while being large
# enough that a non-atomic write would realistically interleave.
brain.emit_event(root, {"role": "dev", "type": "NoteMinted", "idx": idx, "pad": "x" * 200})
PY
BE_N=30
for i in $(seq 1 "$BE_N"); do
    PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 "$BE_WORKER" "$BE" "$i" &
done
wait
out="$(PLUGIN_SCRIPTS="$BE_SCRIPTS" python3 -c '
import json, os, sys
root, n = sys.argv[1], int(sys.argv[2])
p = os.path.join(root, ".claude", "brain-events.jsonl")
lines = open(p, encoding="utf-8").read().splitlines()
valid = 0
idxs = set()
for ln in lines:
    ev = json.loads(ln)   # raises if any line is torn/interleaved
    valid += 1
    idxs.add(ev["idx"])
print("LINES=%d" % len(lines))
print("VALID=%d" % valid)
print("UNIQ=%d" % len(idxs))
print("EXPECT=%d" % n)
' "$BE" "$BE_N" 2>&1)"
check "concurrency: line count == N processes"   "LINES=$BE_N"  "$out"
check "concurrency: every line is valid JSON"    "VALID=$BE_N"  "$out"
check "concurrency: no lost writes (N unique idx)" "UNIQ=$BE_N" "$out"
rm -rf "$BE"
