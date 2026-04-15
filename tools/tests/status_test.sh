#!/bin/bash
# status_test.sh — tests for status-all.sh's STATE verdict, which answers
# "can I pick this clone up?" by folding a live claim and git state into one
# word: `open` (grabbable) / `in use` (claimed) / branch|local|pull|push.
#
# Same harness style as claim_test.sh: a throwaway workspace with real git
# clones, .spork symlinked at the repo under test. No network, no mirror.
#
#   tools/tests/status_test.sh
#
# Exits non-zero if any assertion fails.

set -uo pipefail

SPORK_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ORIGIN_URL_FIXTURE="test:status/fixture.git"

FAILFILE=$(mktemp)
ok()    { printf '  ok   %s\n' "$1"; }
bad()   { printf '  FAIL %s\n' "$1" >&2; echo x >> "$FAILFILE"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# Background sleepers stand in for live session owners; tracked for cleanup.
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

make_clone() {
    local path="$1" branch="$2"
    git -C "$(dirname "$path")" init -q "$(basename "$path")"
    git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$path" remote add origin "$ORIGIN_URL_FIXTURE"
}

# Workspace with `n_ready` ready clones (p1..) plus one feature-branch clone.
make_workspace() {
    local n_ready="$1" i
    WS=$(mktemp -d)
    # Isolate the Claude session source so AGE/SESSION are hermetic (no real
    # ~/.claude state leaks in). Empty until a test writes a fixture log.
    export CLAUDE_PROJECTS_DIR="$WS/projects"
    mkdir -p "$CLAUDE_PROJECTS_DIR"
    ln -s "$SPORK_REPO" "$WS/.spork"
    mkdir -p "$WS/.spork.local"
    cat > "$WS/.spork.local/config" <<EOF
ORIGIN_URL=$ORIGIN_URL_FIXTURE
TRUNK_BRANCH=main
CLONE_PREFIX=p
EOF
    for (( i=1; i<=n_ready; i++ )); do make_clone "$WS/p$i" main; done
    make_clone "$WS/pX" main
    git -C "$WS/pX" checkout -q -b feature
}

status() { ( cd "$WS" && ./.spork/tools/status-all.sh ); }
# Write an ai-title session log for clone <name>, at the project dir Claude Code
# would use (the clone's absolute cwd with `/` → `-`).
session_for() {
    local name="$1" title="$2" enc
    enc="${WS//\//-}-$name"
    mkdir -p "$CLAUDE_PROJECTS_DIR/$enc"
    printf '{"type":"ai-title","aiTitle":"%s","sessionId":"sid"}\n' "$title" \
        > "$CLAUDE_PROJECTS_DIR/$enc/s.jsonl"
}
# Value of column <col> for clone <name>, parsed by the header's character
# columns rather than by whitespace fields. Robust to column order and to cells
# that contain spaces (SESSION titles, the two-word "in use" state). Relies on
# captured (non-tty) output, which carries no color escapes to shift offsets.
field_of() {
    local col="$1" name="$2"
    status | awk -v col="$col" -v repo="$name" '
        function trim(s){ gsub(/^ +| +$/, "", s); return s }
        NR==1 {
            i = 1
            while (match(substr($0, i), /[^ ]+/)) {
                start = i + RSTART - 1
                labels[++ncol] = substr($0, start, RLENGTH)
                starts[ncol] = start
                i = start + RLENGTH
            }
            next
        }
        {
            if (trim(substr($0, starts[1], starts[2] - starts[1])) != repo) next
            for (k = 1; k <= ncol; k++) if (labels[k] == col) {
                len = (k < ncol) ? starts[k+1] - starts[k] : length($0) - starts[k] + 1
                print trim(substr($0, starts[k], len)); exit
            }
            exit
        }'
}
state_of() { field_of STATE "$1"; }

# Claim/release a clone by name via the sourced helpers (claim.sh only grabs
# *ready* clones, so use try_claim directly to occupy a dirty one too).
claim_clone()   { ( cd "$WS" && . ./.spork/tools/_lib.sh && try_claim "$1" "$2" ); }
release_clone() { ( cd "$WS" && . ./.spork/tools/_lib.sh && release_claim "$1" "$2" ); }

# ---------------------------------------------------------------------------
echo "status: STATE verdict folds occupancy + git state into pickability"
make_workspace 3
a=$(live_pid)

# p1 ready & unclaimed -> the one grabbable state.
check "ready, free -> open" "open" "$(state_of p1)"

# pX is on a feature branch -> parked, git state shows through.
check "feature branch -> branch" "branch" "$(state_of pX)"

# p2 ready but claimed by a live session -> in use, never 'open'.
claim_clone p2 "$a" >/dev/null
check "ready, claimed -> in use" "in use" "$(state_of p2)"

# A dirty clone reports its git state when free...
: > "$WS/p3/dirty.txt"
check "dirty, free -> local" "local" "$(state_of p3)"
# ...but a live claim overrides git state: occupancy wins.
claim_clone p3 "$a" >/dev/null
check "dirty, claimed -> in use (claim overrides git state)" "in use" "$(state_of p3)"

# Releasing reverts to the git-derived state — no background reaper.
release_clone p2 "$a" >/dev/null
check "release ready clone -> open again" "open" "$(state_of p2)"
release_clone p3 "$a" >/dev/null
check "release dirty clone -> local again" "local" "$(state_of p3)"

# ---------------------------------------------------------------------------
echo
echo "status: SESSION column shows the latest title, truncated, blank for open"

# pX is on a feature branch (active) -> its title renders, capped at 56 cols.
long="Investigate the search index rebuild flow and reconcile cache entries across clones"
session_for pX "$long"
out=$(status)
trunc="${long:0:55}…"   # SESSION_MAX-1 chars + ellipsis
check "active clone shows truncated title" "1" "$(grep -Fc -- "$trunc" <<<"$out")"
check "untruncated title is not shown"     "0" "$(grep -Fc -- "$long"  <<<"$out")"
# SESSION and BRANCH occupy their swapped columns: SESSION mid-table, BRANCH last.
check "SESSION column holds the title"     "$trunc"   "$(field_of SESSION pX)"
check "BRANCH is now the trailing column"  "feature"  "$(field_of BRANCH pX)"

# p2 is open (ready, unclaimed) -> no SESSION even with a log on disk, matching
# how AGE is blanked for open clones.
session_for p2 "Stale title on an open clone"
out=$(status)
check "open clone shows no session"        "0" "$(grep -Fc -- "Stale title on an open clone" <<<"$out")"
check "open clone SESSION cell is blank"   ""  "$(field_of SESSION p2)"
check "open clone still shows its branch"  "main" "$(field_of BRANCH p2)"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
