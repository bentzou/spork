#!/bin/bash
# resume_test.sh — tests for the two tools behind `just resume`:
#   find-session.sh — resolve an id/prefix to "<clone>\t<cwd>\t<full-id>"
#   claim-one.sh    — claim a NAMED clone (any git state) for an owner
#
# Same harness style as status_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test, a hermetic
# CLAUDE_PROJECTS_DIR fixture, and background sleepers standing in for live
# claim owners. No network, no mirror, and `claude` itself is never launched —
# these cover everything up to the resume handoff.
#
#   tools/tests/resume_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:resume/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

LIVE_PIDS=()
live_pid() { sleep 300 >/dev/null 2>&1 & local p=$!; LIVE_PIDS+=("$p"); printf '%s' "$p"; }

WS=""
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

make_workspace() {
    local n="$1" i
    WS=$(mktemp -d)
    export CLAUDE_PROJECTS_DIR="$WS/projects"
    export CODEX_SESSIONS_DIR="$WS/codex-sessions"
    # Hermetic occupancy: no real terminal/claude cwds leak into claim-one.
    export SPORK_PROC_SWEEP="" SPORK_PROC_SWEEP_LOADED=1
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

# Write a session log for <clone> at <subpath> ("" = clone root) with id <id>
# and a recorded launch <cwd> ("" = omit the cwd record, exercising fallback).
session_for() {
    local name="$1" subpath="$2" id="$3" cwd="$4" enc dir
    enc="${WS//\//-}-$name"
    [[ -n "$subpath" ]] && enc="$enc-${subpath//\//-}"
    dir="$CLAUDE_PROJECTS_DIR/$enc"
    mkdir -p "$dir"
    {
        printf '{"type":"session","sessionId":"%s"}\n' "$id"
        [[ -n "$cwd" ]] && printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$cwd" "$id"
    } > "$dir/$id.jsonl"
}

codex_session_for() {
    local name="$1" subpath="$2" id="$3" cwd="$4" title="$5" enc dir
    dir="$CODEX_SESSIONS_DIR/2026/07/20"
    mkdir -p "$dir"
    {
        printf '{"timestamp":"2026-07-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"%s","cwd":"%s"}}\n' "$id" "$cwd"
        printf '{"timestamp":"2026-07-20T00:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$title"
    } > "$dir/rollout-2026-07-20T00-00-00-$id.jsonl"
    # Keep args symmetrical with session_for; cwd in the log is authoritative.
    : "$name" "$subpath"
}

find_session() { ( cd "$WS" && ./.spork/tools/find-session.sh "$@" ); }
claim_one()    { ( cd "$WS" && ./.spork/tools/claim-one.sh "$@" ); }
release()      { ( cd "$WS" && ./.spork/tools/release.sh "$@" ); }
occupied() {  # occupied <clone> -> "yes"/"no"
    ( cd "$WS" && . ./.spork/tools/_lib.sh && clone_occupied "$WS/$1" && echo yes || echo no )
}

# ---------------------------------------------------------------------------
echo "find-session: resolve id/prefix to clone, launch cwd, and full id"
make_workspace 3

# A session launched from a monorepo subdir: its cwd must come back exactly,
# not a lossy decode of the dashed project-dir name.
mkdir -p "$WS/p1/src/app"
session_for p1 "src-app" "11110000-aaaa-bbbb-cccc-000000000001" "$WS/p1/src/app"
session_for p2 ""        "22220000-dddd-eeee-ffff-000000000002" "$WS/p2"

want1="claude	p1	$WS/p1/src/app	11110000-aaaa-bbbb-cccc-000000000001"
check "full id resolves to clone+cwd+id" "$want1" "$(find_session 11110000-aaaa-bbbb-cccc-000000000001)"
check "subdir cwd preserved verbatim"    "$WS/p1/src/app" "$(find_session 11110000 | cut -f3)"
check "unique prefix resolves"           "$want1" "$(find_session 1111)"
check "clone of the match"               "p2"     "$(find_session 2222 | cut -f2)"

# ---------------------------------------------------------------------------
echo
echo "find-session: ambiguity, exact-over-prefix, misses, fallbacks"

# Two ids sharing a prefix: the bare prefix is ambiguous (exit 1)...
session_for p3 "" "abcd0000-0000-0000-0000-000000000aaa" "$WS/p3"
session_for p3 "" "abcd1111-1111-1111-1111-000000000bbb" "$WS/p3"
check "ambiguous prefix -> exit 1"   "1" "$(find_session abcd >/dev/null 2>&1; echo $?)"
check "ambiguous prefix lists both"  "2" "$(find_session abcd 2>&1 >/dev/null | grep -c '^  abcd')"

# ...but an exact full id wins even when it's a prefix of nothing else here, and
# even if it were a prefix of another it'd still resolve to the exact match.
session_for p1 "" "ex"     "$WS/p1"      # short id that is a prefix of "ex2..."
session_for p1 "" "ex2abc" "$WS/p1"
check "exact id beats longer prefix" "ex" "$(find_session ex | cut -f4)"

check "no match -> exit 1"           "1" "$(find_session nope >/dev/null 2>&1; echo $?)"
check "no arg -> usage exit 2"       "2" "$(find_session >/dev/null 2>&1; echo $?)"

# A session whose log records no cwd falls back to the clone root.
session_for p2 "" "nocwd000-0000-0000-0000-000000000ccc" ""
check "missing cwd -> clone root"    "$WS/p2" "$(find_session nocwd | cut -f3)"

# A recorded cwd that no longer exists also falls back to the clone root.
session_for p2 "" "gonecwd0-0000-0000-0000-000000000ddd" "$WS/p2/was/here"
check "stale cwd -> clone root"      "$WS/p2" "$(find_session gonecwd | cut -f3)"

# ---------------------------------------------------------------------------
echo
echo "find-session: a clone name resolves to that clone's newest session"
make_workspace 2

mkdir -p "$WS/p1/src/app"
session_for p1 ""        "aaaa0000-0000-0000-0000-000000000001" "$WS/p1"
session_for p1 "src-app" "bbbb0000-0000-0000-0000-000000000002" "$WS/p1/src/app"
p1_root_log="$CLAUDE_PROJECTS_DIR/${WS//\//-}-p1/aaaa0000-0000-0000-0000-000000000001.jsonl"
p1_sub_log="$CLAUDE_PROJECTS_DIR/${WS//\//-}-p1-src-app/bbbb0000-0000-0000-0000-000000000002.jsonl"
touch -t 202601010000 "$p1_root_log"

want="claude	p1	$WS/p1/src/app	bbbb0000-0000-0000-0000-000000000002"
check "clone name -> newest session (cwd + id)" "$want" "$(find_session p1)"

# Recency is last write, same as the status table: age the subdir session
# and the root one wins.
touch "$p1_root_log"
touch -t 202601010000 "$p1_sub_log"
check "newest by last write wins" "aaaa0000-0000-0000-0000-000000000001" "$(find_session p1 | cut -f4)"

# A clone with no sessions has nothing to resume.
check "session-less clone -> exit 1" "1" "$(find_session p2 >/dev/null 2>&1; echo $?)"
out=$(find_session p2 2>&1 >/dev/null)
case "$out" in *p2*) ok "error names the clone";; *) bad "error names the clone (got [$out])";; esac

