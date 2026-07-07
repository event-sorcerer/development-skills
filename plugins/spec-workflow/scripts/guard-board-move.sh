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
# Fail-closed exception: if shlex can't tokenize the command (e.g. an unbalanced
# quote) AND the raw text still contains both "board.sh" and "move", we can't
# prove it's safe, so we block with a distinct message rather than risk letting
# a real move through unparsed.
set -uo pipefail

RESULT="$(python3 -c '
import json, re, shlex, sys

REVIEW_STATUS = "in review"

def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())

try:
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    command = ""

try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    if "board.sh" in command and "move" in command:
        print("unparseable")
    else:
        print("allow")
    sys.exit(0)

blocked = False
for i, tok in enumerate(tokens):
    if tok.rsplit("/", 1)[-1] != "board.sh":
        continue
    if i + 3 >= len(tokens):
        continue
    subcmd = tokens[i + 1]
    status = tokens[i + 3]
    if subcmd == "move" and norm(status) == REVIEW_STATUS:
        blocked = True

print("review-move" if blocked else "allow")
' 2>/dev/null)" || exit 0

case "$RESULT" in
    allow) exit 0 ;;
    unparseable)
        echo "BLOCKED: could not safely parse this command to confirm it isn't a move to 'In review'. Simplify it (avoid nesting board.sh inside quotes/heredocs) and retry." >&2
        exit 2
        ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MARKER="$ROOT/.claude/gate-pass"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$MARKER" ]]; then
    echo "BLOCKED: no recorded gate pass. Run \`bash \"$HERE/gate.sh\"\` to green (it records the pass), then retry the move to 'In review'." >&2
    exit 2
fi
if [[ "$(cat "$MARKER")" != "$(bash "$HERE/tree-state.sh")" ]]; then
    echo "BLOCKED: the tree changed since the last recorded gate pass. Re-run \`bash \"$HERE/gate.sh\"\`, then retry the move to 'In review'." >&2
    exit 2
fi
exit 0
