#!/usr/bin/env bash
# board-queue.sh — rate-limit resilience for board.sh (issue #77 / #84).
#
# Sourced by board.sh AFTER the per-board vars (OWNER/REPO/PN/PID/*_FIELD/
# FIRST_STATUS) are resolved and item_id()/opt_id() are defined — every
# function below depends on those. Not meant to be executed directly.
#
# Model: a mutating op (move/prio/est/item-add) that hits a GitHub rate limit
# is appended to a durable local queue (QUEUE_FILE, one JSON object per line)
# instead of failing the caller. `board.sh flush` (and every board-READING
# command, automatically) replays the queue in order once quota returns.
# Replaying a `move` first checks the item's current status and skips if the
# target already holds (SPEC: prevents a stale queued move from regressing a
# status a newer, already-applied move already advanced past). If the limit
# re-trips mid-replay, the remainder (current op + everything after it) is
# written back to QUEUE_FILE verbatim and flush returns success — the loop
# keeps going, nothing is lost, nothing double-applies.
set -uo pipefail

QUEUE_FILE="${BOARD_QUEUE_FILE:-$ROOT/.claude/board-queue.jsonl}"

# Mutual exclusion for flush (#92): a bash-3.2-portable mutex -- macOS bash
# has no flock builtin, but mkdir is atomic on every POSIX filesystem, so a
# lockdir next to the queue file is the portable equivalent. A stale lock
# (older than QUEUE_LOCK_TTL, mtime-based) is broken with a warning so a
# flusher that crashed mid-flush can't wedge the queue forever.
QUEUE_LOCK_DIR="$(dirname "$QUEUE_FILE")/board-queue.lock"
QUEUE_LOCK_TTL="${BOARD_QUEUE_LOCK_TTL:-600}"  # seconds

# _rate_limited <captured-stderr-or-combined-output> -> 0 if it looks like a
# GitHub rate-limit response. Two layers:
#  1. Fast path — case-insensitive "rate limit" substring (REST "API rate
#     limit exceeded", GraphQL "API rate limit exceeded (RATE_LIMITED)", a
#     secondary rate limit): every TEXT-VISIBLE variant we've seen contains
#     that phrase.
#  2. Probe fallback (#90) — gh sometimes MASKS GraphQL exhaustion as an
#     unrelated error (e.g. "unknown owner type", no "rate limit" text
#     anywhere: live evidence, #90). When the fast path misses, probe the
#     REST rate_limit endpoint (works even while GraphQL itself is
#     exhausted) and treat remaining==0 on the graphql resource as ground
#     truth. remaining>0 means the error is real — surface it verbatim.
_rate_limited() {
    grep -qi "rate limit" <<<"$1" && return 0
    _graphql_remaining_is_zero
}

# _graphql_remaining_is_zero -> 0 (true) iff `gh api rate_limit`'s graphql
# resource reports remaining==0. A probe failure (gh itself erroring, e.g.
# also rate-limited on REST, or unparseable JSON) is NOT treated as
# rate-limited — that would mask a real error behind a silent queue.
_graphql_remaining_is_zero() {
    local raw remaining
    raw="$(gh api rate_limit 2>/dev/null)" || return 1
    remaining="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.argv[1])["resources"]["graphql"]["remaining"])
except Exception:
    print(-1)
' "$raw")"
    [[ "$remaining" == "0" ]]
}

