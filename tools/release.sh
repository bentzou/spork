#!/bin/bash
# release.sh — release a clone claim made by claim.sh.
#
# Usage: release.sh CLONE [OWNER_PID]
#
# CLONE is a clone path or bare name (e.g. /path/to/p2 or p2). OWNER_PID is the
# process that holds the claim (defaults to the caller's parent). The claim is
# removed unless a *different* live process owns it — so a late release after
# the clone was reclaimed by someone else is a safe no-op.
#
# Releasing is best-effort: a stale claim left by a dead owner is reclaimed on
# the next claim.sh anyway, so this never errors on "nothing to release".

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: release.sh CLONE [OWNER_PID]" >&2; exit 2; }

name=$(basename "${1%/}")
owner="${2:-$PPID}"

release_claim "$name" "$owner"
