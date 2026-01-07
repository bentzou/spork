#!/bin/bash
# pick-ready.sh — print the path of the first "ready" clone in this workspace.
#
# Ready means: on trunk, clean working tree, in sync with upstream. Same
# definition as status-all.sh's "ready" state. Exits non-zero with a message
# on stderr if no clone qualifies.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

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

while IFS= read -r path; do
    if is_ready "$path"; then
        printf '%s\n' "${path%/}"
        exit 0
    fi
done < <(spork_clones)

echo "No ready clones in $BASE_DIR (try \`just status\`)." >&2
exit 1
