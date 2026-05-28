#!/bin/bash
# claim_test.sh — tests for the clone-claim machinery (_lib.sh helpers plus the
# claim.sh / release.sh / pick-ready.sh CLIs).
#
# Builds a throwaway workspace with real git clones, symlinks .spork at the
# repo under test, and exercises both the sourced helpers (unit) and the tools
# as invoked in production (integration). No network, no mirror.
#
#   tools/tests/claim_test.sh        # run all
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:claim/fixture.git"

# Failures are recorded to a file so assertions inside subshells (where the
# sourced _lib lives) still count toward the final exit status.
FAILFILE=$(mktemp)
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# Background sleepers stand in for live session owners; tracked for cleanup.
# Detach all fds — a backgrounded job that inherits the command-substitution
# pipe would keep $(live_pid) blocked until the sleep ends.
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

# Build a workspace with `n_ready` ready clones (p1..) plus one non-ready clone
# (on a branch) to confirm it's skipped.
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
    for (( i=1; i<=n_ready; i++ )); do
        make_clone "$WS/p$i" main
    done
    # A non-ready clone: on a feature branch, so is_ready is false.
    make_clone "$WS/pX" main
    git -C "$WS/pX" checkout -q -b feature
}

make_clone() {
    local path="$1" branch="$2"
    git -C "$(dirname "$path")" init -q "$(basename "$path")"
    git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$path" remote add origin "$ORIGIN_URL_FIXTURE"
}

# Run a spork tool the way production does: from the workspace via ./.spork.
tool() { local t="$1"; shift; ( cd "$WS" && "./.spork/tools/$t" "$@" ); }

# ---------------------------------------------------------------------------
echo "unit: try_claim / release_claim / staleness"
make_workspace 3
# shellcheck source=/dev/null
( cd "$WS" && . ./.spork/tools/_lib.sh

    sleep 300 >/dev/null 2>&1 & a=$!
    sleep 300 >/dev/null 2>&1 & b=$!

    try_claim p1 "$a"; check "first claim succeeds" 0 $?
    try_claim p1 "$b"; check "second claim by other live pid fails" 1 $?
    clone_occupied "$WS/p1"; check "p1 reads occupied" 0 $?
    clone_occupied "$WS/p2"; check "p2 reads free" 1 $?

    release_claim p1 "$a"; check "owner releases" 0 $?
    clone_occupied "$WS/p1"; check "p1 free after release" 1 $?
    try_claim p1 "$b"; check "reclaim after release succeeds" 0 $?

    # Staleness: a claim owned by a dead pid is reclaimable.
    d=$(bash -c ':' & p=$!; wait "$p" 2>/dev/null; echo "$p")
    mkdir -p "$RUNTIME_DIR/claims/p2"; echo "$d" > "$RUNTIME_DIR/claims/p2/pid"
    clone_occupied "$WS/p2"; check "dead-owner claim reads free" 1 $?
    try_claim p2 "$a"; check "reclaim stale claim succeeds" 0 $?

    # release by a non-owner whose claim is live must be refused.
    release_claim p2 "$b"; check "non-owner release refused" 1 $?
    kill "$a" "$b" 2>/dev/null
) || bad "unit subshell errored"

# ---------------------------------------------------------------------------
echo "integration: claim.sh hands out distinct clones, then exhausts"
make_workspace 3
a=$(live_pid); b=$(live_pid); c=$(live_pid)
c1=$(tool claim.sh "$a"); check "claim 1 -> p1" "$WS/p1" "$c1"
c2=$(tool claim.sh "$b"); check "claim 2 -> p2" "$WS/p2" "$c2"
c3=$(tool claim.sh "$c"); check "claim 3 -> p3" "$WS/p3" "$c3"
out=$(tool claim.sh "$(live_pid)" 2>&1); rc=$?
check "claim 4 exits non-zero" 1 "$rc"
case "$out" in *"in use"*) ok "exhaustion hint shown";; *) bad "exhaustion hint shown (got [$out])";; esac

echo "integration: pick-ready skips occupied; release frees"
g=$(tool pick-ready.sh 2>/dev/null); check "pick-ready skips claimed, no free -> error" "" "$g"
tool release.sh "$WS/p2" "$b"; check "release.sh p2" 0 $?
c4=$(tool claim.sh "$(live_pid)"); check "p2 reusable after release" "$WS/p2" "$c4"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
