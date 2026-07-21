#!/usr/bin/env bash
# section-serial-delivery.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/hookjson) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Covers issue #272: methodology.serialDelivery — a stricter, orthogonal mode
# to maxInProgress that gates on MERGE rather than a parallel-lane count. Two
# enforcement points, tested independently:
#   1. next.py's picker: WAIT instead of PICK while any board task is in a
#      not-yet-merged working state (In progress OR In review).
#   2. guard-board-move.sh: defense in depth against a manual
#      `board.sh move <n> "In progress"` while another task is already
#      In progress/In review, read from the offline board-cache.json (never
#      a network call) — fail OPEN with a warning on a cache miss.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== next.py (serialDelivery picker gate, #272) =="

out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-review.json")"
check "serial + In review blocker: WAIT line names #2 and its status" "WAIT: serial delivery — #2 FX-002: auth model is In review; merge it before picking" "$out"
check_absent "serial + In review blocker: no PICK line" "=> PICK:" "$out"

out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-progress.json")"
check "serial + In progress blocker: WAIT line names #2 and its status" "WAIT: serial delivery — #2 FX-002: auth model is In progress; merge it before picking" "$out"
check_absent "serial + In progress blocker: no PICK line" "=> PICK:" "$out"

out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-safe.json")"
check "serial + only QA/Ready/Deployed: PICK proceeds normally" "=> PICK: #1  FX-001: scaffold" "$out"
check_absent "serial + only QA/Ready/Deployed: no WAIT line" "WAIT: serial delivery" "$out"

# regression: mode OFF (existing fixtures/project, no serialDelivery key) is
# byte-identical to the pre-#272 behavior -- same assertions section-next-similar.sh
# already makes, repeated here so this file alone proves the golden case too.
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.wip.json")"
check "serial off: wip resume guard unchanged" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "serial off: no WAIT line ever printed" "WAIT: serial delivery" "$out"
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.serial-review.json")"
check "serial off: an In review item never triggers WAIT" "=> PICK: #1  FX-001: scaffold" "$out"
check_absent "serial off: no WAIT line for an In review item" "WAIT: serial delivery" "$out"

echo "== guard-board-move.sh (serialDelivery move guard, #272) =="

_serial_repo() { # sets T (fixture repo dir) with .claude/project.yaml (serialDelivery=<1>) + optional board-cache.json (arg2, "-" = none)
    T="$(mktemp -d)"
    ( cd "$T" && git init -q . && git commit -q --allow-empty -m init )
    mkdir -p "$T/.claude"
    cp "$FIX/valid.project.yaml" "$T/.claude/project.yaml"
    if [[ "${1:-1}" == "1" ]]; then
        printf '\nmethodology:\n    serialDelivery: true\n' >>"$T/.claude/project.yaml"
    fi
    if [[ "${2:-}" != "-" ]]; then
        printf '%s' "${2:-{\}}" >"$T/.claude/board-cache.json"
    fi
}

# --- (a) another task already In progress -> blocked, blocker named, override documented ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: blocks with the blocking issue named" "#5" "$out"
check "serial move guard: names the blocking status" "In progress" "$out"
check "serial move guard: mentions the override env var" "SERIAL_DELIVERY_OVERRIDE" "$out"
check "serial move guard: exits nonzero" "rc=2" "$out"
rm -rf "$T"

# --- (b) another task already In review -> also blocks ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In review"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: In review blocker also blocks" "#5" "$out"
check "serial move guard: In review blocker exits nonzero" "rc=2" "$out"
rm -rf "$T"

# --- (c) override env var allows the move through ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && SERIAL_DELIVERY_OVERRIDE=1 bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: SERIAL_DELIVERY_OVERRIDE=1 allows the move" "rc=0" "$out"
rm -rf "$T"

# --- (d) no blocker in the cache -> allowed ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "QA"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: no In progress/In review blocker -> allowed" "rc=0" "$out"
rm -rf "$T"

# --- (e) cache miss (file absent) -> fail OPEN with a warning, never wedges the loop ---
_serial_repo 1 -
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: cache miss fails open (exit 0)" "rc=0" "$out"
check "serial move guard: cache miss warns" "WARNING" "$out"
rm -rf "$T"

# --- (f) mode off -> guard never engages even with a blocker in the cache ---
_serial_repo 0 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: mode off allows the move" "rc=0" "$out"
check_absent "serial move guard: mode off never blocks" "BLOCKED" "$out"
rm -rf "$T"

# --- (g) moves to a non-"In progress" status are unaffected, even with a blocker ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"QA\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: non-'In progress' target status is unaffected" "rc=0" "$out"
rm -rf "$T"
