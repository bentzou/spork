#!/bin/bash
# perf_config_test.sh — tests for ensure_status_perf in _lib.sh, the helper
# that enables core.untrackedCache on a clone so `just status`'s `git status`
# probe is incremental instead of a full-tree lstat sweep.
#
#   tools/tests/perf_config_test.sh
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

# Minimal workspace so _lib.sh sources cleanly (it requires .spork.local/config).
WS=$(mktemp -d)
cleanup() { [[ -d "$WS" ]] && rm -rf "$WS"; rm -f "$FAILFILE"; }
trap cleanup EXIT

ln -s "$SPORK_REPO" "$WS/.spork"
mkdir -p "$WS/.spork.local"
cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=test:perf/fixture.git
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF

cd "$WS" || exit 1
# shellcheck source=/dev/null
. ./.spork/tools/_lib.sh

uc() { git -C "$1" config --get core.untrackedCache 2>/dev/null || echo unset; }

# ---------------------------------------------------------------------------
echo "ensure_status_perf: enables untrackedCache, idempotent, respects override"

repo="$WS/clone"
git init -q "$repo"
check "fresh clone has no untrackedCache" "unset" "$(uc "$repo")"

ensure_status_perf "$repo"
check "ensure sets untrackedCache=true" "true" "$(uc "$repo")"

# Second call is a no-op and must not error (function returns 0).
ensure_status_perf "$repo"
check "idempotent: stays true" "true" "$(uc "$repo")"

# An explicit override (even false) is respected, not clobbered back to true.
git -C "$repo" config core.untrackedCache false
ensure_status_perf "$repo"
check "explicit override left alone" "false" "$(uc "$repo")"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
