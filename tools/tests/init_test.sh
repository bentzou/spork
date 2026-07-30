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
check "ledger is flush left with a placeholder note" "1" \
    "$(grep -Ec '^created \.spork\.local/config  \(placeholder' <<<"$out")"
check "justfile row carries its import note" "1" \
    "$(grep -Ec '^created justfile +\(imports \.spork/spork\.just\)' <<<"$out")"
check "no ensured-runtime noise" "0" "$(grep -c "ensured" <<<"$out")"

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

# Output contract: a flush-left created/exists ledger with aligned detail
# parentheticals, one quiet mirror line ("... done", dots only on a tty), the
# clone summary, and a footer naming the clone — no git chatter, no scare lines.
check "ledger: config line with origin and trunk" "1" \
    "$(grep -Fc "created .spork.local/config  (origin $ORIGIN, trunk trunk)" <<<"$out")"
check "ledger: justfile line with import note" "1" \
    "$(grep -Ec '^created justfile +\(imports \.spork/spork\.just\)' <<<"$out")"
check "ledger rows are flush left" "2" "$(grep -c '^created ' <<<"$out")"
check "no ensured-runtime noise" "0" "$(grep -c "ensured" <<<"$out")"
check "mirror line is quiet and completes in place" "1" \
    "$(grep -Fc "Cloning mirror from origin (one-time, full history) ... done" <<<"$out")"
check "git chatter suppressed" "0" "$(grep -c "Cloning into bare repository" <<<"$out")"
check "old clone narration gone" "0" "$(grep -c "No existing local clone found" <<<"$out")"
check "no 'No clones found' scare line" "0" "$(grep -c "No clones of" <<<"$out")"
check "clone summary line present" "1" "$(grep -Ec "^Cloned p1 → trunk @ [0-9a-f]+" <<<"$out")"
check "footer names the fresh clone" "1" \
    "$(grep -Fc "Workspace ready. Try \`just status\`, then \`just claude\` to grab p1." <<<"$out")"
check "no cd hint when already in the workspace" "0" "$(grep -c "cd " <<<"$out")"

# Invoked from outside the workspace, the footer leads with the cd.
out=$( cd "$TMP" && "$ws/.spork/init" "$ORIGIN" 2>&1 ); rc=$?
check "outside invocation exits 0" 0 "$rc"
check "footer leads with cd when run from elsewhere" "1" \
    "$(grep -Fc "Workspace ready. Try \`cd $ws\`, then \`just status\`, then \`just claude\`." <<<"$out")"

# ---------------------------------------------------------------------------
echo
echo "init <url>: idempotent re-run"
out=$( cd "$ws" && ./.spork/init "$ORIGIN" 2>&1 ); rc=$?
check "re-run exits 0" 0 "$rc"
check "no second clone" 1 "$(exists "$ws/p2")"
grep -Fxq "ORIGIN_URL=$ORIGIN" "$ws/.spork.local/config"
check "config untouched" 0 $?
check "re-run ledger: config exists" "1" "$(grep -Ec '^exists  \.spork\.local/config$' <<<"$out")"
check "re-run ledger: justfile exists" "1" "$(grep -Ec '^exists  justfile$' <<<"$out")"
check "re-run: mirror skip drops the long path" "1" \
    "$(grep -Fc "Mirror already exists (skipping clone)." <<<"$out")"
check "re-run footer stays generic" "1" \
    "$(grep -Fc "Workspace ready. Try \`just status\`, then \`just claude\`." <<<"$out")"

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
echo "sync-setup: a failed mirror download says so and shows git's stderr"
ws=$(new_ws mirrorfail)
mkdir -p "$ws/.spork.local"
printf 'ORIGIN_URL=%s\nTRUNK_BRANCH=trunk\n' "$TMP/gone.git" > "$ws/.spork.local/config"
out=$( cd "$ws" && ./.spork/tools/setup-mirror.sh 2>&1 ); rc=$?
check "failed download exits non-zero" 1 "$(( rc != 0 ? 1 : 0 ))"
check "progress line ends in failed" "1" \
    "$(grep -Fc "Cloning mirror from origin (one-time, full history) ... failed" <<<"$out")"
case "$out" in
    *"does not exist"*|*"not found"*|*"No such"*) ok "git's own error passes through" ;;
    *) bad "git's own error passes through (got [$out])" ;;
esac
check "no half-made mirror left behind" 1 "$(exists "$ws/.spork.local/runtime/mirror.git")"

# ---------------------------------------------------------------------------
echo
if [[ -s "$FAILFILE" ]]; then
    echo "FAILURES"
    exit 1
else
    echo "all passed"
fi
