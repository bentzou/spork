#!/bin/bash
# pr-map.sh — refresh the branch -> open-PR cache behind status's PR column.
#
# Asks `gh` for the repo's open PRs and writes runtime/pr-map as
# "<head-branch>\t<number>" lines (atomically, via tmp+rename). `just
# status` never touches the network, so this runs from the sync path — the
# one place spork already pays for it.
#
# Best-effort by design: no GitHub origin, no gh, or a failed call keeps the
# previous map, prints one explanatory line (for the sync log), and exits 0
# so sync never fails on PR decoration.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

slug=$(origin_repo_slug)
if [[ -z "$slug" ]]; then
    echo "pr-map: skipped (ORIGIN_URL is not a GitHub remote)"
    exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "pr-map: skipped (gh not installed)"
    exit 0
fi

if out=$(gh pr list --repo "$slug" --limit 500 \
        --json number,headRefName \
        --jq '.[] | .headRefName + "\t" + (.number|tostring)' 2>&1); then
    printf '%s\n' "$out" > "$RUNTIME_DIR/pr-map.tmp"
    mv "$RUNTIME_DIR/pr-map.tmp" "$RUNTIME_DIR/pr-map"
    echo "pr-map: $(grep -c . "$RUNTIME_DIR/pr-map" | tr -d ' ') open PR(s)"
else
    echo "pr-map: failed ($(echo "$out" | head -1)) — keeping previous map"
fi
