#!/bin/bash
# claim.sh — atomically claim the first ready, free clone and print its path.
#
# Usage: claim.sh [OWNER_PID]
#
# Walks clones in workspace order and grabs the first that is ready (on trunk,
# clean, in sync) and not already held by a live claim. The grab is atomic
# (mkdir), so concurrent `jc`/`just claude` invocations land on different
# clones instead of all piling into the first ready one.
#
# OWNER_PID is the process whose liveness keeps the claim held — pass the shell
# (or session) that will run for the life of the work. Defaults to the caller's
# PID. Release with release.sh on normal exit; if the owner dies first, the
# claim goes stale and is reclaimed automatically.
#
# Exits non-zero with a hint on stderr if every ready clone is occupied.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

owner="${1:-$PPID}"

saw_ready=0
while IFS= read -r path; do
    is_ready "$path" || continue
    saw_ready=1
    name=$(basename "${path%/}")
    if try_claim "$name" "$owner"; then
        printf '%s\n' "${path%/}"
        exit 0
    fi
done < <(spork_clones)

if (( saw_ready )); then
    echo "No open clones — every ready one is in use. Run \`just clone\` for another, or \`just status\`." >&2
else
    echo "No open clones in $BASE_DIR (try \`just status\`)." >&2
fi
exit 1
