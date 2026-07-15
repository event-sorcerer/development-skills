#!/usr/bin/env bash
# section-changelog.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== changelog.sh: type-bucket grouping (#165) =="
CGD="$(mktemp -d)"
(
    cd "$CGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
ROOTSHA="$(cd "$CGD" && git rev-parse HEAD)"
(
    cd "$CGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: add widget (#10)"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: broken thing"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "docs: update readme"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "refactor: tidy internals"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "test: add coverage"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "retro: mint note"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "not conventional subject"
) >/dev/null 2>&1

out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" --to HEAD 2>&1)"
check "changelog.sh: Feat bucket header present" "### Feat" "$out"
check "changelog.sh: Feat bullet keeps PR reference" "- add widget (#10)" "$out"
check "changelog.sh: Fix bucket header present" "### Fix" "$out"
check "changelog.sh: Fix bullet text" "- broken thing" "$out"
check "changelog.sh: Docs bucket header present" "### Docs" "$out"
check "changelog.sh: Docs bullet text" "- update readme" "$out"
check "changelog.sh: Refactor bucket header present" "### Refactor" "$out"
check "changelog.sh: Refactor bullet text" "- tidy internals" "$out"
check "changelog.sh: Test bucket header present" "### Test" "$out"
check "changelog.sh: Test bullet text" "- add coverage" "$out"
check "changelog.sh: Retro bucket header present" "### Retro" "$out"
check "changelog.sh: Retro bullet text" "- mint note" "$out"
check "changelog.sh: Other bucket header present" "### Other" "$out"
check "changelog.sh: Other bullet keeps full subject" "- not conventional subject" "$out"
check_absent "changelog.sh: unused Chore bucket header not printed" "### Chore" "$out"

echo "== changelog.sh: --from/--to ref selection (#165) =="
MIDSHA="$(cd "$CGD" && git log --format=%H --grep="^fix: broken thing$" -1)"
out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" --to "$MIDSHA" 2>&1)"
check "changelog.sh: --to restricts range, includes commits up to --to" "- broken thing" "$out"
check_absent "changelog.sh: --to restricts range, excludes commits after --to" "- update readme" "$out"
check "changelog.sh: heading uses literal from/to refs" "## $ROOTSHA..$MIDSHA" "$out"

echo "== changelog.sh: Unreleased heading when --to defaults to untagged HEAD (#165) =="
out="$(cd "$CGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$ROOTSHA" 2>&1)"
check "changelog.sh: no tag at HEAD -> Unreleased heading" "## Unreleased" "$out"

rm -rf "$CGD"

echo "== changelog.sh: default --from resolves the last spec-workflow--v* tag (#165) =="
TGD="$(mktemp -d)"
(
    cd "$TGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
    git tag spec-workflow--v1.0.0
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: after tag one"
    git tag spec-workflow--v1.1.0
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: after tag two"
    git tag other-nonmatching-tag
) >/dev/null 2>&1
out="$(cd "$TGD" && bash "$PLUGIN/scripts/changelog.sh" 2>&1)"
check "changelog.sh: default --from resolves most recent tag (heading)" "## spec-workflow--v1.1.0..HEAD" "$out"
check "changelog.sh: default --from excludes commits before the resolved tag" "- after tag two" "$out"
check_absent "changelog.sh: default --from excludes commits before the resolved tag (negative)" "- after tag one" "$out"
rm -rf "$TGD"

echo "== changelog.sh: default --from falls back to the first commit when no tag exists (#165) =="
NGD="$(mktemp -d)"
(
    cd "$NGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: root"
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: only feature"
    git tag v-marker-not-matching-prefix
) >/dev/null 2>&1
FIRSTSHA="$(cd "$NGD" && git rev-list --max-parents=0 HEAD)"
out="$(cd "$NGD" && bash "$PLUGIN/scripts/changelog.sh" 2>&1)"
check "changelog.sh: no-tag fallback resolves the first commit as --from" "## $FIRSTSHA..HEAD" "$out"
check "changelog.sh: no-tag fallback includes commits after the root" "- only feature" "$out"
rm -rf "$NGD"

echo "== changelog.sh: --write prepends to a fresh file (#165) =="
WGD="$(mktemp -d)"
(
    cd "$WGD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
WROOTSHA="$(cd "$WGD" && git rev-parse HEAD)"
(
    cd "$WGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: brand new file feature"
) >/dev/null 2>&1
FRESH="$WGD/CHANGELOG.md"
(cd "$WGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$WROOTSHA" --write "$FRESH") >/dev/null 2>&1
check_rc "changelog.sh: --write on a fresh file exits 0" 0 $?
freshbody="$(cat "$FRESH" 2>/dev/null)"
check "changelog.sh: --write creates a # Changelog H1 for a fresh file" "# Changelog" "$freshbody"
check "changelog.sh: --write on a fresh file includes the new section" "- brand new file feature" "$freshbody"

echo "== changelog.sh: --write prepends to an existing file, preserving old content (#165) =="
printf '# Changelog\n\n## old-section\n### Fix\n- an old fix (abc1234)\n' > "$FRESH"
(
    cd "$WGD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: newer fix for the log"
) >/dev/null 2>&1
NEWFROM="$(cd "$WGD" && git log --format=%H --grep="^feat: brand new file feature$" -1)"
(cd "$WGD" && bash "$PLUGIN/scripts/changelog.sh" --from "$NEWFROM" --write "$FRESH") >/dev/null 2>&1
check_rc "changelog.sh: --write on an existing file exits 0" 0 $?
existbody="$(cat "$FRESH" 2>/dev/null)"
check "changelog.sh: --write prepends the new section" "- newer fix for the log" "$existbody"
check "changelog.sh: --write preserves the old section below" "## old-section" "$existbody"
check "changelog.sh: --write preserves old bullet content" "- an old fix (abc1234)" "$existbody"
newpos=$(grep -n "newer fix for the log" "$FRESH" | head -1 | cut -d: -f1)
oldpos=$(grep -n "old-section" "$FRESH" | head -1 | cut -d: -f1)
if [[ "$newpos" -lt "$oldpos" ]]; then cmp_rc=0; else cmp_rc=1; fi
check_rc "changelog.sh: --write new section appears before old section" 0 "$cmp_rc"

echo "== changelog.sh: --write stays idempotent across consecutive real writes (#165) =="
IDD="$(mktemp -d)"
(
    cd "$IDD" || exit 1
    git init -q
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "chore: init"
) >/dev/null 2>&1
IDROOT="$(cd "$IDD" && git rev-parse HEAD)"
(
    cd "$IDD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "feat: first feature"
) >/dev/null 2>&1
IDFIRST="$(cd "$IDD" && git rev-parse HEAD)"
IDFILE="$IDD/CHANGELOG.md"
(cd "$IDD" && bash "$PLUGIN/scripts/changelog.sh" --from "$IDROOT" --write "$IDFILE") >/dev/null 2>&1
(
    cd "$IDD" || exit 1
    git -c user.name=t -c user.email=t@e.com commit -q --allow-empty -m "fix: second fix"
) >/dev/null 2>&1
(cd "$IDD" && bash "$PLUGIN/scripts/changelog.sh" --from "$IDFIRST" --write "$IDFILE") >/dev/null 2>&1
idbody="$(cat "$IDFILE" 2>/dev/null)"
idfirstline="$(head -1 "$IDFILE" 2>/dev/null)"
idh1count="$(grep -cFx '# Changelog' "$IDFILE" 2>/dev/null)"
check "changelog.sh: --write second write keeps # Changelog as the very first line" "# Changelog" "$idfirstline"
check "changelog.sh: --write second write keeps exactly one H1 (count)" "1" "$idh1count"
check "changelog.sh: --write second write includes the newest section" "- second fix" "$idbody"
check "changelog.sh: --write second write still includes the first write's section" "- first feature" "$idbody"
rm -rf "$IDD"

rm -rf "$WGD"
