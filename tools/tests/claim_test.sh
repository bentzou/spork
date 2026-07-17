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
    # Seed the process sweep as already-loaded-and-empty so occupancy is
    # hermetic (no real terminal/claude cwds leak in). Tests inject fake
    # processes by overwriting SPORK_PROC_SWEEP.
    export SPORK_PROC_SWEEP="" SPORK_PROC_SWEEP_LOADED=1
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

# Inject a fake process sweep: sweep [<cmd> <path>]... (no args clears it).
sweep() {
    local out=""
    while (( $# )); do
        out+="${out:+$'\n'}$1"$'\t'"$2"
        shift 2
    done
    export SPORK_PROC_SWEEP="$out"
}

# ---------------------------------------------------------------------------
echo "unit: try_claim / release_claim / staleness"
make_workspace 3
# shellcheck source=/dev/null
( cd "$WS" && . ./.spork/tools/_lib.sh

    sleep 300 >/dev/null 2>&1 & a=$!
    sleep 300 >/dev/null 2>&1 & b=$!

    err=$(claim_owner p1 2>&1 >/dev/null)
    check "unclaimed clone reads silently" "" "$err"

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
echo "unit: proc_attached / clone_occupied see live processes, not just claims"
make_workspace 3
( cd "$WS" && . ./.spork/tools/_lib.sh

    SPORK_PROC_SWEEP=$(printf 'zsh\t%s/p1/deep/dir\nclaude\t%s/p2' "$WS" "$WS")

    proc_attached "$WS/p1";        check "shell in subdir attaches" 0 $?
    proc_attached "$WS/p1" claude; check "command filter excludes shells" 1 $?
    proc_attached "$WS/p2" claude; check "command filter matches claude" 0 $?
    proc_attached "$WS/p3";        check "untouched clone unattached" 1 $?
    proc_attached "$WS/p";         check "path prefix alone does not attach" 1 $?

    clone_occupied "$WS/p1"; check "process alone occupies (no claim)" 0 $?
    clone_occupied "$WS/p3"; check "no claim, no process -> free" 1 $?
) || bad "unit subshell errored"

# ---------------------------------------------------------------------------
echo "unit: spork_proc_sweep joins pgrep names with lsof cwds"
( cd "$WS" && . ./.spork/tools/_lib.sh
    # Stub the probes: pgrep answers per command name (last arg), lsof prints
    # -F pn records. The join must label each cwd with the pgrep-side name —
    # lsof's own command field is useless for claude (its executable is a bare
    # version number like "2.1.211").
    pgrep() { local name; eval 'name=${'$#'}'
        case "$name" in
            claude) printf '11\n' ;;
            zsh)    printf '22\n33\n' ;;
            *)      return 1 ;;
        esac
    }
    lsof() { printf 'p11\nfcwd\nn/ws/p1\np22\nfcwd\nn/ws/p2/sub\np33\nfcwd\nn/elsewhere\n'; }

    out=$(spork_proc_sweep)
    expected=$(printf 'claude\t/ws/p1\nzsh\t/ws/p2/sub\nzsh\t/elsewhere')
    check "sweep labels cwds by pgrep name" "$expected" "$out"

    # No live processes at all -> empty sweep, success (occupancy degrades
    # to claims-only).
    pgrep() { return 1; }
    out=$(spork_proc_sweep); rc=$?
    check "no processes -> empty sweep" "" "$out"
    check "no processes -> exit 0" 0 "$rc"
) || bad "sweep subshell errored"

# ---------------------------------------------------------------------------
echo "unit: clone_origin_url answers from .git/config, git only as fallback"
make_workspace 1
( cd "$WS" && . ./.spork/tools/_lib.sh

    check "plain clone parses without git" "$ORIGIN_URL_FIXTURE" "$(clone_origin_url "$WS/p1")"

    mkdir "$WS/plaindir"
    check "non-repo dir -> empty" "" "$(clone_origin_url "$WS/plaindir")"

    # pushurl shares the section and the 'url' substring; only `url` counts.
    git -C "$WS/p1" config remote.origin.pushurl other:push.git
    check "pushurl not mistaken for url" "$ORIGIN_URL_FIXTURE" "$(clone_origin_url "$WS/p1")"

    # A gitfile layout (separate git dir) has no .git/config to parse — the
    # fallback asks git itself.
    git init -q --separate-git-dir "$WS/.gd" "$WS/gf"
    git -C "$WS/gf" remote add origin "$ORIGIN_URL_FIXTURE"
    check "gitfile repo falls back to git" "$ORIGIN_URL_FIXTURE" "$(clone_origin_url "$WS/gf")"
) || bad "unit subshell errored"

# ---------------------------------------------------------------------------
echo "integration: claim.sh / pick-ready.sh skip clones someone is sitting in"
make_workspace 2
sweep zsh "$WS/p1"
c1=$(tool claim.sh "$(live_pid)"); check "claim skips occupied p1 -> p2" "$WS/p2" "$c1"
out=$(tool claim.sh "$(live_pid)" 2>&1); rc=$?
check "p1 occupied, p2 claimed -> exhausted" 1 "$rc"
g=$(tool pick-ready.sh 2>/dev/null); check "pick-ready finds nothing either" "" "$g"
sweep
g=$(tool pick-ready.sh); check "sweep cleared -> p1 pickable again" "$WS/p1" "$g"

echo "integration: claim-one refuses a live claude, tolerates a bare shell"
make_workspace 2
sweep claude "$WS/p1"
out=$(tool claim-one.sh p1 "$(live_pid)" 2>&1); rc=$?
check "hand-launched claude -> refused" 1 "$rc"
case "$out" in *"in use"*) ok "refusal explains why";; *) bad "refusal explains why (got [$out])";; esac
# A bare terminal parked in the clone is fine — it may well be the caller.
sweep zsh "$WS/p2"
c=$(tool claim-one.sh p2 "$(live_pid)"); check "bare shell -> allowed" "$WS/p2" "$c"
sweep

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
