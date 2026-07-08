#!/usr/bin/env bash
# section-ui-hub.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
echo "== ui-hub (lifecycle on a scratch port) =="
_hubtmp="$(mktemp -d)"
export UI_HUB_STATE="$_hubtmp/hub"
HUB="$PLUGIN/scripts/ui-hub.py"
lifecycle_start "hub starts" UI_HUB_PORT 'python3 "$HUB" start'
echo '<h1>d</h1>' > "$UI_HUB_STATE/d.html"
out="$(python3 "$HUB" ask d1 "T" "$UI_HUB_STATE/d.html" --blocking)"; check "hub ask" "asked 'd1'" "$out"
out="$(curl -sf "http://127.0.0.1:$UI_HUB_PORT/api/state")";    check "hub state has pending" '"id": "d1"' "$out"
out="$(curl -sf -X POST "http://127.0.0.1:$UI_HUB_PORT/api/answer" -H 'Content-Type: application/json' -d '{"id":"d1","selection":"- Use: Option A"}')"
check "hub answer accepted" '"ok": true' "$out"
out="$(python3 "$HUB" answers --consume)";            check "hub answer collected" "Use: Option A" "$out"
out="$(python3 "$HUB" answers)";                      check_absent "hub consume archived it" "d1" "$out"

# #55: start must FAIL loudly when the port it's asked to bind is already
# held by someone else -- otherwise a caller whose own server never came
# up keeps reporting RUNNING and its clients silently talk to whichever
# process DID bind that port (see _rand_port's check-then-bind window:
# two concurrent callers can both probe the same free port microseconds
# apart and both pick it), so answers/consumes land in the wrong state
# dir instead of failing visibly. Force the collision directly -- this
# suite's own hub above is still bound to $UI_HUB_PORT -- rather than
# rely on timing luck to hit the same race.
_collide_dir="$(mktemp -d)/hub"
out="$(UI_HUB_STATE="$_collide_dir" python3 "$HUB" start --port "$UI_HUB_PORT" 2>&1)"
check_rc "hub start reports failure on an already-bound port" 1 "$?"
rm -rf "$(dirname "$_collide_dir")"

python3 "$HUB" stop >/dev/null
unset UI_HUB_STATE UI_HUB_PORT

