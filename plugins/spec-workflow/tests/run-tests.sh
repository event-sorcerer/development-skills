#!/usr/bin/env bash
# run-tests.sh — hermetic tests for the spec-workflow plugin (no gh/network needed).
# Used by CI and runnable locally: bash plugins/spec-workflow/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
FIX="$HERE/fixtures"
fails=0

check() { # name  expected-substring  actual-output
    if grep -qF "$2" <<<"$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected to contain: $2"
        echo "     got: $(head -3 <<<"$3")"
        fails=$((fails + 1))
    fi
}

echo "== syntax =="
for f in "$PLUGIN"/scripts/*.sh "$HERE"/run-tests.sh; do
    if bash -n "$f"; then echo "ok   bash -n $(basename "$f")"; else echo "FAIL bash -n $f"; fails=$((fails + 1)); fi
done
if python3 -m py_compile "$PLUGIN/scripts/validate-config.py"; then
    echo "ok   py_compile validate-config.py"
else
    echo "FAIL py_compile"; fails=$((fails + 1))
fi

echo "== validate-config =="
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.json")"
check "valid fixture passes" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/broken.project.json" || true)"
check "broken: schemaVersion" "schemaVersion must be 1" "$out"
check "broken: statusFlow option" "'Done' has no matching status option id" "$out"
check "broken: empty priority options" "priority.options is empty" "$out"
check "broken: bad taskPrefix" "must be alphanumeric starting with a letter" "$out"
check "broken: unknown board ref" "does not match any boards[].id" "$out"
check "broken: overlapping ranges" "overlaps epic" "$out"
check "broken: unknown blockedBy epic" "unknown epic 'EZ'" "$out"
check "broken: bad untilStatus" "not in statusFlow" "$out"
check "broken: missing gate" "missing required key 'gate'" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/templates/project.example.json" || true)"
check "template rejected (placeholders)" "template placeholder" "$out"

echo "== preflight =="
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q . )
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "no config -> setup-project" "PREFLIGHT FAIL: no .claude/project.json" "$out"
mkdir -p "$T/.claude" && cp "$FIX/valid.project.json" "$T/.claude/project.json"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "missing spec file -> craft-spec" "spec file(s) missing: SPEC.md" "$out"
touch "$T/SPEC.md"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "config + spec ok" "preflight ok: config + 1 spec(s) present" "$out"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh")"
check "config-only ok" "preflight ok: config present" "$out"

echo
if [[ $fails -gt 0 ]]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