# _rate_limit_reset_human -> ISO-8601 UTC reset time from the REST rate_limit
# endpoint. Prefers the graphql resource's reset (the counter that's
# actually exhausted when GraphQL masks its own errors), falling back to
# the top-level `rate` alias if `resources.graphql` is absent -- both are
# real shapes of gh's response.
_rate_limit_reset_human() {
    local raw
    raw="$(gh api rate_limit 2>/dev/null)" || { echo "unknown"; return; }
    python3 -c '
import json, sys, datetime
try:
    d = json.loads(sys.argv[1])
    try:
        ts = d["resources"]["graphql"]["reset"]
    except Exception:
        ts = d["rate"]["reset"]
    print(datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    print("unknown")
' "$raw"
}

# queue_append <op> <key=value>... -> appends one JSON line (op + given keys
# + a ts) to QUEUE_FILE. Values are passed as argv (never string-concatenated
# into JSON by hand) so titles/statuses with quotes/spaces stay safe.
queue_append() {
    local op="$1"; shift
    mkdir -p "$(dirname "$QUEUE_FILE")"
    python3 -c '
import json, sys, time
op = sys.argv[1]
d = {"op": op}
for pair in sys.argv[2:]:
    k, _, v = pair.partition("=")
    d[k] = v
d["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
print(json.dumps(d))
' "$op" "$@" >>"$QUEUE_FILE"
}

_jf() { # <json-line> <field> -> value ("" if absent)
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"
}

# _flush_sync <tag>: test-only synchronization point, a no-op in production.
# Two conditions must BOTH hold before this does anything (review #92
# round 2 -- an unbounded wait here, misfired outside a test, would hang
# every flush forever, silently):
#   1. BOARD_QUEUE_TEST_SYNC names a directory that exists.
#   2. That directory contains an explicit opt-in sentinel file,
#      .board-queue-test-sync -- a stray/leaked env var pointing at some
#      unrelated real directory must not activate this hook.
# When active: touches <dir>/<tag>.ready then blocks (poll) until
# <dir>/<tag>.go appears, capped at BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS
# iterations of a 0.02s sleep (default 1500 =~ 30s) -- past the cap it
# gives up loudly and proceeds, rather than hanging forever. Lets
# concurrency tests pin the exact interleaving of overlapping flush calls
# instead of racing on wall-clock sleeps (see section-board-queue.sh, #92).
_flush_sync() {
    local tag="$1" dir="${BOARD_QUEUE_TEST_SYNC:-}" waited=0 cap="${BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS:-1500}"
    [[ -n "$dir" && -d "$dir" && -f "$dir/.board-queue-test-sync" ]] || return 0
    : >"$dir/$tag.ready"
    while [[ ! -f "$dir/$tag.go" ]]; do
        sleep 0.02
        waited=$((waited + 1))
        if [[ "$waited" -ge "$cap" ]]; then
            echo "flush: WARNING _flush_sync($tag) gave up after $waited iterations waiting for $dir/$tag.go -- proceeding without the test hook" >&2
            return 0
        fi
    done
}

# _item_id_rl <issue#> -> prints the project item id to stdout if found.
# Cache-first (issue #78, .claude/board-cache.json, see board.sh): a cache
# HIT costs zero gh calls. A cache MISS costs exactly one gh call -- a full
# item-list, whose result refreshes the WHOLE cache as a side effect, so
# every other issue's lookup this session is then free too -- instead of a
# blind full re-list per lookup. Unlike item_id() (board.sh) this does NOT
# swallow the underlying gh error on a miss's fetch — it distinguishes "no
# such item" from "the lookup itself failed rate-limited (incl. masked,
# #90)" so callers can queue instead of misreporting a masked rate limit as
# "bad issue# or status" (#90).
# Return: 0 = found (id on stdout), 1 = real miss (gh call succeeded, no
# such item/issue), 2 = the gh call failed and looks rate-limited.
_item_id_rl() {
    local num="$1" hit out err rc id
    hit="$(_cache_get "$num")" && { cut -f1 <<<"$hit"; return 0; }
    err="$(mktemp)"
    out="$(gh_project_items_json "$PN" "$OWNER" 2>"$err")"; rc=$?
    if [[ $rc -ne 0 ]]; then
        if _rate_limited "$(cat "$err")"; then
            rm -f "$err"
            return 2
        fi
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    # The cache refresh below is a pure side effect (best-effort write, see
    # board.sh) -- THIS call's correctness is decided by parsing $out
    # directly, so a write failure (e.g. read-only .claude/) can never turn a
    # real hit into a false miss.
    printf '%s' "$out" | _cache_refresh_from_items
    id="$(python3 -c '
import json, sys
try:
    n = int(sys.argv[1])
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in data.get("items", []):
    if (it.get("content") or {}).get("number") == n:
        print(it["id"])
        break
' "$num" <<<"$out")"
    if [[ -n "$id" ]]; then
        printf '%s' "$id"
        return 0
    fi
    return 1
}

# _poll_visible <issue#> -> prints the item id on stdout if it becomes
# visible within the cap. Cap: 2 attempts with backoff (0.3s, 0.6s) -- issue
# #78, down from the pre-#77 value of 10 and #77's own value of 3: each
# attempt is a cache-aware lookup (_item_id_rl), so a hit is free and even a
# miss costs one full-board call, not a blind re-list. Return: 0 = found (id
# on stdout), 1 = still not visible after the cap (caller defers to the
# queue), 2 = a lookup attempt looked rate-limited (caller defers to the
# queue too -- further polling would just burn quota for nothing).
_poll_visible() {
    local num="$1" delays=(0.3 0.6) i id rc
    for i in 0 1; do
        id="$(_item_id_rl "$num")"; rc=$?
        if [[ $rc -eq 2 ]]; then return 2; fi
        if [[ -n "$id" ]]; then printf '%s' "$id"; return 0; fi
        sleep "${delays[$i]}"
    done
    return 1
}

# _current_status: DELIBERATELY NOT cache-first, unlike _item_id_rl. This is
# flush's stale-move-regression guard (#92): it must see the TRUE remote
# status, because the whole reason a move is sitting in the queue is that it
# never actually applied -- the cache can only reflect mutations THIS script
# applied, never an out-of-band remote change (or a still-pending queued
# one), so trusting it here would silently defeat the guard. It still
# refreshes the whole cache as a side effect (the fetch happens either way),
# so _item_id_rl calls made right after this one are free.
_current_status() { # issue# -> status string ("" if not found / lookup failed)
    local num="$1" out
    out="$(gh_project_items_json "$PN" "$OWNER" 2>/dev/null)" || { printf ''; return 0; }
    # Side-effect cache refresh (best-effort write, see board.sh); THIS call's
    # answer is parsed straight from $out, same reasoning as _item_id_rl.
    printf '%s' "$out" | _cache_refresh_from_items
    python3 -c '
import json, sys
try:
    n = int(sys.argv[1])
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in data.get("items", []):
    if (it.get("content") or {}).get("number") == n:
        print(it.get("status") or "")
        break
' "$num" <<<"$out"
}

# _mutate_field <issue#> <field-id> <edit-flag> <value> <new-status-or-empty>
# -> shared by _do_move/_do_prio/_do_est: resolves the item id (cache-first),
# applies the edit, and on success updates the cache (issue #78 acceptance
# criterion 5 -- "every mutation updates the cached entry"). <new-status> is
# the status to cache iff this edit changes Status (move); empty leaves the
# cached status untouched (prio/est don't change it).
# If the edit itself fails for a reason that ISN'T a rate limit, the cached
# id may simply be stale (the item was removed from the board, the cache
# predates a board change, etc.) -- drop it and re-resolve ONCE (a fresh
# full-board lookup, bypassing the now-empty cache slot) before giving up,
# per criterion 5 ("a mutation rejected because remote state changed drops
# the entry and re-resolves once").
# Return: 0 = applied, 1 = real failure (message already printed), 2 =
# rate-limited, 3 = no such item (caller prints the specific message).
_mutate_field() {
    local num="$1" field="$2" flag="$3" value="$4" new_status="$5" id out rc id2
    id="$(_item_id_rl "$num")"; rc=$?
    [[ $rc -eq 2 ]] && return 2
    [[ -z "$id" ]] && return 3
    out="$(gh project item-edit --id "$id" --project-id "$PID" --field-id "$field" "$flag" "$value" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _cache_put "$num" "$id" "$new_status"
        return 0
    fi
    if _rate_limited "$out"; then
        return 2
    fi
    _cache_drop "$num"
    id2="$(_item_id_rl "$num")"; rc=$?
    if [[ $rc -eq 2 ]]; then return 2; fi
    if [[ -z "$id2" || "$id2" == "$id" ]]; then
        echo "$out" >&2
        return 1
    fi
    out="$(gh project item-edit --id "$id2" --project-id "$PID" --field-id "$field" "$flag" "$value" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _cache_put "$num" "$id2" "$new_status"
        return 0
    fi
    if _rate_limited "$out"; then return 2; fi
    echo "$out" >&2
    return 1
}

# _do_move/_do_prio/_do_est: same effect as the move/prio/est case branches,
# factored out so both the live command AND flush replay share one
# implementation. Return 0 = applied, 1 = real (non-rate-limit) failure,
# 2 = rate-limited (caller decides: queue live, or re-queue-and-stop in flush).
_do_move() {
    local num="$1" status="$2" opt rc
    opt="$(opt_id status "$status")"
    if [[ -z "$opt" ]]; then
        echo "ERROR: bad issue# or status '$status' (must match statusFlow)" >&2
        return 1
    fi
    _mutate_field "$num" "$STATUS_FIELD" --single-select-option-id "$opt" "$status"; rc=$?
    case "$rc" in
        0)
            echo "moved #$num -> $status"
            python3 "$HERE/telemetry.py" "$ROOT" record \
                "{\"kind\":\"transition\",\"task\":\"$num\",\"from\":\"\",\"to\":\"$status\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
                >/dev/null 2>&1 || true
            return 0
            ;;
        2) return 2 ;;
        3) echo "ERROR: bad issue# or status '$status' (must match statusFlow)" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

