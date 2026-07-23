#!/bin/bash
# init_test.sh — tests for `init [origin-url]`: bare scaffolding, and the
# one-command bootstrap (config + trunk detection + mirror + first clone).
#
# Harness style follows clean_test.sh: throwaway workspaces under mktemp,
# .spork symlinked at the repo under test. The "remote" is a local bare
# repo, so ls-remote/fetch stay on-disk — no network.
#
#   tools/tests/init_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
# 0 if <path> exists, 1 if not — a $?-safe file probe for check().
exists() { if [[ -e "$1" ]]; then echo 0; else echo 1; fi; }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; rm -f "$FAILFILE"; }
trap cleanup EXIT
TMP=$(mktemp -d)

# Fixture origin: a local bare repo whose default branch is `trunk` — not
# `main`, so a passing test proves detection rather than a lucky default.
ORIGIN="$TMP/origin.git"
git init -q --bare -b trunk "$ORIGIN"
seed="$TMP/seed"
git init -q -b trunk "$seed"
git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$seed" remote add origin "$ORIGIN"
git -C "$seed" push -q origin trunk

new_ws() { # new_ws <name> -> echoes workspace path (reusable across sections)
    local ws="$TMP/$1"
    mkdir -p "$ws"
    [[ -e "$ws/.spork" ]] || ln -s "$SPORK_REPO" "$ws/.spork"
    printf '%s' "$ws"
}

# ---------------------------------------------------------------------------
echo "init: bare run scaffolds only"
ws=$(new_ws bare)
out=$( cd "$ws" && ./.spork/init 2>&1 ); rc=$?
check "bare init exits 0" 0 "$rc"
check "config scaffolded" 0 "$(exists "$ws/.spork.local/config")"
grep -q "YOUR-ORG" "$ws/.spork.local/config"
check "config is the example placeholder" 0 $?
check "justfile scaffolded" 0 "$(exists "$ws/justfile")"
check "no mirror created" 1 "$(exists "$ws/.spork.local/runtime/mirror.git")"
check "no clone created" 1 "$(exists "$ws/p1")"

# ---------------------------------------------------------------------------
echo
echo "init <url>: one-command bootstrap"
ws=$(new_ws full)
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "init <url> exits 0" 0 "$rc"
grep -Fxq "ORIGIN_URL=$ORIGIN" "$ws/.spork.local/config"
check "config carries the origin url" 0 $?
grep -Fxq "TRUNK_BRANCH=trunk" "$ws/.spork.local/config"
check "trunk branch detected from the remote" 0 $?
check "mirror created" 0 "$(exists "$ws/.spork.local/runtime/mirror.git")"
check "first clone created" 0 "$(exists "$ws/p1")"
check "clone is on the detected trunk" "trunk" \
    "$(git -C "$ws/p1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
check "clone has the seeded history" "init" \
    "$(git -C "$ws/p1" log -1 --format=%s 2>/dev/null)"
check "clone origin points at the real remote" "$ORIGIN" \
    "$(git -C "$ws/p1" config --get remote.origin.url 2>/dev/null)"

# ---------------------------------------------------------------------------
echo
echo "init <url>: idempotent re-run"
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "re-run exits 0" 0 "$rc"
check "no second clone" 1 "$(exists "$ws/p2")"
grep -Fxq "ORIGIN_URL=$ORIGIN" "$ws/.spork.local/config"
check "config untouched" 0 $?

# ---------------------------------------------------------------------------
echo
echo "init <url>: fills in a still-placeholder config"
ws=$(new_ws bare)   # reuse the bare-scaffolded workspace from above
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "init over placeholder config exits 0" 0 "$rc"
grep -Fxq "ORIGIN_URL=$ORIGIN" "$ws/.spork.local/config"
check "placeholder replaced with the real url" 0 $?
check "first clone created" 0 "$(exists "$ws/p1")"

# ---------------------------------------------------------------------------
echo
echo "init <url>: conflicting existing config refused"
ws=$(new_ws conflict)
mkdir -p "$ws/.spork.local"
printf 'ORIGIN_URL=git@example.com:other/repo.git\nTRUNK_BRANCH=main\n' \
    > "$ws/.spork.local/config"
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "mismatched url refused" 1 "$rc"
case "$out" in
    *ORIGIN_URL*) ok "refusal names ORIGIN_URL" ;;
    *)            bad "refusal names ORIGIN_URL (got [$out])" ;;
esac
grep -Fxq "ORIGIN_URL=git@example.com:other/repo.git" "$ws/.spork.local/config"
check "existing config left alone" 0 $?
check "no clone created" 1 "$(exists "$ws/p1")"

# ---------------------------------------------------------------------------
echo
echo "init <url>: matching existing config resumes"
ws=$(new_ws resume)
mkdir -p "$ws/.spork.local"
printf 'ORIGIN_URL=%s\nTRUNK_BRANCH=trunk\n' "$ORIGIN" > "$ws/.spork.local/config"
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "matching config resumes fine" 0 "$rc"
check "mirror created" 0 "$(exists "$ws/.spork.local/runtime/mirror.git")"
check "first clone created" 0 "$(exists "$ws/p1")"

# ---------------------------------------------------------------------------
echo
echo "init <url>: unreachable origin fails cleanly"
ws=$(new_ws bad)
out=$( cd "$ws" && ./.spork/init "$TMP/nope.git" 2>&1 ); rc=$?
check "bad url exits non-zero" 1 "$rc"
check "no config written on failure" 1 "$(exists "$ws/.spork.local/config")"
check "no mirror created on failure" 1 "$(exists "$ws/.spork.local/runtime/mirror.git")"

# ---------------------------------------------------------------------------
echo
if [[ -s "$FAILFILE" ]]; then
    echo "FAILURES"
    exit 1
else
    echo "all passed"
fi
