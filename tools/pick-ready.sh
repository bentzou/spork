#!/bin/bash
# pick-ready.sh — print the path of the first ready, unoccupied clone.
#
# Ready means: on trunk, clean working tree, in sync with upstream (see
# is_ready in _lib.sh). Clones with a live claim are skipped so navigation
# doesn't drop you into a clone someone is already working in. This is the
# read-only picker behind `just go`/`jg`; it does NOT claim — use claim.sh
# (`just claude`/`jc`) when you're about to start a session. Exits non-zero
# with a message on stderr if nothing qualifies.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

while IFS= read -r path; do
    if is_ready "$path" && ! clone_occupied "$path"; then
        printf '%s\n' "${path%/}"
        exit 0
    fi
done < <(spork_clones)

echo "No ready, free clones in $BASE_DIR (try \`just status\`)." >&2
exit 1