_do_prio() {
    local num="$1" prio="$2" opt rc
    opt="$(opt_id priority "$prio")"
    if [[ -z "$opt" ]]; then
        echo "ERROR: bad issue# or priority '$prio'" >&2
        return 1
    fi
    _mutate_field "$num" "$PRIO_FIELD" --single-select-option-id "$opt" ""; rc=$?
    case "$rc" in
        0) echo "prio #$num -> $prio"; return 0 ;;
        2) return 2 ;;
        3) echo "ERROR: bad issue# or priority '$prio'" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

_do_est() {
    local num="$1" points="$2" rc
    if [[ -z "$EST_FIELD" ]]; then
        echo "ERROR: no estimate field configured" >&2
        return 1
    fi
    _mutate_field "$num" "$EST_FIELD" --number "$points" ""; rc=$?
    case "$rc" in
        0) echo "est #$num -> $points"; return 0 ;;
        2) return 2 ;;
        3) echo "ERROR: bad issue# '$num'" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

# _do_add_finish: the remainder of `add`'s work after the issue itself
# exists (item-add, poll for visibility, move to FIRST_STATUS, set prio).
# Used both by `add`'s own fallback (visibility cap hit) and by flush
# replaying a queued add-finish op. Idempotent: skips item-add / move when
# the item is already visible / already at the target status.
_do_add_finish() {
    local num="$1" url="$2" first_status="$3" prio="$4" id out rc cur
    id="$(_item_id_rl "$num")"; rc=$?
    [[ $rc -eq 2 ]] && return 2
    if [[ -z "$id" ]]; then
        out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
        if [[ $rc -ne 0 ]]; then
            _rate_limited "$out" && return 2
            echo "ERROR: add-finish #$num: gh project item-add failed: $out" >&2
            return 1
        fi
        id="$(_poll_visible "$num")"
        [[ -z "$id" ]] && return 2  # still not visible (or rate-limited) within the cap -- re-queue, try again later
    fi
    cur="$(_current_status "$num")"
    if [[ "$cur" != "$first_status" ]]; then
        _do_move "$num" "$first_status"; rc=$?
        [[ "$rc" -ne 0 ]] && return "$rc"
    fi
    _do_prio "$num" "$prio"; rc=$?
    [[ "$rc" -ne 0 ]] && return "$rc"
    echo "flush: finished add #$num [$prio]"
    return 0
}

