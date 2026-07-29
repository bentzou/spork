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
# Where agent CLIs store session logs. Overridable so the session readers below
# can be tested against fixture roots.
# shellcheck disable=SC2034
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
# shellcheck disable=SC2034
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}"

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

# remote.origin.url of a repo, forking git only when it must. Every picker
# and the status table call this once per workspace directory, so the common
# case — a real .git directory whose config carries the url in plain form —
# is answered by a bash parse of .git/config (microseconds instead of a
# ~10ms git fork). Anything the parse can't see (a gitfile/worktree layout,
# an [include]d config) defers to `git config`, which stays the source of
# truth for exotic setups. A directory with no .git at all answers empty
# with no fork.
clone_origin_url() {
    local path="${1%/}" cfg line key in_origin=0 url=""
    cfg="$path/.git/config"
    if [[ ! -f "$cfg" ]]; then
        [[ -e "$path/.git" ]] || return 0
        git -C "$path" config --get remote.origin.url 2>/dev/null
        return 0
    fi
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"                # ltrim
        case "$line" in
            '[remote "origin"]'*) in_origin=1; continue ;;
            '['*)                 in_origin=0; continue ;;
        esac
        (( in_origin )) || continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"                   # rtrim
        if [[ "$key" == url ]]; then
            url="${line#*=}"
            url="${url#"${url%%[![:space:]]*}"}"               # last wins, like git
        fi
    done < "$cfg"
    if [[ -n "$url" ]]; then
        printf '%s\n' "$url"
    else
        git -C "$path" config --get remote.origin.url 2>/dev/null
    fi
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
        url=$(clone_origin_url "$path")
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

# GitHub coordinates & PR lookup
# ------------------------------
# String-only derivations from ORIGIN_URL — no network, no git. Non-GitHub
# remotes simply answer empty and every PR feature degrades to off.

# "org/repo" when ORIGIN_URL points at github.com (scp, ssh, or https form).
origin_repo_slug() {
    local url="${ORIGIN_URL%.git}"
    case "$url" in
        git@github.com:*)       printf '%s' "${url#git@github.com:}" ;;
        ssh://git@github.com/*) printf '%s' "${url#ssh://git@github.com/}" ;;
        https://github.com/*)   printf '%s' "${url#https://github.com/}" ;;
    esac
}

# The repo's web page (https://github.com/org/repo).
origin_web_url() {
    local slug; slug=$(origin_repo_slug)
    [[ -n "$slug" ]] && printf 'https://github.com/%s' "$slug"
    return 0
}

