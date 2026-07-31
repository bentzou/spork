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

# A fake gh: answers the open-PR list and the per-branch merged probes as the
# --jq templates would, or fails when GH_FAIL is set (exercising the
# keep-previous-map path). Every invocation is appended to GH_LOG so tests can
# assert which branches were (not) queried.
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
[[ -n "${GH_FAIL:-}" ]] && { echo "boom: api exploded" >&2; exit 1; }
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$*" in
    *"pr view 77"*)  printf '77\tMERGED\tOID77\n' ;;
    *"pr view "*)    echo "no pull requests found" >&2; exit 1 ;;
    *"--head done-branch"*) printf '55\tOID55\n' ;;
    *"--head "*)     : ;;  # branch with no merged PR: empty result
    *"pr list"*)     printf 'feat/x\t12\topen\tOIDX\npr-9\t9\topen\tOID9\n' ;;
esac
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

prmap() { ( cd "$WS" && PATH="$STUB:$PATH" GH_LOG="$STUB/gh.log" ./.spork/tools/pr-map.sh ); }
map_file() { cat "$WS/.spork.local/runtime/pr-map" 2>/dev/null; }

# A local clone in the workspace pool, parked on <branch>.
mkclone() { # mkclone <name> <branch>
    git -C "$WS" init -q "$1"
    git -C "$WS/$1" symbolic-ref HEAD "refs/heads/$2"
    git -C "$WS/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$WS/$1" remote add origin "git@github.com:testorg/testrepo.git"
}

# ---------------------------------------------------------------------------
echo "pr-map.sh: writes the cache from gh, best-effort on every failure mode"

make_workspace "git@github.com:testorg/testrepo.git"
out=$(prmap); rc=$?
check "refresh succeeds" 0 "$rc"
check "map holds gh's rows" "$(printf 'feat/x\t12\topen\tOIDX\npr-9\t9\topen\tOID9')" "$(map_file)"
case "$out" in *2*) ok "summary counts the PRs";; *) bad "summary counts the PRs (got [$out])";; esac

# A failing gh keeps the previous map and still exits 0 (sync must not care).
out=$(GH_FAIL=1 prmap); rc=$?
check "gh failure -> exit 0" 0 "$rc"
check "gh failure keeps previous map" "$(printf 'feat/x\t12\topen\tOIDX\npr-9\t9\topen\tOID9')" "$(map_file)"
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
echo "pr-map.sh: pool-scoped merged pass fills in landed PRs"

make_workspace "git@github.com:testorg/testrepo.git"
mkclone p1 main          # trunk: never a candidate
mkclone p2 done-branch   # merged PR #55
mkclone p3 feat/x        # already in the open map: no probe
mkclone p4 side-quest    # no PR at all: no row
mkclone p5 pr-77         # someone else's PR, checked out by number: merged
: > "$STUB/gh.log"
out=$(prmap); rc=$?
check "refresh succeeds with a pool" 0 "$rc"
map=$(map_file)
case "$map" in *"done-branch	55	merged	OID55"*) ok "merged PR row cached with oid";; *) bad "merged PR row cached with oid (got [$map])";; esac
case "$map" in *"pr-77	77	merged	OID77"*) ok "pr-<n> branch resolved by number";; *) bad "pr-<n> branch resolved by number (got [$map])";; esac
case "$map" in *"side-quest"*) bad "branch without a PR stays out of the map";; *) ok "branch without a PR stays out of the map";; esac
case "$map" in *"feat/x	12	open	OIDX"*) ok "open rows still present";; *) bad "open rows still present (got [$map])";; esac
check "feat/x appears exactly once" 1 "$(printf '%s\n' "$map" | grep -c '^feat/x	')"
log=$(cat "$STUB/gh.log")
case "$log" in *"--head main"*) bad "trunk is never probed";; *) ok "trunk is never probed";; esac
case "$log" in *"--head feat/x"*) bad "open-mapped branch is not re-probed";; *) ok "open-mapped branch is not re-probed";; esac
case "$out" in *merged*) ok "summary mentions merged count";; *) bad "summary mentions merged count (got [$out])";; esac

# ---------------------------------------------------------------------------
echo
echo "unit: origin_repo_slug / origin_web_url / pr_for_branch / pr_info_for_branch"

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

    # pr_info_for_branch: number|state|oid, tolerant of legacy 2-field rows.
    printf 'feat/x\t12\topen\tOIDX\ndone\t55\tmerged\tOID55\nold\t3\n' > "$RUNTIME_DIR/pr-map"
    check "info: open row" "12|open|OIDX" "$(pr_info_for_branch feat/x)"
    check "info: merged row" "55|merged|OID55" "$(pr_info_for_branch done)"
    check "info: legacy row defaults to open" "3|open|" "$(pr_info_for_branch old)"
    check "info: pr-<n> fallback has unknown state" "42||" "$(pr_info_for_branch pr-42)"
    check "info: no pr anywhere -> empty" "" "$(pr_info_for_branch dev)"
    check "pr_for_branch reads 4-field rows" "12" "$(pr_for_branch feat/x)"
) || bad "unit subshell errored"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