# _do_adopt: add an EXISTING issue to the board (issue #84). Idempotent —
# a no-op (with a message) if the issue is already a board item. #92: a
# freshly-added item has no Status set by item-add itself (it landed with
# '-' on the board) -- poll briefly for visibility (same cache-aware,
# 2-attempt/backoff cap as _do_add_finish -- issue #78 -- via _poll_visible)
# and set FIRST_STATUS, matching `add`'s behavior. If the item never
# becomes visible in that window the adopt still succeeds (the issue IS on
# the board); if setting the status itself rate-limits, queue a follow-up
# move instead of failing the whole adopt.
_do_adopt() {
    local num="$1" id url out rc cur
    id="$(_item_id_rl "$num")"; rc=$?
    [[ $rc -eq 2 ]] && return 2
    if [[ -n "$id" ]]; then
        echo "adopt #$num: already on board"
        return 0
    fi
    url="https://github.com/$REPO/issues/$num"
    out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        _rate_limited "$out" && return 2
        echo "ERROR: adopt #$num: gh project item-add failed: $out" >&2
        return 1
    fi
    id="$(_poll_visible "$num")"; rc=$?
    if [[ $rc -eq 2 ]]; then echo "adopted #$num"; return 0; fi
    if [[ -n "$id" ]]; then
        cur="$(_current_status "$num")"
        # shellcheck disable=SC2153  # FIRST_STATUS is the global set by board.sh's
        # eval block, not a typo of a local first_status
        if [[ "$cur" != "$FIRST_STATUS" ]]; then
            _do_move "$num" "$FIRST_STATUS"; rc=$?
            if [[ "$rc" -eq 2 ]]; then
                queue_append move issue="$num" status="$FIRST_STATUS"
            elif [[ "$rc" -ne 0 ]]; then
                echo "ERROR: adopt #$num: added to board but failed to set initial status" >&2
                return 1
            fi
        fi
    fi
    echo "adopted #$num"
    return 0
}

