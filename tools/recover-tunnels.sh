#!/bin/bash
# Background maintenance: release clones held only by dedicated tunnel terminals.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Export the configured watch list for the Python occupancy check.
export SPORK_LIVE_COMMANDS
while IFS= read -r path; do
    name=$(basename "$path")
    claim_live "$name" && continue
    if output=$(python3 "$SPORK_DIR/tools/close-tunnels.py" "$path" --only-occupant 2>&1); then
        [[ -z "$output" ]] || printf '%s: %s\n' "$name" "$output"
    else
        printf '%s: tunnel recovery skipped: %s\n' "$name" "$output"
    fi
done < <(spork_clones)