# PR number for a branch, or empty. Two sources, no network: the cache
# pr-map.sh wrote during the last `just sync` ("<branch>\t<number>" lines,
# checked first so it stays authoritative), then the pr-<N> naming
# convention for branches checked out from someone else's PR.
pr_for_branch() {
    local branch="$1" b n
    if [[ -f "$RUNTIME_DIR/pr-map" ]]; then
        while IFS=$'\t' read -r b n; do
            if [[ "$b" == "$branch" ]]; then printf '%s' "$n"; return 0; fi
        done < "$RUNTIME_DIR/pr-map"
    fi
    [[ "$branch" =~ ^pr-([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
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

: "${SPORK_AGENTS:=claude codex}"
: "${SPORK_LIVE_COMMANDS:=claude codex zsh bash fish}"

agent_valid() {
    local want="$1" a
    for a in $SPORK_AGENTS; do
        [[ "$a" == "$want" ]] && return 0
    done
    return 1
}

agent_label() {
    case "$1" in
        claude) printf 'Claude' ;;
        codex)  printf 'Codex' ;;
        *)      printf '%s' "$1" ;;
    esac
}

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
# (2>/dev/null must precede the input redirection: redirections apply left
# to right, and it's the `<` on a missing pid file that would complain.)
claim_owner() {
    local name="$1" owner=""
    read -r owner 2>/dev/null < "$CLAIMS_DIR/$name/pid" || true
    printf '%s' "$owner"
}

# Agent recorded for a claim, or empty for old/manual claims.
claim_agent() {
    local name="$1" agent=""
    read -r agent 2>/dev/null < "$CLAIMS_DIR/$name/agent" || true
    printf '%s' "$agent"
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
    local name="$1" pid="$2" agent="${3:-claude}" d
    d="$CLAIMS_DIR/$name"
    mkdir -p "$CLAIMS_DIR"
    if mkdir "$d" 2>/dev/null; then
        printf '%s\n' "$pid" > "$d/pid"
        printf '%s\n' "$agent" > "$d/agent"
        return 0
    fi
    # Directory exists: live owner blocks us; a dead owner is reclaimable.
    claim_live "$name" && return 1
    printf '%s\n' "$pid" > "$d/pid"
    printf '%s\n' "$agent" > "$d/agent"
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

# pad_tail <var> <width> <cell> — store in <var> the spaces that grow <cell>
# to <width> columns. Counts characters, not printf's field-width bytes: a
# 1-column multibyte glyph (the "—" placeholder) is 3 UTF-8 bytes, so byte
# counting swallows two spaces of padding and drags every later column left.
# Shared by the status and log tables.
pad_tail() {
    local n=$(( $2 - ${#3} ))
    (( n < 0 )) && n=0
    printf -v "$1" '%*s' "$n" ''
}

# Claude sessions
# ---------------
# Claude Code writes one jsonl per session under CLAUDE_PROJECTS_DIR, in a
# directory whose name is the session's cwd with `/` replaced by `-`. These
# readers surface, per clone, when it was last worked in and the title of that
# session — the AGE and SESSION columns in `just status`, and the per-session
# history behind `just log`.

# Scan backward for everything the readers below need: the last ai-title
# record and the last record timestamp. Emits exactly two lines — the raw ISO
# timestamp, then the raw ai-title record line (either may be empty; records
# are single-line JSON, so line framing is safe). Active transcripts routinely
# grow to several megabytes; reverse order lets us stop near the end instead of
# rereading the whole history on every status refresh.
claude_session_scan() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    LC_ALL=C tail -r "$file" 2>/dev/null | LC_ALL=C awk '
        !have_title && /"type":"ai-title"/ {
            title = $0
            have_title = 1
        }
        !have_ts {
            # Within the first matching line, the last timestamp occurrence
            # still wins. Copies embedded in string values (tool output quoting
            # a record) carry escaped quotes and never match.
            s = $0
            while (match(s, /"timestamp":"[0-9][^"]*"/)) {
                ts = substr(s, RSTART + 13, RLENGTH - 14)
                s = substr(s, RSTART + RLENGTH)
            }
            if (ts != "") have_ts = 1
        }
        have_title && have_ts { print ts; print title; exit }
        END {
            if (!(have_title && have_ts)) { print ts; print title }
        }
    ' || true
}

# Parse the aiTitle value out of one ai-title record line, or empty.
# Best-effort string parse — no jq dependency; anything it can't parse
# (unknown key order, malformed line) degrades to empty rather than failing.
claude_title_parse() {
    local line="$1" title
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

# ISO-8601 UTC timestamp -> epoch seconds (millis dropped); empty in, empty out.
claude_iso_epoch() {
    [[ -n "$1" ]] || return 0
    TZ=UTC0 date -j -f '%Y-%m-%dT%H:%M:%S' "${1:0:19}" +%s 2>/dev/null
}

# Latest AI-generated title in a session jsonl, or empty. Titles are appended
# over a session's life as `ai-title` records
# ({"type":"ai-title","aiTitle":"…","sessionId":…}), so the last one wins.
claude_session_title() {
    local iso line
    { IFS= read -r iso; IFS= read -r line; } < <(claude_session_scan "$1")
    claude_title_parse "$line"
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
claude_clone_session_files_raw() {
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

# Read one agent+clone slice from a command-scoped session inventory. Inventory
# rows are "<mtime><TAB><agent><TAB><clone-path><TAB><session-id><TAB><file>";
# the public clone readers retain their historical "<mtime> <file>" output so
# their callers do not need to know whether an inventory is active.
session_inventory_clone_files() {
    local agent="$1" repo_path="${2%/}"
    local mtime row_agent row_path row_id file
    [[ -f "${SPORK_SESSION_INVENTORY_FILE:-}" ]] || return 0
    while IFS=$'\t' read -r mtime row_agent row_path row_id file; do
        [[ "$row_agent" == "$agent" && "$row_path" == "$repo_path" ]] || continue
        printf '%s %s\n' "$mtime" "$file"
    done < "$SPORK_SESSION_INVENTORY_FILE"
}

# Same slice with the session id kept: "<mtime><TAB><id><TAB><file>" rows.
session_inventory_clone_rows() {
    local agent="$1" repo_path="${2%/}"
    local mtime row_agent row_path row_id file
    [[ -f "${SPORK_SESSION_INVENTORY_FILE:-}" ]] || return 0
    while IFS=$'\t' read -r mtime row_agent row_path row_id file; do
        [[ "$row_agent" == "$agent" && "$row_path" == "$repo_path" ]] || continue
        printf '%s\t%s\t%s\n' "$mtime" "$row_id" "$file"
    done < "$SPORK_SESSION_INVENTORY_FILE"
}

claude_clone_session_files() {
    claude_clone_session_files_raw "$1"
}

# Epoch of the last timestamped record in a session jsonl, or empty when no
# record carries one. This — not mtime — is when you last interacted with the
# session: idle claude processes rewrite their jsonl on every system wake
# without appending records, so mtime clusters on the latest wake and lies
# about interaction recency.
claude_session_last_ts() {
    local iso line
    { IFS= read -r iso; IFS= read -r line; } < <(claude_session_scan "$1")
    claude_iso_epoch "$iso"
}

# Path of a clone's newest session jsonl (by mtime), or empty when it has
# none. The "which session was last active here?" selector, shared by the
# status table and resume-by-clone-name.
claude_newest_session_file() {
    local best=0 best_file="" line mtime file
    while IFS= read -r line; do
        mtime="${line%% *}"
        file="${line#* }"
        (( mtime > best )) && { best=$mtime; best_file=$file; }
    done < <(claude_clone_session_files "$1")
    printf '%s' "$best_file"
}

# Newest session for any cwd inside a clone, as "<epoch>|<title>". The file
# is picked by mtime (cheap, one stat sweep), but the epoch reported is the
# last record timestamp inside it — the last real interaction — falling back
# to mtime for logs that carry no timestamps. Both fields empty ("|") when
# the clone has no sessions. One claude_session_scan pass supplies both the
# epoch and the title.
claude_newest_session() {
    local file iso tline ts
    file=$(claude_newest_session_file "$1")
    if [[ -n "$file" ]]; then
        { IFS= read -r iso; IFS= read -r tline; } < <(claude_session_scan "$file")
        ts=$(claude_iso_epoch "$iso")
        [[ -n "$ts" ]] || ts=$(stat -f %m "$file" 2>/dev/null)
        printf '%s|%s' "$ts" "$(claude_title_parse "$tline")"
    else
        printf '|'
    fi
}

# The cwd a Claude session was launched from: the first record carrying a "cwd"
# field. Best-effort string parse, matching the no-jq style of the other
# readers; an unparseable log degrades to empty rather than failing.
claude_session_cwd() {
    local file="$1" line cwd
    line=$(grep -m1 -F '"cwd":"' "$file" 2>/dev/null)
    [[ -n "$line" ]] || return 0
    cwd=$(sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' <<<"$line")
    cwd=${cwd//\\\//\/}
    cwd=${cwd//\\\\/\\}
    printf '%s' "$cwd"
}

# Codex sessions
# --------------
# Codex stores interactive transcripts under CODEX_SESSIONS_DIR as jsonl files
# grouped by date. Unlike Claude, the directory does not encode cwd, so the
# clone filter reads each transcript's session_meta cwd. This mirrors the
# Claude helpers above and stays file-backed for simple fixtures.

json_string_field() {
    local line="$1" field="$2" value
    local needle="\"${field}\":\""
    [[ "$line" == *"$needle"* ]] || return 0
    value="${line#*"$needle"}"
    value="${value%%\"*}"
    value=${value//\\\"/\"}
    value=${value//\\\//\/}
    value=${value//\\\\/\\}
    printf '%s' "$value"
}

codex_session_meta_line() {
    local file="$1" line=""
    IFS= read -r line 2>/dev/null < "$file" || true
    if [[ "$line" == *'"type":"session_meta"'* ]]; then
        printf '%s' "$line"
    else
        # Older or externally-produced logs may place metadata later.
        grep -m1 -F '"type":"session_meta"' "$file" 2>/dev/null
    fi
}

codex_session_cwd() {
    local file="$1" line
    line=$(codex_session_meta_line "$file")
    json_string_field "$line" cwd
}

# The logical session id for a rollout: session_meta's session_id. Forked or
# resumed rollouts each get their own file (and their own payload "id") but
# carry the original session_id — the handle `codex resume` accepts — so every
# rollout of one logical session answers the same id here.
codex_session_id_from_meta() {
    local line="$1" file="$2" id
    id=$(json_string_field "$line" session_id)
    [[ -z "$id" ]] && id=$(json_string_field "$line" id)
    if [[ -z "$id" ]]; then
        id="${file##*/}"
        id="${id%.jsonl}"
        id="${id#rollout-????-??-??T??-??-??-}"
    fi
    printf '%s' "$id"
}

codex_session_id() {
    local file="$1"
    codex_session_id_from_meta "$(codex_session_meta_line "$file")" "$file"
}

codex_session_title() {
    local file="$1" line title
    # Prefer the first real user message, which matches Codex's own thread
    # preview closely enough for spork's status/log display.
    line=$(awk '/"type":"event_msg"/ && /"type":"user_message"/ { print; exit }' "$file" 2>/dev/null)
    title=$(json_string_field "$line" message)
    [[ -z "$title" ]] && title=$(json_string_field "$line" text)
    [[ -z "$title" ]] && title=$(json_string_field "$(codex_session_meta_line "$file")" title)
    printf '%s' "$title"
}

codex_session_scan() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    LC_ALL=C tail -r "$file" 2>/dev/null | LC_ALL=C awk '
        {
            s = $0
            while (match(s, /"timestamp":"[0-9][^"]*"/)) {
                ts = substr(s, RSTART + 13, RLENGTH - 14)
                s = substr(s, RSTART + RLENGTH)
            }
            if (ts != "") { print ts; exit }
        }
        END { if (ts == "") print "" }
    ' || true
}

codex_iso_epoch() {
    claude_iso_epoch "$1"
}

codex_clone_session_files_raw() {
    local repo_path="${1%/}" root="$CODEX_SESSIONS_DIR"
    [[ -d "$root" ]] || return 0

    local file cwd files=()
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        cwd=$(codex_session_cwd "$file")
        [[ "$cwd" == "$repo_path" || "$cwd" == "$repo_path"/* ]] || continue
        files+=("$file")
    done < <(find "$root" -type f -name '*.jsonl' 2>/dev/null)

    (( ${#files[@]} == 0 )) && return 0
    stat -f '%m %N' "${files[@]}" 2>/dev/null
}

codex_clone_session_files() {
    if [[ -f "${SPORK_SESSION_INVENTORY_FILE:-}" ]]; then
        session_inventory_clone_files codex "$1"
    else
        codex_clone_session_files_raw "$1"
    fi
}

# Build the session inventory used by one top-level command. Claude's directory
# layout is already a cheap cwd index, so its clone readers keep using that
# directly. Codex keeps every transcript in one date tree: scan that tree
# exactly once, map each metadata cwd to a clone with string comparisons, then
# stat all survivors in one call. This avoids the old
# O(clones * all Codex sessions) discovery performed by status/log/resume.
#
# Usage: spork_session_inventory_build <output-file> [<clone-path> ...]
# When paths are omitted, the current workspace's clones are discovered once.
spork_session_inventory_build() {
    local output="$1" path file line cwd id matched i mapping
    shift

    local paths=("$@") codex_files=()
    if (( ${#paths[@]} == 0 )); then
        while IFS= read -r path; do paths+=("${path%/}"); done < <(spork_clones)
    else
        for i in "${!paths[@]}"; do paths[i]="${paths[i]%/}"; done
    fi

    : > "$output"

    if agent_valid codex && [[ -d "$CODEX_SESSIONS_DIR" ]]; then
        mapping="$output.codex-map.$$"
        : > "$mapping"
        while IFS= read -r file; do
            [[ -f "$file" ]] || continue
            # One metadata read serves both the cwd match and the session id.
            line=$(codex_session_meta_line "$file")
            cwd=$(json_string_field "$line" cwd)
            [[ -n "$cwd" ]] || continue
            matched=""
            for path in "${paths[@]}"; do
                if [[ "$cwd" == "$path" || "$cwd" == "$path"/* ]]; then
                    matched="$path"
                    break
                fi
            done
            [[ -n "$matched" ]] || continue
            id=$(codex_session_id_from_meta "$line" "$file")
            codex_files+=("$file")
            printf '%s\t%s\t%s\n' "$matched" "$id" "$file" >> "$mapping"
        done < <(find "$CODEX_SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null)

        if (( ${#codex_files[@]} > 0 )); then
            # Join stat's actual survivors back to their clone paths by file
            # name. A transcript can disappear while an agent prunes history;
            # using stat's returned path avoids shifting every later array
            # index onto the wrong clone in that race.
            awk -F '\t' '
                FNR == NR { repo[$3] = $1; sid[$3] = $2; next }
                {
                    mtime = $0; sub(/ .*/, "", mtime)
                    file = $0; sub(/^[^ ]+ /, "", file)
                    if (file in repo)
                        printf "%s\tcodex\t%s\t%s\t%s\n", mtime, repo[file], sid[file], file
                }
            ' "$mapping" <(stat -f '%m %N' "${codex_files[@]}" 2>/dev/null) >> "$output"
        fi
        rm -f "$mapping"
    fi
}

# Epoch of the last timestamped record, or empty — the Codex twin of
# claude_session_last_ts, and the same cure for the same lie: mtime clusters
# on system wakes, record timestamps mark real interaction.
codex_session_last_ts() {
    codex_iso_epoch "$(codex_session_scan "$1")"
}

codex_newest_session_file() {
    local best=0 best_file="" line mtime file
    while IFS= read -r line; do
        mtime="${line%% *}"
        file="${line#* }"
        (( mtime > best )) && { best=$mtime; best_file=$file; }
    done < <(codex_clone_session_files "$1")
    printf '%s' "$best_file"
}

codex_newest_session() {
    local file iso ts
    file=$(codex_newest_session_file "$1")
    if [[ -n "$file" ]]; then
        iso=$(codex_session_scan "$file")
        ts=$(codex_iso_epoch "$iso")
        [[ -n "$ts" ]] || ts=$(stat -f %m "$file" 2>/dev/null)
        printf '%s|%s' "$ts" "$(codex_session_title "$file")"
    else
        printf '|'
    fi
}

agent_clone_session_files() {
    local agent="$1" path="$2"
    case "$agent" in
        claude) claude_clone_session_files "$path" ;;
        codex)  codex_clone_session_files "$path" ;;
    esac
}

# Session files for a clone with their ids attached, as
# "<mtime><TAB><id><TAB><file>" rows. Claude ids are the file name, so they
# cost nothing; Codex ids ride along in the inventory (built from the same
# metadata read as the cwd), falling back to a per-file read without one.
# This is what lets callers group forked Codex rollouts — many files, one
# logical session — without reopening every transcript.
agent_clone_session_rows() {
    local agent="$1" path="$2" line mtime file id
    case "$agent" in
        claude)
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                mtime="${line%% *}"
                file="${line#* }"
                id="${file##*/}"
                printf '%s\t%s\t%s\n' "$mtime" "${id%.jsonl}" "$file"
            done < <(claude_clone_session_files "$path")
            ;;
        codex)
            if [[ -f "${SPORK_SESSION_INVENTORY_FILE:-}" ]]; then
                session_inventory_clone_rows codex "$path"
            else
                while IFS= read -r line; do
                    [[ -n "$line" ]] || continue
                    mtime="${line%% *}"
                    file="${line#* }"
                    printf '%s\t%s\t%s\n' "$mtime" "$(codex_session_id "$file")" "$file"
                done < <(codex_clone_session_files_raw "$path")
            fi
            ;;
    esac
}

agent_session_title() {
    local agent="$1" file="$2"
    case "$agent" in
        claude) claude_session_title "$file" ;;
        codex)  codex_session_title "$file" ;;
    esac
}

agent_session_id() {
    local agent="$1" file="$2" id
    case "$agent" in
        claude) id="${file##*/}"; printf '%s' "${id%.jsonl}" ;;
        codex)  codex_session_id "$file" ;;
    esac
}

agent_newest_session_file() {
    local agent="$1" path="$2"
    case "$agent" in
        claude) claude_newest_session_file "$path" ;;
        codex)  codex_newest_session_file "$path" ;;
    esac
}

agent_session_cwd() {
    local agent="$1" file="$2"
    case "$agent" in
        claude) claude_session_cwd "$file" ;;
        codex)  codex_session_cwd "$file" ;;
    esac
}

agent_session_last_ts() {
    local agent="$1" file="$2"
    case "$agent" in
        claude) claude_session_last_ts "$file" ;;
        codex)  codex_session_last_ts "$file" ;;
    esac
}

agent_newest_session() {
    local agent="$1" path="$2"
    case "$agent" in
        claude) claude_newest_session "$path" ;;
        codex)  codex_newest_session "$path" ;;
    esac
}

# Newest session for any configured agent in a clone, as
# "<agent>|<epoch>|<title>". Empty agent/epoch/title ("||") when none exist.
spork_newest_session() {
    local path="$1" agent info epoch title best_agent="" best_epoch=0 best_title=""
    for agent in $SPORK_AGENTS; do
        info=$(agent_newest_session "$agent" "$path")
        epoch="${info%%|*}"
        title="${info#*|}"
        [[ -n "$epoch" ]] || continue
        if (( epoch > best_epoch )); then
            best_epoch="$epoch"
            best_agent="$agent"
            best_title="$title"
        fi
    done
    if [[ -n "$best_agent" ]]; then
        printf '%s|%s|%s' "$best_agent" "$best_epoch" "$best_title"
    else
        printf '||'
    fi
}
