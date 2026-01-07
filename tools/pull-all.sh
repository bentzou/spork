#!/bin/bash
# pull-all.sh — batch update clones in this spork workspace.
#
# Default: git pull --ff-only on each clone on $TRUNK_BRANCH with a clean tree.
#          Prints one line per repo: updated | up to date | skipped: <reason> | failed: <reason>
# --fetch-only: git fetch every clone (no merge, no skip rules).
#
# Usage:
#   pull-all.sh
#   pull-all.sh --fetch-only

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

FETCH_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fetch-only) FETCH_ONLY=1; shift ;;
        -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
        *)            echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

process() {
    local path="$1"

    if (( FETCH_ONLY )); then
        if git -C "$path" fetch --quiet >/dev/null 2>&1; then
            echo "fetched"
        else
            echo "failed: fetch"
        fi
        return
    fi

    local branch before after err
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$branch" != "$TRUNK_BRANCH" ]]; then
        echo "skipped: on branch '${branch:-unknown}'"
        return
    fi

    if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
        echo "skipped: uncommitted changes"
        return
    fi

    before=$(git -C "$path" rev-parse HEAD)
    if ! err=$(git -C "$path" pull --ff-only --quiet 2>&1); then
        err=$(echo "$err" | head -1)
        echo "failed: ${err:-pull failed}"
        return
    fi
    after=$(git -C "$path" rev-parse HEAD)

    if [[ "$before" == "$after" ]]; then
        echo "up to date"
    else
        echo "updated"
    fi
}

paths=()
while IFS= read -r line; do paths+=("$line"); done < <(spork_clones)

if (( ${#paths[@]} == 0 )); then
    echo "No clones of $ORIGIN_URL found under $BASE_DIR." >&2
    exit 0
fi

max_width=0
for path in "${paths[@]}"; do
    name=$(basename "$path")
    (( ${#name} > max_width )) && max_width=${#name}
done

for path in "${paths[@]}"; do
    name=$(basename "$path")
    printf '%-*s  %s\n' "$max_width" "$name" "$(process "$path")"
done
