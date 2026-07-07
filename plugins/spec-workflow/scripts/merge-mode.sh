#!/usr/bin/env bash
# merge-mode.sh — show or configure auto-merge for this project (.claude/project.yaml).
#   merge-mode.sh                 # or: status -> autoMerge / reviewer models / mergeMethod / reviewerTokenEnv
#   merge-mode.sh on|off          # sets methodology.autoMerge
#   merge-mode.sh model <model>[,<model>...]   # sets delegation.identities.reviewer.models (allowed set)
#   merge-mode.sh method <squash|merge|rebase>  # sets methodology.mergeMethod
#   merge-mode.sh preauth          # is `gh pr merge`/`gh pr review` pre-authorized in .claude/settings*.json?
#   merge-mode.sh preauth-snippet  # print the permissions block that would pre-authorize them
# Unlike ui-mode (local flag), auto-merge is a project-wide, versioned config
# change: merging without a human is something every clone must agree on.
# Reads via the shared loader (yaml or legacy json); writes back in the file's own format.
#
# `preauth` is a heuristic advisory probe: it only inspects THIS repo's
# .claude/settings.json and .claude/settings.local.json. Allow-rules granted
# elsewhere (user or global settings) are invisible to it — a "missing"
# verdict here does not guarantee the harness will actually deny the merge;
# that is only discovered at run time. It never edits any file itself.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# preauth / preauth-snippet only inspect/print settings.json content — no
# project config required, so they run before the CONFIG guard below.
if [[ "${1:-}" == "preauth" ]]; then
    allow_rules() { # <path> — one allow-rule string per line, silently empty if file is absent/unparsable
        [[ -f "$1" ]] || return 0
        python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for rule in (data.get("permissions") or {}).get("allow") or []:
    print(rule)
' "$1"
    }
    ALLOW="$(allow_rules "$ROOT/.claude/settings.json"; allow_rules "$ROOT/.claude/settings.local.json")"
    missing=""
    for rule in "Bash(gh pr merge:*)" "Bash(gh pr review:*)"; do
        if ! grep -qxF "$rule" <<<"$ALLOW"; then
            [[ -n "$missing" ]] && missing="$missing, $rule" || missing="$rule"
        fi
    done
    if [[ -z "$missing" ]]; then
        echo "preauth: ok"
        exit 0
    else
        echo "preauth: missing $missing"
        exit 1
    fi
fi
if [[ "${1:-}" == "preauth-snippet" ]]; then
    cat <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(gh pr merge:*)",
      "Bash(gh pr review:*)",
      "Bash(gh pr comment:*)",
      "Bash(git push:*)"
    ]
  }
}
EOF
    exit 0
fi

CONFIG="$(PYTHONPATH="$HERE" python3 "$HERE/config.py" "$ROOT" path)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo "ERROR: no .claude/project.yaml (or legacy .json) — run the setup-project skill first" >&2; exit 1; }

# Config reads + surgical writes both go through the shared loader (config.py).
jset() { python3 "$HERE/config.py" "$ROOT" set "$1" "$2"; }  # jset <dot.path> <json-value>
jget() { python3 "$HERE/config.py" "$ROOT" get "$1"; }

case "${1:-status}" in
    status)
        am="$(jget methodology.autoMerge)"
        models="$(jget delegation.identities.reviewer.models)"
        method="$(jget methodology.mergeMethod)"
        tokenenv="$(jget delegation.reviewerTokenEnv)"
        [[ "$am" == "true" ]] && echo "autoMerge: ON (agent reviews, approves, merges — no human approval)" \
                              || echo "autoMerge: OFF (a human approves and merges every PR)"
        echo "reviewer models: ${models:-[\"claude-sonnet-5\", \"claude-sonnet-5[1m]\"] (default)}"
        echo "mergeMethod: ${method:-squash (default)}"
        if [[ -n "$tokenenv" ]]; then
            if [[ -n "${!tokenenv:-}" ]]; then echo "reviewerTokenEnv: $tokenenv (set in env — approvals appear as a distinct GitHub account)"
            else echo "reviewerTokenEnv: $tokenenv (NOT set in this env — approvals fall back to review comments)"; fi
        else
            echo "reviewerTokenEnv: unset (approvals are posted as review comments; branch protection requiring approvals will block)"
        fi ;;
    on)  jset methodology.autoMerge true;  echo "autoMerge: ON (methodology.autoMerge=true in $CONFIG — commit this change)" ;;
    off) jset methodology.autoMerge false; echo "autoMerge: OFF (methodology.autoMerge=false in $CONFIG — commit this change)" ;;
    model)
        [[ -n "${2:-}" ]] || { echo "usage: merge-mode.sh model <model>[,<model>...]" >&2; exit 1; }
        arr="$(python3 -c 'import json,sys; print(json.dumps([m.strip() for m in sys.argv[1].split(",") if m.strip()]))' "$2")"
        jset delegation.identities.reviewer.models "$arr"
        echo "reviewer models: $2 (delegation.identities.reviewer.models in $CONFIG — commit this change)" ;;
    method)
        case "${2:-}" in squash|merge|rebase) ;; *) echo "usage: merge-mode.sh method <squash|merge|rebase>" >&2; exit 1 ;; esac
        jset methodology.mergeMethod "\"$2\""
        echo "mergeMethod: $2 (methodology.mergeMethod in $CONFIG — commit this change)" ;;
    *) echo "usage: merge-mode.sh [status|on|off|model <model>[,<model>...]|method <squash|merge|rebase>|preauth|preauth-snippet]" >&2; exit 1 ;;
esac
