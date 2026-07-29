#!/bin/bash
# log_test.sh — tests for log-all.sh, which lists Claude sessions across the
# clone pool newest-first: one row per session (including closed ones), ordered
# by last activity, with the session's title.
#
# Same harness style as status_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test, and a hermetic
# CLAUDE_PROJECTS_DIR fixture. No network, no mirror.
#
#   tools/tests/log_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:log/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

WS=""
LIVE_PIDS=()
live_pid() { sleep 300 >/dev/null 2>&1 & local p=$!; LIVE_PIDS+=("$p"); printf '%s' "$p"; }
cleanup() {
    local p
    for p in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    [[ -n "$WS" && -d "$WS" ]] && rm -rf "$WS"
    rm -f "$FAILFILE"
}
trap cleanup EXIT

make_clone() {
    local path="$1"
    git -C "$(dirname "$path")" init -q "$(basename "$path")"
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$path" remote add origin "$ORIGIN_URL_FIXTURE"
}

# Workspace with clones p1..pN (git repos wired to the fixture origin so
# spork_clones picks them up). Empty session dir until a test writes logs.
make_workspace() {
    local n="$1" i
    WS=$(mktemp -d)
    export CLAUDE_PROJECTS_DIR="$WS/projects"
    export CODEX_SESSIONS_DIR="$WS/codex-sessions"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR"
    ln -s "$SPORK_REPO" "$WS/.spork"
    mkdir -p "$WS/.spork.local"
    cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF
    for (( i=1; i<=n; i++ )); do make_clone "$WS/p$i"; done
}

log() { ( cd "$WS" && ./.spork/tools/log-all.sh "$@" ); }

# Write a session log for <clone> at <subpath> ("" for the clone root), with
# <title> ("" for a session that never got an ai-title), stamped at <touch-ts>
# (a `touch -t` timestamp controlling mtime → ordering). File name <id>.jsonl.
session_for() {
    local name="$1" subpath="$2" title="$3" ts="$4" id="$5" enc dir
    enc="${WS//\//-}-$name"
    [[ -n "$subpath" ]] && enc="$enc-${subpath//\//-}"
    dir="$CLAUDE_PROJECTS_DIR/$enc"
    mkdir -p "$dir"
    if [[ -n "$title" ]]; then
        printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$title" "$id" > "$dir/$id.jsonl"
    else
        printf '{"type":"user","sessionId":"%s"}\n' "$id" > "$dir/$id.jsonl"
    fi
    touch -t "$ts" "$dir/$id.jsonl"
}

# "REP|SESSION" for body row N (1-based, header skipped), or empty. AGE, AGENT,
# REP and ID are single tokens; SESSION is the free-text remainder. Non-tty
# capture carries no color escapes, so plain field splitting is safe.
row() { row_of "$1" all; }
row_of() {
    local n="$1"; shift
    log "$@" | awk -v n="$n" '
        function trim(s){ gsub(/^ +| +$/, "", s); return s }
        NR==1 { next }
        (NR-1)==n { rep=$3; $1=""; $2=""; $3=""; $4=""; print rep "|" trim($0); exit }'
}
# ID (4th column) and AGE (1st column) of body row N, or empty.
id_of()  { log all | awk -v n="$1" 'NR==1{next} (NR-1)==n{print $4; exit}'; }
age_of() { log all | awk -v n="$1" 'NR==1{next} (NR-1)==n{print $1; exit}'; }
# Count of body rows (header excluded).
row_count() { local c; c=$(log all | wc -l); echo $(( c - 1 )); }
# Claim clone <name> for owner <pid> via the sourced helper (occupies it).
claim_clone() { ( cd "$WS" && . ./.spork/tools/_lib.sh && try_claim "$1" "$2" ); }
# Body rows for clone <name> carrying the "(in use)" marker.
inuse_rows() { log all | awk -v r="$1" 'NR>1 && $3==r' | grep -c '(in use)'; }

