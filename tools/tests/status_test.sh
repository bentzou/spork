#!/bin/bash
# status_test.sh — tests for status-all.sh's STATE verdict, which answers
# "can I pick this clone up?" by folding occupancy (live claim OR a claude/
# shell process cwd'd in the clone) and git state into one word:
# `open` (grabbable) / `in use` (occupied) / `parked` (off-trunk and/or
# dirty tree) / pull|push.
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
    export CODEX_SESSIONS_DIR="$WS/codex-sessions"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$CODEX_SESSIONS_DIR"
    # Seed the process sweep as already-loaded-and-empty so occupancy is
    # hermetic too (no real terminal/claude cwds leak in). Tests inject
    # fake processes by overwriting SPORK_PROC_SWEEP.
    export SPORK_PROC_SWEEP="" SPORK_PROC_SWEEP_LOADED=1
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

# Inject a fake process sweep: sweep [<cmd> <path>]... (no args clears it).
sweep() {
    local out=""
    while (( $# )); do
        out+="${out:+$'\n'}$1"$'\t'"$2"
        shift 2
    done
    export SPORK_PROC_SWEEP="$out"
}

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

# pX is on a feature branch -> parked; BRANCH column carries the branch name.
check "feature branch -> parked" "parked" "$(state_of pX)"
check "BRANCH shows the branch, unadorned" "feature" "$(field_of BRANCH pX)"

# p2 ready but claimed by a live session -> in use, never 'open'.
claim_clone p2 "$a" >/dev/null
check "ready, claimed -> in use" "in use" "$(state_of p2)"

# A dirty clone is parked too (parked on trunk implies a dirty tree).
: > "$WS/p3/dirty.txt"
check "dirty, free -> parked" "parked" "$(state_of p3)"
check "dirty trunk BRANCH stays plain" "main" "$(field_of BRANCH p3)"
# ...but a live claim overrides git state: occupancy wins.
claim_clone p3 "$a" >/dev/null
check "dirty, claimed -> in use (claim overrides git state)" "in use" "$(state_of p3)"

# Releasing reverts to the git-derived state — no background reaper.
release_clone p2 "$a" >/dev/null
check "release ready clone -> open again" "open" "$(state_of p2)"
release_clone p3 "$a" >/dev/null
check "release dirty clone -> parked again" "parked" "$(state_of p3)"

# A dirty feature branch is just parked as well.
: > "$WS/pX/dirty.txt"
check "dirty branch -> parked" "parked" "$(state_of pX)"
rm "$WS/pX/dirty.txt" "$WS/p3/dirty.txt"

# ---------------------------------------------------------------------------
echo
echo "status: a live claude/shell process occupies a clone without any claim"

# A shell parked in the clone (hand-opened terminal, no claim) -> in use.
sweep zsh "$WS/p1"
check "shell cwd in clone -> in use" "in use" "$(state_of p1)"

# A process cwd'd in a subdirectory counts (monorepo subdir sessions).
sweep bash "$WS/p1/src/app"
check "shell in subdir -> in use" "in use" "$(state_of p1)"

# A path that merely shares the name prefix must NOT count (p1 vs p1x/p10).
sweep zsh "$WS/p1extra"
check "prefix sibling not matched -> open" "open" "$(state_of p1)"

# A live claude process occupies the clone like any other attachment; the
# SESSION title renders the same either way.
session_for p1 "Fix parser"
sweep claude "$WS/p1"
check "claude cwd -> in use" "in use" "$(state_of p1)"
check "occupied clone shows its title" "Fix parser" "$(field_of SESSION p1)"

sweep

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
echo "status: pull/push when trunk diverges from a configured upstream"

make_workspace 3

# Wire an upstream for main by hand (ref + branch config), as a fetch would.
track_origin() {
    local p="$1" sha="$2"
    git -C "$WS/$p" update-ref refs/remotes/origin/main "$sha"
    git -C "$WS/$p" config branch.main.remote origin
    git -C "$WS/$p" config branch.main.merge refs/heads/main
}
commit_on() { git -C "$WS/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }

# p1 ahead: local main has a commit origin/main lacks -> push.
a1=$(git -C "$WS/p1" rev-parse HEAD)
commit_on p1 "local only"
track_origin p1 "$a1"
check "trunk ahead of upstream -> push" "push" "$(state_of p1)"

# p2 behind: origin/main has a commit local main lacks -> pull.
commit_on p2 "remote only"
b2=$(git -C "$WS/p2" rev-parse HEAD)
git -C "$WS/p2" reset -q --hard HEAD^
track_origin p2 "$b2"
check "trunk behind upstream -> pull" "pull" "$(state_of p2)"

# In-sync tracking is still just open.
track_origin p3 "$(git -C "$WS/p3" rev-parse HEAD)"
check "in sync with upstream -> open" "open" "$(state_of p3)"

# ---------------------------------------------------------------------------
echo
echo "status: PR column maps branches to PR numbers (cache + pr-<n> names)"

make_workspace 2
mkdir -p "$WS/.spork.local/runtime"
printf 'feature\t123\n' > "$WS/.spork.local/runtime/pr-map"

# pX sits on `feature`, which the sync-time cache maps to PR 123.
check "cached branch shows its PR" "#123" "$(field_of PR pX)"
# A pr-<n> checkout needs no cache: the number is in the branch name.
git -C "$WS/p1" checkout -q -b pr-4567
check "pr-<n> branch shows its number" "#4567" "$(field_of PR p1)"
# Open clones on trunk have no PR: the cell stays blank.
check "open trunk clone -> blank PR" "" "$(field_of PR p2)"
# PR renders as its own column, just before the trailing BRANCH.
check "PR sits before BRANCH" "PR BRANCH" "$(status | head -1 | awk '{print $(NF-1), $NF}')"

# ---------------------------------------------------------------------------
echo
echo "status: rows are ordered naturally (p10 after p9, not after p1)"

# A fresh workspace with >9 ready clones exposes lexicographic vs natural order:
# plain glob sort interleaves p10 between p1 and p2; natural sort keeps p1..p10
# in numeric order. Rows render in spork_clones() order, so assert on row index.
make_workspace 10

# 1-based index of clone <name>'s row in the body (header stripped), or empty.
# Capture status once into awk (no pipe) so awk can stop at the match without
# racing the producer into a broken pipe.
row_index_of() {
    local name="$1"
    awk -v repo="$name" '
        function trim(s){ gsub(/^ +| +$/, "", s); return s }
        NR==1 { next }                         # skip header
        { if (trim($1) == repo) { print NR-1; exit } }' <<<"$(status)"
}
check "p1 precedes p2"   "1" "$(( $(row_index_of p1)  < $(row_index_of p2)  ))"
check "p2 precedes p10"  "1" "$(( $(row_index_of p2)  < $(row_index_of p10) ))"
check "p9 precedes p10"  "1" "$(( $(row_index_of p9)  < $(row_index_of p10) ))"

# ---------------------------------------------------------------------------
echo
echo "status: AGE counts from last interaction; active rows order by it too"

make_workspace 3
# Two parked clones with session logs. p1's session started 5 days ago and
# was last written 4 days ago (a long-running session); p2's started and
# ended 1 day ago. touch -t backdates birthtime along with mtime, and a
# later forward touch moves only mtime — so the two act as birth/last knobs.
: > "$WS/p1/dirty.txt"
: > "$WS/p2/dirty.txt"
session_for p1 "Long running work"
session_for p2 "Short recent work"
p1_file="$CLAUDE_PROJECTS_DIR/${WS//\//-}-p1/s.jsonl"
p2_file="$CLAUDE_PROJECTS_DIR/${WS//\//-}-p2/s.jsonl"
touch -t "$(date -v-5d +%Y%m%d%H%M)" "$p1_file"   # birth = last = 5d ago
touch -t "$(date -v-4d +%Y%m%d%H%M)" "$p1_file"   # last write -> 4d ago
touch -t "$(date -v-1d +%Y%m%d%H%M)" "$p2_file"   # birth = last = 1d ago

# AGE is anchored to the session's last write — when you last interacted —
# not its start (p1's fixture separates the two: born 5d ago, written 4d).
check "AGE from last write (not session start)" "4d" "$(field_of AGE p1)"
check "AGE when start and last write coincide"  "1d" "$(field_of AGE p2)"

# Ordering is by last touch, most recent first: p2 (1d) outranks p1 (4d),
# beating the natural p1-then-p2 clone order.
check "recently-touched active row first" "1" \
    "$(( $(row_index_of p2) < $(row_index_of p1) ))"
# A session-less active clone (pX, feature branch) sorts after both.
check "session-less active row last among active" "1" \
    "$(( $(row_index_of p1) < $(row_index_of pX) ))"
# Open clones still close the table.
check "open rows stay last" "1" "$(( $(row_index_of pX) < $(row_index_of p3) ))"

# A wake-style touch — fresh mtime, stale records — must not fake freshness:
# when the file carries timestamped records, AGE and ordering use the last
# one, not the mtime. Rewrite p1's log with a 1h-old record (mtime = now):
# mtime would say "0s"; the record timestamp says "1h", and 1h < p2's 1d so
# p1 now leads the table.
printf '{"type":"user","timestamp":"%s","sessionId":"s"}\n{"type":"ai-title","aiTitle":"Long running work","sessionId":"s"}\n' \
    "$(date -u -v-1H +%Y-%m-%dT%H:%M:%S.000Z)" > "$p1_file"
check "AGE from record timestamp despite fresh mtime" "1h" "$(field_of AGE p1)"
check "ordering follows record timestamp" "1" \
    "$(( $(row_index_of p1) < $(row_index_of p2) ))"

# ---------------------------------------------------------------------------
echo
nfail=$(wc -l < "$FAILFILE" | tr -d ' ')
echo "failed: $nfail"
(( nfail == 0 ))
