#!/bin/bash
# reset_test.sh — tests for reset.sh: take a clone back to a pristine `open`
# state (trunk, clean tree, no stray branches), refusing to destroy unpushed
# work unless --force, and refusing occupied clones outright.
#
# Same harness style as claim_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test. No network, no mirror.
#
#   tools/tests/reset_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:reset/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

WS=""
cleanup() { [[ -n "$WS" && -d "$WS" ]] && rm -rf "$WS"; rm -f "$FAILFILE"; }
trap cleanup EXIT

make_clone() {
    local path="$1"
    git -C "$(dirname "$path")" init -q "$(basename "$path")"
    git -C "$path" symbolic-ref HEAD refs/heads/main
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$path" remote add origin "$ORIGIN_URL_FIXTURE"
}

make_workspace() {
    local n="$1" i
    WS=$(mktemp -d)
    # Hermetic occupancy (see claim_test.sh).
    export SPORK_PROC_SWEEP="" SPORK_PROC_SWEEP_LOADED=1
    ln -s "$SPORK_REPO" "$WS/.spork"
    mkdir -p "$WS/.spork.local"
    cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
POST_CLONE='touch .pc-ran'
EOF
    for (( i=1; i<=n; i++ )); do make_clone "$WS/p$i"; done
}

tool()  { local t="$1"; shift; ( cd "$WS" && "./.spork/tools/$t" "$@" ); }
reset() { tool reset.sh "$@"; }
# Commit helper with fixture identity.
gc() { local p="$1"; shift; git -C "$WS/$p" -c user.email=t@t -c user.name=t "$@"; }

# 0 if <path> exists, 1 if not — a $?-safe file probe for check().
exists() { if [[ -e "$1" ]]; then echo 0; else echo 1; fi; }

sweep() {
    local out=""
    while (( $# )); do
        out+="${out:+$'\n'}$1"$'\t'"$2"
        shift 2
    done
    export SPORK_PROC_SWEEP="$out"
}

# ---------------------------------------------------------------------------
echo "reset: validation and occupancy guards"
make_workspace 3

out=$(reset nope 2>&1); rc=$?
check "unknown clone -> error" 1 "$rc"

mkdir "$WS/notaclone"
out=$(reset notaclone 2>&1); rc=$?
check "dir that isn't a clone of ORIGIN_URL -> error" 1 "$rc"

sweep zsh "$WS/p1"
out=$(reset p1 --force 2>&1); rc=$?
check "occupied clone refused even with --force" 1 "$rc"
case "$out" in *"in use"*) ok "occupied refusal explains why";; *) bad "occupied refusal explains why (got [$out])";; esac
sweep

# ---------------------------------------------------------------------------
echo
echo "reset: clean trunk clone is a cheap no-op"
reset p1 >/dev/null 2>&1; rc=$?
check "clean clone resets fine" 0 "$rc"
check "still on trunk" "main" "$(git -C "$WS/p1" rev-parse --abbrev-ref HEAD)"

# ---------------------------------------------------------------------------
echo
echo "reset: uncommitted work needs --force"
: > "$WS/p1/wip.txt"
out=$(reset p1 2>&1); rc=$?
check "dirty tree refused without --force" 1 "$rc"
check "refusal left the file alone" 0 "$(exists "$WS/p1/wip.txt")"
case "$out" in *--force*) ok "hint mentions --force";; *) bad "hint mentions --force (got [$out])";; esac

reset p1 --force >/dev/null 2>&1; rc=$?
check "dirty tree cleaned with --force" 0 "$rc"
check "working tree clean after" "" "$(git -C "$WS/p1" status --porcelain)"

# ---------------------------------------------------------------------------
echo
echo "reset: branch policy — merged branches go quietly, unmerged need --force"

# A merged branch (same tip as trunk) is deleted without ceremony.
git -C "$WS/p1" branch done-work
reset p1 >/dev/null 2>&1; rc=$?
check "merged branch: reset succeeds" 0 "$rc"
check "merged branch deleted" "main" "$(git -C "$WS/p1" for-each-ref refs/heads --format='%(refname:short)' | tr '\n' ' ' | xargs)"

# An unmerged branch (unique commit) blocks, and survives the refusal.
git -C "$WS/p2" checkout -q -b feat
gc p2 commit -q --allow-empty -m "unpushed work"
out=$(reset p2 2>&1); rc=$?
check "unmerged branch refused without --force" 1 "$rc"
case "$out" in *feat*) ok "refusal names the branch";; *) bad "refusal names the branch (got [$out])";; esac
git -C "$WS/p2" rev-parse -q --verify feat >/dev/null; check "branch survives refusal" 0 $?

reset p2 --force >/dev/null 2>&1; rc=$?
check "unmerged branch: --force resets" 0 "$rc"
check "back on trunk" "main" "$(git -C "$WS/p2" rev-parse --abbrev-ref HEAD)"
git -C "$WS/p2" rev-parse -q --verify feat >/dev/null; check "branch deleted under --force" 1 $?

# ---------------------------------------------------------------------------
echo
echo "reset: snaps trunk to origin's tracking ref when one exists"

# Simulate a fetched origin/main, then advance local main past it: those
# trunk commits exist nowhere else, so they're unpushed work -> --force.
shaA=$(git -C "$WS/p3" rev-parse HEAD)
git -C "$WS/p3" update-ref refs/remotes/origin/main "$shaA"
gc p3 commit -q --allow-empty -m "unpushed trunk commit"
out=$(reset p3 2>&1); rc=$?
check "trunk ahead of origin refused without --force" 1 "$rc"
reset p3 --force >/dev/null 2>&1; rc=$?
check "--force snaps to origin ref" 0 "$rc"
check "HEAD == origin/main" "$shaA" "$(git -C "$WS/p3" rev-parse HEAD)"

# ---------------------------------------------------------------------------
echo
echo "reset: --full also wipes ignored files and reruns POST_CLONE"
make_workspace 1

# A tracked .gitignore plus an ignored artifact (a stand-in for node_modules).
echo "build.out" > "$WS/p1/.gitignore"
gc p1 add .gitignore
gc p1 commit -q -m "add gitignore"
echo artifact > "$WS/p1/build.out"

reset p1 >/dev/null 2>&1; rc=$?
check "default reset succeeds around ignored file" 0 "$rc"
check "ignored file kept by default" 0 "$(exists "$WS/p1/build.out")"
check "POST_CLONE not run by default" 1 "$(exists "$WS/p1/.pc-ran")"

reset p1 --full >/dev/null 2>&1; rc=$?
check "--full reset succeeds" 0 "$rc"
check "--full wipes ignored file" 1 "$(exists "$WS/p1/build.out")"
check "--full reruns POST_CLONE" 0 "$(exists "$WS/p1/.pc-ran")"

# ---------------------------------------------------------------------------
echo
echo "reset: detached HEAD comes back to trunk"
make_workspace 1
git -C "$WS/p1" checkout -q --detach
reset p1 >/dev/null 2>&1; rc=$?
check "detached HEAD reset succeeds" 0 "$rc"
check "back on trunk" "main" "$(git -C "$WS/p1" rev-parse --abbrev-ref HEAD)"

# ---------------------------------------------------------------------------
echo
echo "reset: a broken clone gets a re-clone hint, not a half-reset"
make_workspace 1
echo garbage > "$WS/p1/.git/HEAD"
out=$(reset p1 --force 2>&1); rc=$?
check "broken clone -> error" 1 "$rc"
case "$out" in *clone*) ok "hint suggests re-cloning";; *) bad "hint suggests re-cloning (got [$out])";; esac

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
