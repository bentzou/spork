#!/bin/bash
# pr-map.sh — refresh the branch -> PR cache behind status's PR column and
# merged verdict.
#
# Asks `gh` for the repo's open PRs, then probes each branch currently
# checked out in the pool that has no open PR for a *merged* one, and writes
# runtime/pr-map as "<branch>\t<number>\t<state>\t<headRefOid>" lines
# (atomically, via tmp+rename). State is `open` or `merged`; headRefOid is
# the PR's head commit — status compares it to the local branch tip, which
# is what makes the merged verdict squash-proof and reuse-proof. `just
# status` never touches the network, so this runs from the sync path — the
# one place spork already pays for it.
#
# The merged probes are pool-scoped (a handful of branches, one small gh
# call each) rather than repo-wide: merged state only matters for clones we
# can reclaim. pr-<N> convention branches probe by number instead of head
# name, since their local name isn't the upstream ref.
#
# Best-effort by design: no GitHub origin, no gh, or a failed open-PR call
# keeps the previous map, prints one explanatory line (for the sync log),
# and exits 0 so sync never fails on PR decoration. A failed merged probe
# just leaves that branch without a row.

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

if ! open_rows=$(gh pr list --repo "$slug" --limit 500 \
        --json number,headRefName,headRefOid \
        --jq '.[] | .headRefName + "\t" + (.number|tostring) + "\topen\t" + .headRefOid' 2>&1); then
    echo "pr-map: failed ($(echo "$open_rows" | head -1)) — keeping previous map"
    exit 0
fi

# Pool branches worth a merged probe: checked out somewhere, not trunk, not
# detached, not already open. Deduped — two clones on one branch is one probe.
declare -a candidates=()
while IFS= read -r path; do
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    [[ -z "$branch" || "$branch" == "HEAD" || "$branch" == "$TRUNK_BRANCH" ]] && continue
    case "$open_rows" in "$branch	"*|*$'\n'"$branch	"*) continue ;; esac
    for seen in ${candidates[@]+"${candidates[@]}"}; do
        [[ "$seen" == "$branch" ]] && continue 2
    done
    candidates+=("$branch")
done < <(spork_clones)

merged_rows=""
merged_count=0
for branch in ${candidates[@]+"${candidates[@]}"}; do
    if [[ "$branch" =~ ^pr-([0-9]+)$ ]]; then
        # A checkout of someone else's PR: the number is authoritative, the
        # local branch name is not the upstream head — resolve by number.
        row=$(gh pr view "${BASH_REMATCH[1]}" --repo "$slug" \
                --json number,state,headRefOid \
                --jq '(.number|tostring) + "\t" + .state + "\t" + .headRefOid' 2>/dev/null) || continue
        IFS=$'\t' read -r num state oid <<<"$row"
        [[ "$state" == "MERGED" ]] || continue
    else
        row=$(gh pr list --repo "$slug" --head "$branch" --state merged --limit 1 \
                --json number,headRefOid \
                --jq '.[] | (.number|tostring) + "\t" + .headRefOid' 2>/dev/null) || continue
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r num oid <<<"$row"
    fi
    merged_rows+="${branch}	${num}	merged	${oid}"$'\n'
    (( merged_count++ ))
done

{
    [[ -n "$open_rows" ]] && printf '%s\n' "$open_rows"
    [[ -n "$merged_rows" ]] && printf '%s' "$merged_rows"
} > "$RUNTIME_DIR/pr-map.tmp"
mv "$RUNTIME_DIR/pr-map.tmp" "$RUNTIME_DIR/pr-map"
open_count=$(printf '%s' "$open_rows" | grep -c . || true)
echo "pr-map: $open_count open PR(s), $merged_count merged"