# ---------------------------------------------------------------------------
echo "log: sessions across clones, newest first, incl. closed + subdir sessions"
make_workspace 3

# p1 has three sessions: an old (closed) root one, a newer root one, and a
# subdir session newest of the three. p2 has the single newest overall. p3 has
# an untitled session, oldest of all.
session_for p1 ""        "p1 old work"   202601020000 a
session_for p1 ""        "p1 new work"   202601030000 b
session_for p1 "src-app" "p1 subdir"     202601040000 c
session_for p2 ""        "p2 only"       202601050000 d
session_for p3 ""        ""              202601010000 e

check "row count = every session (closed ones included)" "5" "$(row_count)"
check "newest first: p2"            "p2|p2 only"   "$(row 1)"
check "subdir session ranks by mtime" "p1|p1 subdir" "$(row 2)"
check "next: p1 new"                "p1|p1 new work" "$(row 3)"
check "closed older p1 session shows" "p1|p1 old work" "$(row 4)"
check "untitled session -> em-dash" "p3|—"         "$(row 5)"

# The ID column carries the session id (the resume handle) — here the fixture
# ids are short, so they show verbatim; in practice it's an 8-char UUID prefix.
check "ID column shows the session id" "d"         "$(id_of 1)"
check "ID matches each row's session"  "c"         "$(id_of 2)"

# ---------------------------------------------------------------------------
echo
echo "log: N limits to the most recent, 'all' shows everything, default is 20"

check "N=2 keeps the two newest"    "2"            "$(log 2 | awk 'NR>1' | wc -l | tr -d ' ')"
check "N=2 top row is the newest"   "p2|p2 only"   "$(row_of 1 2)"
check "'all' shows every session"   "5"            "$(row_count)"
check "bad N -> usage error (exit 2)" "2"          "$(log nope >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
echo
echo "log: long titles truncated, empty pool reports gracefully"

long="Investigate the search index rebuild flow and reconcile cache entries across every clone and branch"
session_for p2 "" "$long" 202601060000 f   # now the newest
trunc="${long:0:71}…"                       # SESSION_MAX-1 chars + ellipsis
check "title truncated at SESSION_MAX" "p2|$trunc" "$(row 1)"
check "full long title not shown"      "0"         "$(log all | grep -Fc -- "$long")"

# A pool with clones but no sessions: message to stderr, success exit, no rows.
make_workspace 2
check "no sessions -> exit 0"          "0"  "$(log >/dev/null 2>&1; echo $?)"
check "no sessions -> no stdout rows"  "0"  "$(log 2>/dev/null | wc -l | tr -d ' ')"
check "no sessions -> stderr notice"   "1"  "$(log 2>&1 >/dev/null | grep -c 'No agent sessions')"

# ---------------------------------------------------------------------------
echo
echo "log: rows of an in-use clone are marked so you know resume will refuse"

make_workspace 3
session_for p1 "" "p1 a" 202601020000 a
session_for p1 "" "p1 b" 202601030000 b   # p1 has two sessions
session_for p2 "" "p2 c" 202601040000 c
live=$(live_pid)
claim_clone p2 "$live" >/dev/null          # p2 now has a live session attached

check "in-use clone's row is marked"   "1"  "$(inuse_rows p2)"
check "free clone's rows are not"       "0"  "$(inuse_rows p1)"
# The marker is plain text in piped output (no color), so tooling/eyes both see it.
check "marker text present once"        "1"  "$(log all | grep -c '(in use)')"

# Every session of an in-use clone is marked (you can't resume any of them),
# not just its newest/live one.
session_for p2 "" "p2 d" 202601050000 d
check "all rows of in-use clone marked" "2"  "$(inuse_rows p2)"

# Releasing the claim clears the marker — occupancy is live, not sticky.
( cd "$WS" && . ./.spork/tools/_lib.sh && release_claim p2 "$live" )
check "released clone no longer marked" "0"  "$(inuse_rows p2)"

