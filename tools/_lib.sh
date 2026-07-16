# shellcheck shell=bash
# Common helpers sourced by every spork tool.
#
# Path layout assumed:
#   <workspace>/
#   ├── .spork           -> /path/to/spork/repo  (symlink, or real dir)
#   ├── .spork.local/                            (workspace-specific)
#   │   ├── config
#   │   └── runtime/
#   └── <clones>/
#
# Exports: SPORK_DIR BASE_DIR LOCAL_DIR RUNTIME_DIR MIRROR_DIR LOG_FILE
#          LOCK_DIR CLAIMS_DIR ORIGIN_URL TRUNK_BRANCH CLONE_PREFIX
# Provides: spork_clones — echoes each subdir of BASE_DIR whose
#           remote.origin.url matches ORIGIN_URL (one absolute path per line,
#           trailing slash).
#           is_ready — true if a clone is on trunk, clean, and in sync.
#           clone_occupied / try_claim / release_claim — clone occupancy via
#           live-PID claims under CLAIMS_DIR (see "Claims" below).
#           spork_procs / proc_attached — live claude/shell processes cwd'd
#           in a clone (see "Live-process detection" below).

# Variables are consumed by sourcing scripts; shellcheck would otherwise flag
# them as unused.
# shellcheck disable=SC2034
SPORK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034
BASE_DIR=$(cd "$SPORK_DIR/.." && pwd)
# shellcheck disable=SC2034
LOCAL_DIR="$BASE_DIR/.spork.local"
RUNTIME_DIR="$LOCAL_DIR/runtime"
# shellcheck disable=SC2034
MIRROR_DIR="$RUNTIME_DIR/mirror.git"
# shellcheck disable=SC2034
LOG_FILE="$RUNTIME_DIR/sync.log"
# shellcheck disable=SC2034
LOCK_DIR="$RUNTIME_DIR/sync.lock"
CLAIMS_DIR="$RUNTIME_DIR/claims"
# Where Claude Code stores per-cwd session logs. Overridable so the session
# readers below can be tested against a fixture root.
# shellcheck disable=SC2034
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

if [[ ! -f "$LOCAL_DIR/config" ]]; then
    echo "Missing $LOCAL_DIR/config — run \`.spork/init\` to create one." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LOCAL_DIR/config"

: "${ORIGIN_URL:?ORIGIN_URL must be set in $LOCAL_DIR/config}"
: "${TRUNK_BRANCH:?TRUNK_BRANCH must be set in $LOCAL_DIR/config}"
# shellcheck disable=SC2034
: "${CLONE_PREFIX:=p}"

mkdir -p "$RUNTIME_DIR"

# Per-repo git settings that keep `just status` cheap on a large worktree.
# core.untrackedCache caches the untracked-file scan, so `git status` does an
# incremental check against cached directory mtimes instead of a full-tree
# lstat sweep — the dominant cost when probing many clones at once (a ~8k-file
# tree drops from ~40ms to ~8ms, and the gap widens under the parallel
# contention of statusing every clone). Idempotent: only writes when unset, so
# it's safe to call on every clone on every run. fsmonitor would be faster
# still but needs a persistent per-repo daemon — a poor trade for an occasional
# status command, so it's deliberately left off.
ensure_status_perf() {
    local path="$1"
    # Only write when unset, so an explicit per-clone override (true or false)
    # is left alone.
    [[ -n "$(git -C "$path" config --get core.untrackedCache 2>/dev/null)" ]] && return 0
    git -C "$path" config core.untrackedCache true 2>/dev/null || true
}

