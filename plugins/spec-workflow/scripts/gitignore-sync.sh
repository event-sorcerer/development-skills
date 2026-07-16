#!/usr/bin/env bash
# gitignore-sync.sh — write the plugin's `ignore`-policy paths (from
# scripts/local-state.manifest, via lib/local-state.sh) into a target
# .gitignore as a managed block (SPEC-MEMORY.md §7.2/§7.2.1):
#
#   # >>> spec-workflow managed
#   <ignore paths, one per line, in manifest order>
#   # <<< spec-workflow managed
#
# Replaces ONLY the block's interior if the markers already exist; appends the
# block (with markers) if absent; NEVER touches any line outside the markers.
# Warns (path + matching rule) when a `track`-policy path is already ignored by
# some OTHER, non-managed rule in the target. `--dry-run` prints the unified
# diff and writes nothing. Idempotent: a second run is a no-op.
#
# Usage: gitignore-sync.sh [--dry-run] [target]   (target defaults to .gitignore)
#
# bash 3.2-compatible (no bash-4-only constructs).
set -uo pipefail

GS_HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=plugins/spec-workflow/scripts/lib/local-state.sh
. "$GS_HERE/lib/local-state.sh"

GS_START="# >>> spec-workflow managed"
GS_END="# <<< spec-workflow managed"

gs_usage() {
    cat <<EOF
usage: gitignore-sync.sh [--dry-run] [target]
  Sync the spec-workflow managed block of ignore paths into <target>
  (default: .gitignore). --dry-run prints the diff without writing.
EOF
}

# _gs_rule_matches <rule> <path> — rc 0 if the gitignore <rule> would ignore
# <path>. Pragmatic subset of gitignore semantics: skips comments/blanks/
# negations; supports an anchored (slash-bearing) rule as an exact or
# ancestor-directory match, an unanchored rule as a match on any path
# component, and shell globs in either form.
_gs_rule_matches() {
    local rule="$1" p="$2"
    case "$rule" in ''|'#'*|'!'*) return 1 ;; esac
    rule="${rule%/}"; rule="${rule#/}"
    p="${p%/}"
    [ -n "$rule" ] || return 1
    case "$rule" in
        */*)
            [ "$p" = "$rule" ] && return 0
            # shellcheck disable=SC2254  # unquoted $rule is intentional: honor gitignore globs
            case "$p" in "$rule"/* | $rule | $rule/*) return 0 ;; esac
            ;;
        *)
            [ "$p" = "$rule" ] && return 0
            # shellcheck disable=SC2254  # unquoted $rule is intentional: honor gitignore globs
            case "$p" in "$rule"/* | */"$rule" | */"$rule"/* | $rule | $rule/* | */$rule | */$rule/*) return 0 ;; esac
            ;;
    esac
    return 1
}

gs_dry_run=0
gs_target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) gs_dry_run=1 ;;
        -h|--help) gs_usage; exit 0 ;;
        -*) echo "gitignore-sync: unknown option: $1" >&2; gs_usage >&2; exit 2 ;;
        *)
            if [ -z "$gs_target" ]; then gs_target="$1"
            else echo "gitignore-sync: unexpected extra argument: $1" >&2; exit 2; fi
            ;;
    esac
    shift
done
[ -n "$gs_target" ] || gs_target=".gitignore"

gs_ignore="$(spec_workflow_local_state_paths ignore)" || {
    echo "gitignore-sync: cannot read ignore paths from manifest" >&2; exit 1; }
gs_track="$(spec_workflow_local_state_paths track)" || {
    echo "gitignore-sync: cannot read track paths from manifest" >&2; exit 1; }

# Fresh managed block (no trailing newline; added when composing the file).
gs_block="$GS_START
$gs_ignore
$GS_END"

# Split the existing target into the content before the block and after it,
# recording whether a block was present. Everything outside the markers is
# preserved byte-for-byte (for newline-terminated files, the norm).
gs_before=""
gs_after=""
gs_have_block=0
gs_in_block=0
if [ -f "$gs_target" ]; then
    while IFS= read -r gs_line || [ -n "$gs_line" ]; do
        if [ "$gs_in_block" -eq 1 ]; then
            [ "$gs_line" = "$GS_END" ] && gs_in_block=0
            continue
        fi
        if [ "$gs_line" = "$GS_START" ]; then
            gs_in_block=1
            gs_have_block=1
            continue
        fi
        if [ "$gs_have_block" -eq 0 ]; then
            gs_before="$gs_before$gs_line
"
        else
            gs_after="$gs_after$gs_line
"
        fi
    done < "$gs_target"
fi

if [ "$gs_have_block" -eq 1 ]; then
    gs_new="$gs_before$gs_block
$gs_after"
else
    gs_new="$gs_before$gs_block
"
fi

# §7.2.1: warn (to stderr) for any track path already ignored by a non-managed
# rule — i.e. any line outside the markers (gs_before + gs_after).
gs_nonmanaged="$gs_before$gs_after"
while IFS= read -r gs_tp; do
    [ -n "$gs_tp" ] || continue
    while IFS= read -r gs_rule; do
        [ -n "$gs_rule" ] || continue
        if _gs_rule_matches "$gs_rule" "$gs_tp"; then
            printf 'gitignore-sync: WARNING: track path %s is ignored by non-managed rule %s\n' \
                "$gs_tp" "$gs_rule" >&2
            break
        fi
    done <<EOF
$gs_nonmanaged
EOF
done <<EOF
$gs_track
EOF

gs_tmp="$(mktemp)" || { echo "gitignore-sync: mktemp failed" >&2; exit 1; }
printf '%s' "$gs_new" > "$gs_tmp"

if [ "$gs_dry_run" -eq 1 ]; then
    gs_old="$gs_target"
    [ -f "$gs_old" ] || gs_old=/dev/null
    diff -u "$gs_old" "$gs_tmp" || true
    rm -f "$gs_tmp"
    exit 0
fi

mv "$gs_tmp" "$gs_target"
exit 0