# _dir_mtime <dir> -> mtime as epoch seconds (GNU stat, then BSD/macOS stat;
# 0 if neither works, which never satisfies a staleness check as "past TTL"
# less than TTL is treated as fresh, so a stat failure fails safe: the lock
# is treated as held, never spuriously broken).
_dir_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

# _queue_lock_acquire: mkdir-based mutex (#92) -- portable on bash 3.2/macOS,
# which has no flock builtin, and mkdir is atomic on every POSIX filesystem.
# Returns 0 = lock now held by us, 1 = another flush holds a live lock (the
# caller SKIPS -- never blocks, never replays concurrently). A lock older
# than QUEUE_LOCK_TTL is broken with a warning: a flusher that crashed
# mid-flush must not wedge the queue forever.
_queue_lock_acquire() {
    mkdir -p "$(dirname "$QUEUE_LOCK_DIR")"
    mkdir "$QUEUE_LOCK_DIR" 2>/dev/null && return 0
    local age
    age=$(( $(date +%s) - $(_dir_mtime "$QUEUE_LOCK_DIR") ))
    if [[ "$age" -ge "$QUEUE_LOCK_TTL" ]]; then
        echo "flush: WARNING breaking stale lock (age ${age}s >= ${QUEUE_LOCK_TTL}s TTL) -- a previous flush likely crashed" >&2
        rmdir "$QUEUE_LOCK_DIR" 2>/dev/null
        mkdir "$QUEUE_LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
}

_queue_lock_release() {
    rmdir "$QUEUE_LOCK_DIR" 2>/dev/null || true
}

# _dedupe_aside <file>: rewrites <file> in place (review #92 round 2,
# BLOCKING finding), keeping only the most-recently-enqueued entry per
# (op, issue) for op kinds whose replay can regress a value if a stale
# entry re-applies after a newer one already has (move/prio/est). Without
# this: a rate-limited requeue appends the OLDER op to the TAIL of the
# live queue file, but a NEWER op for the same issue can already be
# sitting there (queued live while the first flush was mid-flight) ahead
# of it. Replay in file order then applies the newer one first (cur
# becomes its target) and the stale older one second -- the `cur ==
# target` skip guard doesn't catch this, since cur is now the NEWER
# target, not the one the stale op checks against -- so the stale op
# re-applies and regresses the value. Recency is judged by each entry's
# own `ts` (untouched across every requeue, so it always reflects original
# enqueue time, not append time); ties keep the later file position.
# Survivors keep their original relative order -- only the stale
# duplicates are dropped.
_dedupe_aside() {
    python3 -c '
import json, sys

path = sys.argv[1]
DEDUPE_OPS = {"move", "prio", "est"}
with open(path) as f:
    lines = [ln for ln in f.read().splitlines() if ln.strip()]

best_idx = {}  # (op, issue) -> (ts, line-index) of the winning entry
for i, ln in enumerate(lines):
    try:
        d = json.loads(ln)
    except Exception:
        continue
    op = d.get("op")
    if op not in DEDUPE_OPS:
        continue
    key = (op, d.get("issue"))
    ts = d.get("ts", "")
    if key not in best_idx or ts >= best_idx[key][0]:
        best_idx[key] = (ts, i)

winners = {idx for _, idx in best_idx.values()}
kept = []
for i, ln in enumerate(lines):
    try:
        d = json.loads(ln)
    except Exception:
        kept.append(ln)
        continue
    if d.get("op") not in DEDUPE_OPS or i in winners:
        kept.append(ln)

with open(path, "w") as f:
    for ln in kept:
        f.write(ln + "\n")
' "$1"
}

