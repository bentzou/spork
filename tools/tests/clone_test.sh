#!/bin/bash
# clone_test.sh — tests for clone.sh: next-number picking, mirror wiring, and
# the one-line summary output.
#
# Same harness style as the other tests: a throwaway workspace with a real
# seeded bare mirror, .spork symlinked at the repo under test. No network.
#
#   tools/tests/clone_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:clone/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

WS=$(mktemp -d)
cleanup() { [[ -d "$WS" ]] && rm -rf "$WS"; rm -f "$FAILFILE"; }
trap cleanup EXIT

ln -s "$SPORK_REPO" "$WS/.spork"
mkdir -p "$WS/.spork.local/runtime"
cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF

# Seed repo -> bare mirror, exactly what sync-setup would leave behind.
seed="$WS/seed"
git init -q "$seed"
git -C "$seed" symbolic-ref HEAD refs/heads/main
echo hello > "$seed/file.txt"
git -C "$seed" add file.txt
git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m init
git clone -q --bare "$seed" "$WS/.spork.local/runtime/mirror.git"
sha=$(git -C "$seed" rev-parse --short HEAD)

clone() { ( cd "$WS" && ./.spork/tools/clone.sh ); }

# ---------------------------------------------------------------------------
echo "clone: one summary line; silent while working"

# No last-sync recorded yet -> the summary carries no freshness parenthetical.
out=$(clone)
check "single output line"       "1" "$(wc -l <<<"$out" | tr -d ' ')"
check "summary line, no synced"  "Cloned p1 → main @ $sha" "$out"

# With a last-sync record, the summary says how fresh the mirror is.
printf '%s 3 pulled= fetched= failed=\n' "$(( $(date +%s) - 7200 ))" \
    > "$WS/.spork.local/runtime/last-sync"
out=$(clone)
check "summary reports mirror freshness" "Cloned p2 → main @ $sha (synced 2h ago)" "$out"

# ---------------------------------------------------------------------------
echo
echo "clone: the clone itself is wired like setup-mirror leaves clones"

check "on trunk"            "main" "$(git -C "$WS/p1" rev-parse --abbrev-ref HEAD)"
check "working tree populated" "hello" "$(cat "$WS/p1/file.txt")"
check "objects shared with the mirror" "$WS/.spork.local/runtime/mirror.git/objects" \
    "$(cat "$WS/p1/.git/objects/info/alternates")"
check "trunk tracks origin" "origin" "$(git -C "$WS/p1" config branch.main.remote)"
check "origin url recorded" "$ORIGIN_URL_FIXTURE" "$(git -C "$WS/p1" remote get-url origin)"

# ---------------------------------------------------------------------------
echo
echo "clone: numbering continues from the highest existing clone"

mkdir "$WS/p9"    # a bare directory with a matching name counts
out=$(clone)
check "skips to max+1" "Cloned p10 → main @ $sha (synced 2h ago)" "$out"

# ---------------------------------------------------------------------------
echo
echo "clone: POST_CLONE still announces itself and runs"

echo "POST_CLONE='touch .post-clone-ran'" >> "$WS/.spork.local/config"
out=$(clone)
check "POST_CLONE line printed" "1" "$(grep -c "Running POST_CLONE" <<<"$out")"
check "POST_CLONE ran in the clone" "1" "$([[ -f "$WS/p11/.post-clone-ran" ]] && echo 1 || echo 0)"
check "summary is the last line" "Cloned p11 → main @ $sha (synced 2h ago)" "$(tail -1 <<<"$out")"

# ---------------------------------------------------------------------------
echo
echo "clone: a count adds that many clones, one summary line each"

out=$( cd "$WS" && ./.spork/tools/clone.sh 3 )
check "three summary lines" "3" "$(grep -c '^Cloned ' <<<"$out")"
for n in 12 13 14; do
    check "p$n created on trunk" "main" "$(git -C "$WS/p$n" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    check "POST_CLONE ran in p$n" "1" "$([[ -f "$WS/p$n/.post-clone-ran" ]] && echo 1 || echo 0)"
done

# A bad count is rejected before anything is created.
out=$( cd "$WS" && ./.spork/tools/clone.sh 2x 2>&1 ); rc=$?
check "non-numeric count rejected" "1" "$(( rc != 0 ? 1 : 0 ))"
check "rejection explains usage" "1" "$(grep -ci "usage" <<<"$out")"
check "zero count rejected" "1" "$( (cd "$WS" && ./.spork/tools/clone.sh 0) >/dev/null 2>&1; echo $(( $? != 0 ? 1 : 0 )) )"
check "no clone created on bad count" 1 "$([[ -e "$WS/p15" ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
