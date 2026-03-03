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

spork_clones() {
    local path url
    shopt -s nullglob
    for path in "$BASE_DIR"/*/; do
        url=$(git -C "$path" config --get remote.origin.url 2>/dev/null || echo "")
        if [[ "$url" == "$ORIGIN_URL" ]]; then
            echo "$path"
        fi
    done
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

# Claims
# ------
# A "claim" marks a clone as in use by a live session, so two near-simultaneous
# `jc`/`just claude` invocations can't both grab the same ready clone. A claim
# is the directory CLAIMS_DIR/<clone-name>, holding a `pid` file with the
# owning process. mkdir is atomic, so it doubles as the race-winning lock.
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

# True if a clone path is occupied (has a live claim).
clone_occupied() {
    local name; name=$(basename "${1%/}")
    claim_live "$name"
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
