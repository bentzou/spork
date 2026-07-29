#!/bin/bash
# codex_session_test.sh — tests for the Codex-session backend in _lib.sh.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

WS=$(mktemp -d)
cleanup() { [[ -d "$WS" ]] && rm -rf "$WS"; rm -f "$FAILFILE"; }
trap cleanup EXIT

export CLAUDE_PROJECTS_DIR="$WS/claude-projects"
export CODEX_SESSIONS_DIR="$WS/codex-sessions"
mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR/2026/07/20" "$WS/p1/src/app" "$WS/p2"
ln -s "$SPORK_REPO" "$WS/.spork"
mkdir -p "$WS/.spork.local"
cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=test:codex/fixture.git
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF

cd "$WS" || exit 1
# shellcheck source=/dev/null
. ./.spork/tools/_lib.sh

codex_session_for() {
    local id="$1" cwd="$2" title="$3" stamp="$4" file
    file="$CODEX_SESSIONS_DIR/2026/07/20/rollout-2026-07-20T00-00-00-$id.jsonl"
    {
        printf '{"timestamp":"2026-07-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"%s","cwd":"%s"}}\n' "$id" "$cwd"
        printf '{"timestamp":"2026-07-20T00:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$title"
    } > "$file"
    touch -t "$stamp" "$file"
    printf '%s' "$file"
}

echo "codex sessions: cwd filter, title, id, newest"

old=$(codex_session_for "11110000-aaaa-bbbb-cccc-000000000001" "$WS/p1" "Root Codex work" 202607200001)
new=$(codex_session_for "22220000-dddd-eeee-ffff-000000000002" "$WS/p1/src/app" "Subdir Codex work" 202607200002)
codex_session_for "33330000-dddd-eeee-ffff-000000000003" "$WS/p2" "Other clone" 202607200003 >/dev/null

check "session id from meta" "11110000-aaaa-bbbb-cccc-000000000001" "$(codex_session_id "$old")"
check "session cwd from meta" "$WS/p1/src/app" "$(codex_session_cwd "$new")"
check "title from user message" "Subdir Codex work" "$(codex_session_title "$new")"
check "clone filter includes root + subdir only" "2" "$(codex_clone_session_files "$WS/p1" | wc -l | tr -d ' ')"
check "newest session is subdir" "$new" "$(codex_newest_session_file "$WS/p1")"
check "generic selector reports codex" "codex" "$(spork_newest_session "$WS/p1" | cut -d'|' -f1)"

# A clone Codex occupies but hasn't recorded in yet (rollouts persist on the
# first message) must yield the empty sentinel, not another clone's session —
# status relies on this to blank SESSION/AGE for a fresh occupant.
mkdir -p "$WS/p3"
check "no transcript yet -> empty sentinel" "|" "$(codex_newest_session "$WS/p3")"
check "agent dispatcher passes the sentinel through" "|" "$(agent_newest_session codex "$WS/p3")"

echo
echo "occupant session: the claim-time cutoff blanks pre-claim transcripts"

# The p1 fixtures were recorded at 2026-07-20T00:01Z. Relative to a claim
# taken before that, they're the occupant's; taken after, they're a previous
# session's and only agent survives (SESSION/AGE render as placeholders).
newest="codex|$(agent_newest_session codex "$WS/p1")"
check "post-claim activity passes through"   "$newest"  "$(spork_occupant_session "$WS/p1" codex 1)"
check "pre-claim transcript is blanked"      "codex||"  "$(spork_occupant_session "$WS/p1" codex 9999999999)"
check "no cutoff (process-only) passes through" "$newest" "$(spork_occupant_session "$WS/p1" codex '')"
check "unknown agent scans all, cutoff still applies" "codex||" \
    "$(spork_occupant_session "$WS/p1" '' 9999999999)"
check "no transcript at all stays the empty row" "codex||" \
    "$(spork_occupant_session "$WS/p3" codex 1)"

echo
echo "session inventory: indexes once and serves clone readers"

inventory="$WS/session-inventory"
spork_session_inventory_build "$inventory" "$WS/p1" "$WS/p2"
export SPORK_SESSION_INVENTORY_FILE="$inventory"
check "inventory contains every matching Codex session" "3" \
    "$(awk -F $'\t' '$2 == "codex" { n++ } END { print n+0 }' "$inventory")"
check "inventory keeps root + subdir mapped to p1" "2" \
    "$(codex_clone_session_files "$WS/p1" | wc -l | tr -d ' ')"

# A command-scoped inventory is a snapshot. Adding a transcript afterward must
# not make a clone reader rescan Codex's global tree behind the caller's back.
codex_session_for "44440000-dddd-eeee-ffff-000000000004" "$WS/p1" "After snapshot" 202607200004 >/dev/null
check "active inventory prevents a second global scan" "2" \
    "$(codex_clone_session_files "$WS/p1" | wc -l | tr -d ' ')"
unset SPORK_SESSION_INVENTORY_FILE
check "reader fallback still sees live filesystem state" "3" \
    "$(codex_clone_session_files "$WS/p1" | wc -l | tr -d ' ')"

echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