spork_clones() {
    local path url
    shopt -s nullglob
    # The shell glob sorts lexicographically, which interleaves p10 between p1
    # and p2. Pipe through `sort -V` for natural (version) order so numeric
    # suffixes rank numerically — p1, p2, ..., p9, p10. This is the single
    # ordering source for the status table and for pick-ready/claim's
    # "first ready" choice, so fixing it here corrects both.
    for path in "$BASE_DIR"/*/; do
        url=$(git -C "$path" config --get remote.origin.url 2>/dev/null || echo "")
        if [[ "$url" == "$ORIGIN_URL" ]]; then
            echo "$path"
        fi
    done | sort -V
}

# True if a clone is "ready": on TRUNK_BRANCH, clean working tree, and in sync
# with its upstream (no ahead/behind). Same definition as status-all.sh's
# `ready` state. Shared by pick-ready.sh and claim.sh.
is_ready() {
    local path="$1" branch dirty_count ahead behind

    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    [[ "$branch" == "$TRUNK_BRANCH" ]] || return 1

    dirty_count=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    (( dirty_count == 0 )) || return 1

    ahead=0
    behind=0
    if git -C "$path" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        read -r ahead behind < <(git -C "$path" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null || echo "0 0")
    fi
    (( ahead == 0 && behind == 0 ))
}

# Live-process detection
# ----------------------
# A claim (below) records *intent*: a wrapper reserved the clone before
# opening a session. Process detection records *observation*: someone is
# actually sitting in the clone — a hand-launched claude, or a terminal cd'd
# into it — neither of which creates a claim. Occupancy (clone_occupied) is
# the OR of the two, so status-all, pick-ready, and claim.sh all answer
# "can I grab this?" the same way, even for sessions opened outside
# `jc`/`just claude`.
#
# The sweep is one pgrep+lsof pass over the commands worth watching (claude
# plus interactive shells; override SPORK_LIVE_COMMANDS in config to taste).
# pgrep matches the name ps shows — essential, because the claude CLI's
# executable is a bare version number ("2.1.211"), so `lsof -c claude` finds
# nothing. lsof then reports each matched pid's cwd. Best-effort by design:
# if pgrep or lsof fail or are missing, the sweep is empty and occupancy
# degrades to claims-only (the pre-detection behavior).

: "${SPORK_LIVE_COMMANDS:=claude zsh bash fish}"

# One "command<TAB>cwd" line per live watched process owned by this user.
# Costs ~1s of lsof — callers go through spork_procs, which caches.
spork_proc_sweep() {
    local c pid uid pairs="" pids=""
    uid=$(id -u)
    for c in $SPORK_LIVE_COMMANDS; do
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            pairs+="$pid $c"$'\n'
            pids+="$pid,"
        done < <(pgrep -x -u "$uid" "$c" 2>/dev/null)
    done
    [[ -n "$pids" ]] || return 0
    # Join lsof's p<pid>/n<cwd> records back to the pgrep-side names.
    awk '
        FNR == NR { cmd[$1] = $2; next }
        /^p/ { pid = substr($0, 2) }
        /^n/ { print cmd[pid] "\t" substr($0, 2) }
    ' <(printf '%s' "$pairs") <(lsof -a -d cwd -p "${pids%,}" -F pn 2>/dev/null)
}

# Cached sweep for this process, and for any subshell forked after the first
# call (workers inherit the loaded variables). Tests pre-seed a fake sweep by
# exporting SPORK_PROC_SWEEP alongside SPORK_PROC_SWEEP_LOADED=1.
spork_procs() {
    if [[ "${SPORK_PROC_SWEEP_LOADED:-0}" != 1 ]]; then
        SPORK_PROC_SWEEP=$(spork_proc_sweep)
        SPORK_PROC_SWEEP_LOADED=1
    fi
    [[ -n "$SPORK_PROC_SWEEP" ]] && printf '%s\n' "$SPORK_PROC_SWEEP"
    return 0
}

# proc_attached <path> [command] — true if a watched live process has its cwd
# at <path> or anywhere below it (subdir cwds count: monorepo sessions run
# from clone subdirectories). With [command], only processes swept under that
# name count — e.g. `proc_attached "$p" claude`: is a claude running here?
proc_attached() {
    local path="${1%/}" want="${2:-}" cmd cwd
    while IFS=$'\t' read -r cmd cwd; do
        [[ -n "$cwd" ]] || continue
        [[ -n "$want" && "$cmd" != "$want" ]] && continue
        [[ "$cwd" == "$path" || "$cwd" == "$path"/* ]] && return 0
    done < <(spork_procs)
    return 1
}

# Claims
# ------
# A "claim" marks a clone as in use by a live session, so two near-simultaneous
# `jc`/`just claude` invocations can't both grab the same ready clone. A claim
# is the directory CLAIMS_DIR/<clone-name>, holding a `pid` file with the
# owning process. mkdir is atomic, so it doubles as the race-winning lock.
# (Process detection above can't replace this: an lsof snapshot has a wide
# check-to-launch window, so two concurrent grabs would both see "free".)
#
# A claim is "live" iff its owner PID is still running. A claim whose owner has
# died (normal exit that skipped release, crash, SIGKILL) is stale and freely
# reclaimable — so occupancy self-heals with no background reaper. Callers
# should still release explicitly on normal exit to free the clone promptly.

# Owner PID recorded for a claim, or empty if unclaimed/malformed.
claim_owner() {
    local name="$1"
    cat "$CLAIMS_DIR/$name/pid" 2>/dev/null
}

# True if <clone-name> has a live claim (owner process still running).
claim_live() {
    local name="$1" owner
    owner=$(claim_owner "$name")
    [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null
}

# True if a clone path is occupied: a live claim (intent) OR a watched
# process cwd'd inside it (observation — see "Live-process detection").
clone_occupied() {
    local path="${1%/}"
    claim_live "$(basename "$path")" && return 0
    proc_attached "$path"
}

# Atomically claim <clone-name> for <pid>. Succeeds (0) if the clone was free
# or held only a stale claim; fails (1) if a live owner already holds it.
try_claim() {
    local name="$1" pid="$2" d
    d="$CLAIMS_DIR/$name"
    mkdir -p "$CLAIMS_DIR"
    if mkdir "$d" 2>/dev/null; then
        printf '%s\n' "$pid" > "$d/pid"
        return 0
    fi
    # Directory exists: live owner blocks us; a dead owner is reclaimable.
    claim_live "$name" && return 1
    printf '%s\n' "$pid" > "$d/pid"
    return 0
}

# Release <clone-name> if <pid> owns it (or the owner is already dead). Refuses
# to remove a claim held by a different live process, so a late release can't
# clobber a clone someone else has since reclaimed.
release_claim() {
    local name="$1" pid="$2" owner
    [[ -n "$name" ]] || return 1
    owner=$(claim_owner "$name")
    if [[ -n "$owner" && "$owner" != "$pid" ]] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    rm -rf "${CLAIMS_DIR:?}/$name"
}

# Render a non-negative duration in seconds as a compact relative age
# (45s / 12m / 3h / 5d). Shared by the status table and the session log.
format_relative() {
    local s="$1"
    # A caller that sampled `now` before a session wrote its log can pass a
    # small negative delta — clamp it to 0.
    (( s < 0 )) && s=0
    if (( s < 60 ));     then printf '%ss' "$s"
    elif (( s < 3600 )); then printf '%sm' "$(( s / 60 ))"
    elif (( s < 86400 ));then printf '%sh' "$(( s / 3600 ))"
    else                      printf '%sd' "$(( s / 86400 ))"
    fi
}

# Claude sessions
# ---------------
# Claude Code writes one jsonl per session under CLAUDE_PROJECTS_DIR, in a
# directory whose name is the session's cwd with `/` replaced by `-`. These
# readers surface, per clone, when it was last worked in and the title of that
# session — the AGE and SESSION columns in `just status`, and the per-session
# history behind `just log`.

# Latest AI-generated title in a session jsonl, or empty. Titles are appended
# over a session's life as `ai-title` records
# ({"type":"ai-title","aiTitle":"…","sessionId":…}), so the last one wins.
# Best-effort string parse — no jq dependency; anything it can't parse (unknown
# key order, malformed line) degrades to empty rather than failing.
claude_session_title() {
    local file="$1" line title
    [[ -f "$file" ]] || return 0
    line=$(grep -F '"type":"ai-title"' "$file" 2>/dev/null | tail -1)
    [[ -n "$line" ]] || return 0
    # Value runs from `"aiTitle":"` to the record's `","sessionId":"…"` tail;
    # anchoring on that tail tolerates commas/escaped quotes inside the title.
    title=$(sed -n 's/.*"aiTitle":"\(.*\)","sessionId":"[^"]*".*/\1/p' <<<"$line")
    # Fallback for a differently-ordered record (title then has no embedded ").
    [[ -z "$title" ]] && title=$(sed -n 's/.*"aiTitle":"\([^"]*\)".*/\1/p' <<<"$line")
    # Unescape the JSON string escapes a short title can realistically contain.
    title=${title//\\\"/\"}
    title=${title//\\\\/\\}
    printf '%s' "$title"
}

# Every session jsonl belonging to a clone, as "<mtime> <path>" lines, one per
# session — including sessions you've already closed, since each leaves its log
# behind. Unsorted; empty output when the clone has no sessions. Project dirs
# encode the cwd as its absolute path with `/`→`-`; subdir sessions (e.g. a
# monorepo `<repo>-src-app`) count too, so work in a subpath still registers.
#
# Cheap by design: one `stat` for the whole clone, no title parsing. A busy
# clone can have hundreds of logs and a stat-per-file fork was the bulk of
# `just status`'s cost. This is the single source of the "which logs belong to
# this clone" rule — claude_newest_session and `just log` both build on it.
# Session files are UUID-named jsonl (no newlines), and the mtime is the first
# space-delimited field, so callers can split on the first space; a path with
# spaces still survives that split intact (everything after the first space).
claude_clone_session_files() {
    local repo_path="${1%/}"
    local encoded="${repo_path//\//-}"
    local root="$CLAUDE_PROJECTS_DIR"
    [[ -d "$root" ]] || return 0

    local files=() dir
    shopt -s nullglob
    for dir in "$root/$encoded" "$root/$encoded"-*; do
        [[ -d "$dir" ]] || continue
        files+=("$dir"/*.jsonl)
    done
    shopt -u nullglob

    (( ${#files[@]} == 0 )) && return 0

    stat -f '%m %N' "${files[@]}" 2>/dev/null
}

# Newest session (by mtime) for any cwd inside a clone, as "<epoch>|<title>".
# Both empty ("|") when the clone has no sessions. Title is read from that same
# newest file — i.e. the session you most recently touched here.
claude_newest_session() {
    local best=0 best_file="" line mtime file
    while IFS= read -r line; do
        mtime="${line%% *}"
        file="${line#* }"
        (( mtime > best )) && { best=$mtime; best_file=$file; }
    done < <(claude_clone_session_files "$1")

    if (( best > 0 )); then
        printf '%s|%s' "$best" "$(claude_session_title "$best_file")"
    else
        printf '|'
    fi
}