# ---------------------------------------------------------------------------
echo
echo "log: forked Codex rollouts collapse to one row per logical session"

make_workspace 2

# One Codex rollout file: <file-uuid> <session-id> <cwd> <title> <iso> <stamp>.
# Forks of one logical session share <session-id> across distinct file uuids.
# The record timestamp (<iso>) drives AGE; <stamp> only sets mtime.
codex_rollout_for() {
    local file_uuid="$1" sid="$2" cwd="$3" title="$4" iso="$5" stamp="$6" dir file
    dir="$CODEX_SESSIONS_DIR/2026/07/20"
    mkdir -p "$dir"
    file="$dir/rollout-2026-07-20T00-00-00-$file_uuid.jsonl"
    {
        printf '{"timestamp":"%s","type":"session_meta","payload":{"session_id":"%s","cwd":"%s"}}\n' "$iso" "$sid" "$cwd"
        printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$iso" "$title"
    } > "$file"
    touch -t "$stamp" "$file"
}

sid="ffff0000-aaaa-bbbb-cccc-000000000001"
codex_rollout_for "aaaa0000-0000-0000-0000-000000000001" "$sid" "$WS/p1" "original run" "2026-07-20T01:00:00.000Z" 202607200100
codex_rollout_for "bbbb0000-0000-0000-0000-000000000002" "$sid" "$WS/p1" "second fork"  "2026-07-20T02:00:00.000Z" 202607200200
codex_rollout_for "cccc0000-0000-0000-0000-000000000003" "$sid" "$WS/p1" "latest fork"  "2026-07-20T03:00:00.000Z" 202607200300
session_for p2 "" "claude too" 202601020000 dddd0000

check "three rollouts, one codex row"  "2"              "$(row_count)"
check "row carries the newest rollout" "p1|latest fork" "$(row 1)"
check "ID is the shared session id"    "ffff0000"       "$(id_of 1)"

# A distinct Codex session id keeps its own row.
codex_rollout_for "eeee0000-0000-0000-0000-000000000004" "99990000-aaaa-bbbb-cccc-000000000009" "$WS/p1" "other session" "2026-07-20T00:30:00.000Z" 202607200030
check "distinct session ids keep rows" "3"              "$(row_count)"

# ---------------------------------------------------------------------------
echo
echo "log: AGE follows record timestamps, not the wake-bumped file mtime"

make_workspace 2

# An idle session's jsonl rewritten on a recent system wake: mtime fresh, but
# the last record months old. A claude session whose records carry no
# timestamps (like the other fixtures here) keeps its mtime.
session_with_ts() {
    local name="$1" title="$2" iso="$3" stamp="$4" id="$5" dir
    dir="$CLAUDE_PROJECTS_DIR/${WS//\//-}-$name"
    mkdir -p "$dir"
    printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s","timestamp":"%s"}\n' \
        "$title" "$id" "$iso" > "$dir/$id.jsonl"
    touch -t "$stamp" "$dir/$id.jsonl"
}
session_with_ts p1 "wake-bumped idle work" "2026-01-01T00:00:00.000Z" 202607280000 stale1
session_for     p2 "" "recent real work" 202606010000 fresh1

check "true recency outranks fresh mtime"   "p2|recent real work"     "$(row 1)"
check "idle session sinks to its record ts" "p1|wake-bumped idle work" "$(row 2)"
# The N-truncation must rank by record ts too — a wake-bumped idle session
# must not crowd genuinely recent work out of the window.
check "N-truncation ranks by record ts"     "p2|recent real work"     "$(row_of 1 1)"
case "$(age_of 2)" in
    *d) ok "wake-bumped AGE reads in days, not minutes" ;;
    *)  bad "wake-bumped AGE reads in days, not minutes (got [$(age_of 2)])" ;;
esac

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
