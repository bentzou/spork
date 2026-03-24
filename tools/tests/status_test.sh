#!/bin/bash
# status_test.sh — tests for status-all.sh's STATE verdict, which answers
# "can I pick this clone up?" by folding a live claim and git state into one
# word: `open` (grabbable) / `in use` (claimed) / branch|local|pull|push.
#
# Same harness style as claim_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test. No network, no mirror.
#
#   tools/tests/status_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:status/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# Background sleepers stand in for live session owners; tracked for cleanup.
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
    local path="$1" branch="$2"
    git -C "$(dirname "$path")" init -q "$(basename "$path")"
    git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$path" remote add origin "$ORIGIN_URL_FIXTURE"
}

# Workspace with `n_ready` ready clones (p1..) plus one feature-branch clone.
make_workspace() {
    local n_ready="$1" i
    WS=$(mktemp -d)
    ln -s "$SPORK_REPO" "$WS/.spork"
    mkdir -p "$WS/.spork.local"
    cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF
    for (( i=1; i<=n_ready; i++ )); do make_clone "$WS/p$i" main; done
    make_clone "$WS/pX" main
    git -C "$WS/pX" checkout -q -b feature
}

status() { ( cd "$WS" && ./.spork/tools/status-all.sh ); }
# STATE word for clone <name> = 2nd-to-last field of its row (AGE may be blank,
# so read STATE positionally from the front: REPO BRANCH STATE [AGE]). STATE can
# be two words ("in use"), so reconstruct it as everything between BRANCH and AGE.
state_of() {
    status | awk -v n="$1" '
        $1==n {
            s=$3
            # Join a possible 2nd STATE word ("in use") when present.
            if ($4!="" && $4 !~ /^[0-9]+[smhd]$/ && $4!="—") s=s" "$4
            print s; exit
        }'
}

# Claim/release a clone by name via the sourced helpers (claim.sh only grabs
# *ready* clones, so use try_claim directly to occupy a dirty one too).
claim_clone()   { ( cd "$WS" && . ./.spork/tools/_lib.sh && try_claim "$1" "$2" ); }
release_clone() { ( cd "$WS" && . ./.spork/tools/_lib.sh && release_claim "$1" "$2" ); }

# ---------------------------------------------------------------------------
echo "status: STATE verdict folds occupancy + git state into pickability"
make_workspace 3
a=$(live_pid)

# p1 ready & unclaimed -> the one grabbable state.
check "ready, free -> open" "open" "$(state_of p1)"

# pX is on a feature branch -> parked, git state shows through.
check "feature branch -> branch" "branch" "$(state_of pX)"

# p2 ready but claimed by a live session -> in use, never 'open'.
claim_clone p2 "$a" >/dev/null
check "ready, claimed -> in use" "in use" "$(state_of p2)"

# A dirty clone reports its git state when free...
: > "$WS/p3/dirty.txt"
check "dirty, free -> local" "local" "$(state_of p3)"
# ...but a live claim overrides git state: occupancy wins.
claim_clone p3 "$a" >/dev/null
check "dirty, claimed -> in use (claim overrides git state)" "in use" "$(state_of p3)"

# Releasing reverts to the git-derived state — no background reaper.
release_clone p2 "$a" >/dev/null
check "release ready clone -> open again" "open" "$(state_of p2)"
release_clone p3 "$a" >/dev/null
check "release dirty clone -> local again" "local" "$(state_of p3)"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