# _flush_queue [--verbose]: replay QUEUE_FILE in order, guarded by the
# lockdir mutex. A second flush that can't take the lock SKIPS immediately
# (issue #92) -- never blocks, never replays concurrently with another
# flush. The lock is taken BEFORE the emptiness check (not after): once
# another flush has moved the queue file aside, the live path is briefly
# and legitimately empty, but that's a "locked" state, not a "nothing to
# do" state -- an emptiness check ahead of the lock attempt would
# misreport the former as the latter. --verbose (used by the explicit
# `flush` verb) prints "queue empty" when there's genuinely nothing to do
# AFTER the lock is held -- so it can never misfire as "empty" during
# another flush's momentary aside-move window. Auto-flush call sites
# (next/list/show) omit --verbose and stay silent on an empty queue,
# matching pre-#92 behavior.
_flush_queue() {
    local verbose=0
    [[ "${1:-}" == "--verbose" ]] && verbose=1
    if ! _queue_lock_acquire; then
        echo "flush: SKIP -- another flush holds the lock ($QUEUE_LOCK_DIR)"
        return 0
    fi
    if [[ -s "$QUEUE_FILE" ]]; then
        _flush_queue_locked
    elif [[ "$verbose" -eq 1 ]]; then
        echo "queue empty"
    fi
    _queue_lock_release
}

# _flush_queue_locked: the actual replay, called with the lock already held.
# Lost-append prevention (#92): instead of a blind truncate, the queue file
# is MOVED ASIDE atomically (mv, same filesystem -- a single rename syscall,
# no read-then-clear gap for a concurrent queue_append to fall into and get
# wiped) before replay. Any re-queued remainder is appended back to the LIVE
# queue path afterward -- which new queue_appends may have grown meanwhile --
# instead of clobbering it.
_flush_queue_locked() {
    local aside line op issue status priority points url first_status prio rc cur requeued reset
    aside="$(mktemp "$(dirname "$QUEUE_FILE")/.flush.XXXXXX")"
    mv "$QUEUE_FILE" "$aside" 2>/dev/null || { rm -f "$aside"; return 0; }
    _dedupe_aside "$aside"
    _flush_sync "${BOARD_QUEUE_TEST_TAG:-flush}"
    requeued=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$requeued" -eq 1 ]]; then
            printf '%s\n' "$line" >>"$QUEUE_FILE"
            continue
        fi
        op="$(_jf "$line" op)"
        case "$op" in
            move)
                issue="$(_jf "$line" issue)"; status="$(_jf "$line" status)"
                cur="$(_current_status "$issue")"
                if [[ -n "$cur" && "$cur" == "$status" ]]; then
                    echo "flush: skip move #$issue (already $status)"
                    rc=0
                else
                    _do_move "$issue" "$status"; rc=$?
                fi
                ;;
            prio)
                issue="$(_jf "$line" issue)"; priority="$(_jf "$line" priority)"
                _do_prio "$issue" "$priority"; rc=$?
                ;;
            est)
                issue="$(_jf "$line" issue)"; points="$(_jf "$line" points)"
                _do_est "$issue" "$points"; rc=$?
                ;;
            add-finish)
                issue="$(_jf "$line" issue)"; url="$(_jf "$line" url)"
                first_status="$(_jf "$line" first_status)"; prio="$(_jf "$line" prio)"
                _do_add_finish "$issue" "$url" "$first_status" "$prio"; rc=$?
                ;;
            adopt)
                issue="$(_jf "$line" issue)"
                _do_adopt "$issue"; rc=$?
                ;;
            *)
                echo "flush: WARNING dropping queued line with unknown op '$op'" >&2
                rc=0
                ;;
        esac
        if [[ "$rc" -eq 2 ]]; then
            reset="$(_rate_limit_reset_human)"
            echo "QUEUED (rate-limited until $reset): $op #$issue"
            printf '%s\n' "$line" >>"$QUEUE_FILE"
            requeued=1
        fi
    done <"$aside"
    rm -f "$aside"
}
