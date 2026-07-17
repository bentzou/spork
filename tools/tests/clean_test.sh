#!/bin/bash
# clean_test.sh — tests for clean.sh: take a clone back to an `open` state
# (latest trunk, clean working tree) while leaving local branches alone,
# refusing to discard uncommitted/unpushed-trunk work unless --force, and
# refusing occupied clones outright.
#
# Same harness style as claim_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test. No network, no mirror.
#
#   tools/tests/clean_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:clean/fixture.git"

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
clean() { tool clean.sh "$@"; }
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
echo "clean: validation and occupancy guards"
make_workspace 3

out=$(clean nope 2>&1); rc=$?
check "unknown clone -> error" 1 "$rc"

mkdir "$WS/notaclone"
out=$(clean notaclone 2>&1); rc=$?
check "dir that isn't a clone of ORIGIN_URL -> error" 1 "$rc"

sweep zsh "$WS/p1"
out=$(clean p1 --force 2>&1); rc=$?
check "occupied clone refused even with --force" 1 "$rc"
case "$out" in *"in use"*) ok "occupied refusal explains why";; *) bad "occupied refusal explains why (got [$out])";; esac
sweep

# ---------------------------------------------------------------------------
echo
echo "clean: pristine trunk clone is a cheap no-op"
clean p1 >/dev/null 2>&1; rc=$?
check "pristine clone cleans fine" 0 "$rc"
check "still on trunk" "main" "$(git -C "$WS/p1" rev-parse --abbrev-ref HEAD)"

# ---------------------------------------------------------------------------
echo
echo "clean: uncommitted work needs --force"
: > "$WS/p1/wip.txt"
out=$(clean p1 2>&1); rc=$?
check "dirty tree refused without --force" 1 "$rc"
check "refusal left the file alone" 0 "$(exists "$WS/p1/wip.txt")"
case "$out" in *--force*) ok "hint mentions --force";; *) bad "hint mentions --force (got [$out])";; esac

clean p1 --force >/dev/null 2>&1; rc=$?
check "dirty tree cleaned with --force" 0 "$rc"
check "working tree clean after" "" "$(git -C "$WS/p1" status --porcelain)"

# ---------------------------------------------------------------------------
echo
echo "clean: local branches are never touched"

# A checked-out branch with unique commits is NOT a loss — the branch ref
# keeps its work — so no --force is needed; clean just returns to trunk.
git -C "$WS/p2" checkout -q -b feat
gc p2 commit -q --allow-empty -m "branch work"
clean p2 >/dev/null 2>&1; rc=$?
check "branch checkout cleans without --force" 0 "$rc"
check "back on trunk" "main" "$(git -C "$WS/p2" rev-parse --abbrev-ref HEAD)"
git -C "$WS/p2" rev-parse -q --verify feat >/dev/null; check "branch survives the clean" 0 $?
check "branch tip untouched" "branch work" "$(git -C "$WS/p2" log -1 --format=%s feat)"

# Merged branches survive too — clean deletes nothing.
git -C "$WS/p1" branch done-work
clean p1 >/dev/null 2>&1; rc=$?
check "merged branch: clean succeeds" 0 "$rc"
git -C "$WS/p1" rev-parse -q --verify done-work >/dev/null; check "merged branch also kept" 0 $?

# ---------------------------------------------------------------------------
echo
echo "clean: snaps trunk to origin's tracking ref when one exists"

# Simulate a fetched origin/main, then advance local main past it: those
# trunk commits exist nowhere else, so they're unpushed work -> --force.
shaA=$(git -C "$WS/p3" rev-parse HEAD)
git -C "$WS/p3" update-ref refs/remotes/origin/main "$shaA"
gc p3 commit -q --allow-empty -m "unpushed trunk commit"
out=$(clean p3 2>&1); rc=$?
check "trunk ahead of origin refused without --force" 1 "$rc"
clean p3 --force >/dev/null 2>&1; rc=$?
check "--force snaps to origin ref" 0 "$rc"
check "HEAD == origin/main" "$shaA" "$(git -C "$WS/p3" rev-parse HEAD)"

# ---------------------------------------------------------------------------
echo
echo "clean: --full also wipes ignored files and reruns POST_CLONE"
make_workspace 1

# A tracked .gitignore plus an ignored artifact (a stand-in for node_modules).
echo "build.out" > "$WS/p1/.gitignore"
gc p1 add .gitignore
gc p1 commit -q -m "add gitignore"
echo artifact > "$WS/p1/build.out"

clean p1 >/dev/null 2>&1; rc=$?
check "default clean succeeds around ignored file" 0 "$rc"
check "ignored file kept by default" 0 "$(exists "$WS/p1/build.out")"
check "POST_CLONE not run by default" 1 "$(exists "$WS/p1/.pc-ran")"

clean p1 --full >/dev/null 2>&1; rc=$?
check "--full clean succeeds" 0 "$rc"
check "--full wipes ignored file" 1 "$(exists "$WS/p1/build.out")"
check "--full reruns POST_CLONE" 0 "$(exists "$WS/p1/.pc-ran")"

# ---------------------------------------------------------------------------
echo
echo "clean: detached HEAD comes back to trunk"
make_workspace 1
git -C "$WS/p1" checkout -q --detach
clean p1 >/dev/null 2>&1; rc=$?
check "detached HEAD clean succeeds" 0 "$rc"
check "back on trunk" "main" "$(git -C "$WS/p1" rev-parse --abbrev-ref HEAD)"

# ---------------------------------------------------------------------------
echo
echo "clean: a broken clone gets a re-clone hint, not a half-clean"
make_workspace 1
echo garbage > "$WS/p1/.git/HEAD"
out=$(clean p1 --force 2>&1); rc=$?
check "broken clone -> error" 1 "$rc"
case "$out" in *clone*) ok "hint suggests re-cloning";; *) bad "hint suggests re-cloning (got [$out])";; esac

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
