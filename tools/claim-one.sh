#!/bin/bash
# claim-one.sh — atomically claim a NAMED clone for an owner and print its path.
#
# Usage: claim-one.sh <clone-name> [OWNER_PID]
#
# The targeted counterpart to claim.sh: where claim.sh grabs the first *ready*
# clone, this claims a specific one regardless of its git state — you're
# deliberately returning to it (e.g. to resume a session in the clone it lives
# in, which may be on a feature branch or dirty). It refuses only if a
# *different* live process already holds the clone.
#
# OWNER_PID is the process whose liveness keeps the claim held — pass the shell
# that runs for the life of the work. Defaults to the caller's parent. Release
# with release.sh on normal exit; a dead owner's claim self-frees.
#
# Exits 2 on usage error, 1 if the clone doesn't exist or is held by another
# live session.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $# -ge 1 && -n "${1:-}" ]] || { echo "usage: claim-one.sh <clone-name> [OWNER_PID]" >&2; exit 2; }

name=$(basename "${1%/}")
owner="${2:-$PPID}"
path="$BASE_DIR/$name"

[[ -d "$path" ]] || { echo "No such clone: $name (try \`just status\`)." >&2; exit 1; }

# try_claim below refuses a clone held by another live *claim*; also refuse
# when a claude is observably running there without one (hand-launched, so it
# never claimed). A bare terminal parked in the clone is fine — you're
# deliberately returning here, and that shell may well be your own.
if proc_attached "$path" claude; then
    echo "$name is in use — a Claude session is already running in it, and only" >&2
    echo "one can run per clone. Exit that session (or pick a clone that's free in" >&2
    echo "\`just log\` / \`just status\`) and retry." >&2
    exit 1
fi

if try_claim "$name" "$owner"; then
    printf '%s\n' "$path"
    exit 0
fi

echo "$name is in use — a Claude session is already attached to it, and only" >&2
echo "one can run per clone. Exit that session (or pick a clone that's free in" >&2
echo "\`just log\` / \`just status\`) and retry." >&2
exit 1
