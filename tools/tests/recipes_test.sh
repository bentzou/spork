#!/bin/bash
# recipes_test.sh — tests for the spork.just recipe surface: menu grouping and
# order, private recipes hidden but callable, and CLONE_SUBDIR handling.
#
# Runs `just` against a throwaway workspace built like clone_test's (seeded
# bare mirror, .spork symlinked at the repo under test). No network.
#
#   tools/tests/recipes_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:recipes/fixture.git"

command -v just >/dev/null || { echo "just not installed — skipping" >&2; exit 0; }

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
cp "$SPORK_REPO/examples/justfile.example" "$WS/justfile"
mkdir -p "$WS/.spork.local/runtime"
cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF

seed="$WS/seed"
git init -q "$seed"
git -C "$seed" symbolic-ref HEAD refs/heads/main
mkdir -p "$seed/src/app"
echo hi > "$seed/src/app/f.txt"
git -C "$seed" add .
git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m init
git clone -q --bare "$seed" "$WS/.spork.local/runtime/mirror.git"
( cd "$WS" && ./.spork/tools/clone.sh >/dev/null )

jw() { ( cd "$WS" && just "$@" ); }

# ---------------------------------------------------------------------------
echo "menu: groups list in use, manage, advanced order"

menu=$(jw --list --unsorted)
check "group order" "[use] [manage] [advanced]" \
    "$(grep -oE '\[[a-z]+\]' <<<"$menu" | tr '\n' ' ' | sed 's/ $//')"
check "use holds the daily loop" "claude codex status sync" \
    "$(awk '/\[use\]/{f=1;next} /\[/{f=0} f && NF{print $1}' <<<"$menu" | tr '\n' ' ' | sed 's/ $//')"
check "manage holds pool upkeep" "clean clone pull" \
    "$(awk '/\[manage\]/{f=1;next} /\[/{f=0} f && NF{print $1}' <<<"$menu" | tr '\n' ' ' | sed 's/ $//')"
check "advanced holds session history" "log next resume" \
    "$(awk '/\[advanced\]/{f=1;next} /\[/{f=0} f && NF{print $1}' <<<"$menu" | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
echo
echo "menu: agent-scoped variants and plumbing stay hidden but callable"

for hidden in resume-claude resume-codex log-claude log-codex claim release fetch sync-setup; do
    check "$hidden hidden" "0" "$(grep -c "^    $hidden" <<<"$menu")"
done
check "log-claude still callable" "0" "$(jw log-claude >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
echo
echo "next: prints the open clone's path, honoring CLONE_SUBDIR"

check "next prints the clone root" "$WS/p1" "$(jw next)"
echo "CLONE_SUBDIR=src/app" >> "$WS/.spork.local/config"
check "next appends CLONE_SUBDIR" "$WS/p1/src/app" "$(jw next)"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
