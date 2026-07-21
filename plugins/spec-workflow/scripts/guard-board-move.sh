#!/usr/bin/env bash
# guard-board-move.sh — PreToolUse(Bash) hook: block `board.sh move <n> "In review"`
# unless gate.sh recorded a pass for the CURRENT tree state. Exit 2 = block (stderr
# goes back to the model); exit 0 = allow. Must stay fast — it runs on every Bash call.
#
# Parsing: the command string is tokenized with Python's stdlib shlex, then every
# `board.sh` argv token is located and its real argv[1] (subcommand) and argv[3]
# (target status) are read at their actual positions. Only an actual `move`
# invocation whose target status is the review-gate status can block; a status
# name appearing anywhere else — comment bodies, gh issue text, heredocs, other
# arguments — never trips the guard, and non-`move` subcommands always pass.
# Compound commands (`A && B`) are handled naturally: shlex still tokenizes the
# whole line, so the board.sh segment's argv is found regardless of what's
# before or after it.
#
# Shell-interpreter wrapping (`bash -c "board.sh move ..."`, `sh -c '...'`,
# an `env`-prefixed variant, or nested `bash -c 'bash -c "..."'`) would hide
# the real argv inside a single opaque token if we only scanned once — that
# was a silent gate bypass. So when a bash/sh/zsh/dash/ksh token is followed
# by a `-c`-ish flag (including combined clusters like `-lc`), the next token
# is treated as an inner command line and re-tokenized recursively (bounded
# depth; deeper nesting fails closed as unparseable, same as a raw unbalanced
# quote would).
#
# Fail-closed exception: if shlex can't tokenize a command/sub-command (e.g. an
# unbalanced quote) AND the raw text still contains both "board.sh" and "move",
# we can't prove it's safe, so we block with a distinct message rather than
# risk letting a real move through unparsed.
#
# #272 (methodology.serialDelivery, defense in depth): a `board.sh move <n>
# "In progress"` is ALSO intercepted below when the config has serialDelivery
# on, blocking it if the offline .claude/board-cache.json (issue #78 — no
# network call) shows another issue already In progress or In review.
# Deliberately fail OPEN (allow, with a stderr warning) when the cache is
# missing/unreadable: a cache-consistency problem must never wedge the build
# loop the way a real network outage would if this were gate-checked instead.
# SERIAL_DELIVERY_OVERRIDE=1 bypasses the block outright (documented escape
# hatch for an intentional manual override).
set -uo pipefail

RESULT="$(python3 -c '
import json, re, shlex, sys

REVIEW_STATUS = "in review"
PROGRESS_STATUS = "in progress"
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh"}
MAX_DEPTH = 5

def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())

def is_c_flag(tok):
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and len(tok) > 1
        and tok[1:].isalpha()
        and "c" in tok[1:]
    )

def evaluate(command, depth):
    if depth > MAX_DEPTH:
        return "unparseable"
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        if "board.sh" in command and "move" in command:
            return "unparseable"
        return "allow"

    i, n = 0, len(tokens)
    while i < n:
        base = tokens[i].rsplit("/", 1)[-1]
        if base in INTERPRETERS and i + 2 < n and is_c_flag(tokens[i + 1]):
            result = evaluate(tokens[i + 2], depth + 1)
            if result != "allow":
                return result
            i += 3
            continue
        if base == "board.sh" and i + 3 < n:
            subcmd, num, status = tokens[i + 1], tokens[i + 2], tokens[i + 3]
            if subcmd == "move" and norm(status) == REVIEW_STATUS:
                return "review-move"
            if subcmd == "move" and norm(status) == PROGRESS_STATUS:
                return "progress-move:" + num
        i += 1
    return "allow"

try:
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    command = ""

print(evaluate(command, 0))
' 2>/dev/null)" || exit 0

case "$RESULT" in
    allow) exit 0 ;;
    unparseable)
        echo "BLOCKED: could not safely parse this command to confirm it isn't a move to 'In review'. Simplify it (avoid nesting board.sh inside quotes/heredocs) and retry." >&2
        exit 2
        ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$RESULT" == progress-move:* ]]; then
    NUM="${RESULT#progress-move:}"
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    SERIAL="$(PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 -c '
import json, os, sys
import config as C

root, num = sys.argv[1], sys.argv[2]
cfg = C.load_config(root=root, warn=False) or {}
if not bool((cfg.get("methodology") or {}).get("serialDelivery", False)):
    print("allow")
    sys.exit(0)
if os.environ.get("SERIAL_DELIVERY_OVERRIDE") == "1":
    print("override")
    sys.exit(0)

cache_path = os.environ.get("BOARD_CACHE_FILE") or os.path.join(root, ".claude", "board-cache.json")
try:
    with open(cache_path) as f:
        cache = json.load(f)
except Exception:
    print("fail-open")
    sys.exit(0)

boards = cfg.get("boards") or []
flow = (boards[0].get("statusFlow") if boards else None) or ["Backlog", "In progress", "In review"]
blocking = set(flow[1:3])

blockers = [
    (n, e.get("status", ""))
    for n, e in cache.items()
    if n != num and isinstance(e, dict) and e.get("status", "") in blocking
]
if blockers:
    print("block:" + ";".join(f"#{n} is {s}" for n, s in blockers))
else:
    print("allow")
' "$ROOT" "$NUM" 2>/dev/null)" || SERIAL="fail-open"

    case "$SERIAL" in
        allow|override) exit 0 ;;
        fail-open)
            echo "WARNING: serialDelivery is on but .claude/board-cache.json is missing/unreadable -- cannot confirm no other task is In progress/In review. Allowing the move (fail-open: an offline-cache problem must never wedge the loop)." >&2
            exit 0
            ;;
        block:*)
            echo "BLOCKED: serial delivery mode (methodology.serialDelivery) — ${SERIAL#block:} — merge it before moving #$NUM to In progress. Override with SERIAL_DELIVERY_OVERRIDE=1 if this is intentional." >&2
            exit 2
            ;;
        *)
            exit 0 ;;
    esac
fi

# CDX-030: delegate to the shared, hook-independent preflight -- single
# source of truth for "is the gate green for this tree" (docs/design/cdx-E3.md
# Decisions). Defense in depth: this hook still intercepts before board.sh
# even starts, but the actual marker+fingerprint check lives in one place.
bash "$HERE/gate-preflight.sh"
exit $?