# ---------------------------------------------------------------------------
echo
echo "find-session: Codex sessions resolve through the agent backend"
make_workspace 2
mkdir -p "$WS/p1/src/app"
codex_session_for p1 "src-app" "cccc0000-0000-0000-0000-000000000001" "$WS/p1/src/app" "Codex work"
want="codex	p1	$WS/p1/src/app	cccc0000-0000-0000-0000-000000000001"
check "codex id resolves with agent" "$want" "$(find_session --agent codex cccc)"
check "codex clone name resolves"    "$want" "$(find_session --agent codex p1)"

# ---------------------------------------------------------------------------
echo
echo "claim-one: claims a named clone in any git state; honors live ownership"
make_workspace 2
a=$(live_pid)
b=$(live_pid)

# Dirty + on a feature branch: claim.sh would skip it, claim-one takes it.
: > "$WS/p1/dirty.txt"
git -C "$WS/p1" checkout -q -b feature
check "claims a non-ready clone"     "$WS/p1" "$(claim_one p1 "$a")"
check "and it now reads occupied"    "yes"    "$(occupied p1)"

# A different live owner is refused; the original still holds it.
check "second live owner refused"    "1"      "$(claim_one p1 "$b" >/dev/null 2>&1; echo $?)"
check "refusal explains it's in use" "1"      "$(claim_one p1 "$b" 2>&1 >/dev/null | grep -c 'in use')"
check "still occupied after refusal" "yes"    "$(occupied p1)"

# Release reverts occupancy (no reaper).
release p1 "$a" >/dev/null
check "released -> free again"       "no"     "$(occupied p1)"

# Unknown clone and missing arg are clean errors.
check "unknown clone -> exit 1"      "1"      "$(claim_one nope "$a" >/dev/null 2>&1; echo $?)"
check "no arg -> usage exit 2"       "2"      "$(claim_one >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
