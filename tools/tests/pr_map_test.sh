#!/bin/bash
# pr_map_test.sh — tests for pr-map.sh (the sync-time branch->PR cache) and
# the _lib helpers behind the status table's PR column (origin_repo_slug /
# origin_web_url / pr_for_branch).
#
# gh is stubbed via PATH so no test touches the network or needs auth.
#
#   tools/tests/pr_map_test.sh
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

WS=""
STUB=$(mktemp -d)
cleanup() { [[ -n "$WS" && -d "$WS" ]] && rm -rf "$WS"; rm -rf "$STUB"; rm -f "$FAILFILE"; }
trap cleanup EXIT

# A fake gh: prints a fixed PR list as the --jq template would, or fails
# when GH_FAIL is set (exercising the keep-previous-map path).
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
[[ -n "${GH_FAIL:-}" ]] && { echo "boom: api exploded" >&2; exit 1; }
printf 'feat/x\t12\npr-9\t9\n'
EOF
chmod +x "$STUB/gh"

make_workspace() { # make_workspace <origin-url>
    WS=$(mktemp -d)
    ln -s "$SPORK_REPO" "$WS/.spork"
    mkdir -p "$WS/.spork.local"
    cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$1
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF
}

prmap() { ( cd "$WS" && PATH="$STUB:$PATH" ./.spork/tools/pr-map.sh ); }
map_file() { cat "$WS/.spork.local/runtime/pr-map" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "pr-map.sh: writes the cache from gh, best-effort on every failure mode"

make_workspace "git@github.com:testorg/testrepo.git"
out=$(prmap); rc=$?
check "refresh succeeds" 0 "$rc"
check "map holds gh's rows" "$(printf 'feat/x\t12\npr-9\t9')" "$(map_file)"
case "$out" in *2*) ok "summary counts the PRs";; *) bad "summary counts the PRs (got [$out])";; esac

# A failing gh keeps the previous map and still exits 0 (sync must not care).
out=$(GH_FAIL=1 prmap); rc=$?
check "gh failure -> exit 0" 0 "$rc"
check "gh failure keeps previous map" "$(printf 'feat/x\t12\npr-9\t9')" "$(map_file)"
case "$out" in *fail*) ok "failure is reported";; *) bad "failure is reported (got [$out])";; esac

# No gh on PATH at all: skip quietly, write nothing.
make_workspace "git@github.com:testorg/testrepo.git"
out=$( cd "$WS" && PATH="/usr/bin:/bin" ./.spork/tools/pr-map.sh ); rc=$?
check "gh absent -> exit 0" 0 "$rc"
check "gh absent -> no map" "" "$(map_file)"
case "$out" in *skip*) ok "skip is reported";; *) bad "skip is reported (got [$out])";; esac

# A non-GitHub origin can't have a slug: skip quietly.
make_workspace "test:not/github.git"
out=$(prmap); rc=$?
check "non-github origin -> exit 0" 0 "$rc"
check "non-github origin -> no map" "" "$(map_file)"

# ---------------------------------------------------------------------------
echo
echo "unit: origin_repo_slug / origin_web_url / pr_for_branch"

make_workspace "git@github.com:testorg/testrepo.git"
( cd "$WS" && . ./.spork/tools/_lib.sh

    check "scp-style slug" "testorg/testrepo" "$(origin_repo_slug)"
    ORIGIN_URL="https://github.com/o/r.git"
    check "https slug" "o/r" "$(origin_repo_slug)"
    ORIGIN_URL="ssh://git@github.com/o/r.git"
    check "ssh slug" "o/r" "$(origin_repo_slug)"
    ORIGIN_URL="git@gitlab.com:o/r.git"
    check "non-github -> empty slug" "" "$(origin_repo_slug)"

    # shellcheck disable=SC2034  # read by the sourced origin_* helpers
    ORIGIN_URL="git@github.com:testorg/testrepo.git"
    check "web url from slug" "https://github.com/testorg/testrepo" "$(origin_web_url)"

    printf 'feat/x\t12\npr-9\t9\n' > "$RUNTIME_DIR/pr-map"
    check "map hit" "12" "$(pr_for_branch feat/x)"
    check "map beats name convention" "9" "$(pr_for_branch pr-9)"
    check "pr-<n> name fallback (not in map)" "777" "$(pr_for_branch pr-777)"
    check "no pr anywhere -> empty" "" "$(pr_for_branch dev)"
    rm "$RUNTIME_DIR/pr-map"
    check "no map file -> fallback still works" "42" "$(pr_for_branch pr-42)"
) || bad "unit subshell errored"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
