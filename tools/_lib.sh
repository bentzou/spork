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
#          LOCK_DIR ORIGIN_URL TRUNK_BRANCH CLONE_PREFIX
# Provides: spork_clones — echoes each subdir of BASE_DIR whose
#           remote.origin.url matches ORIGIN_URL (one absolute path per line,
#           trailing slash).

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
