#!/bin/bash
# clean.sh — return a clone to an `open` state: latest trunk, clean tree.
#
# Usage: clean.sh <clone-name> [--full] [--force]
#
# Checks out TRUNK_BRANCH, hard-resets it to origin's tracking ref (the
# freshest ref the mirror knows — no network, `just sync` owns freshness),
# and removes untracked files. Local branches are left strictly alone: their
# refs keep whatever work they hold, parked in the background. Refuses to
# touch a clone someone is in (live claim or detected claude/terminal), and
# refuses to discard work only you have — a dirty tree, unpushed trunk
# commits — unless --force.
#
# --full   also wipes ignored files (git clean -x: node_modules, build
#          caches, local envs) and reruns POST_CLONE to rebuild them.
# --force  proceeds through the loss guard. The trunk reset stays
#          reflog-recoverable for a while; removed untracked files do not.
#
# Exits 2 on usage error, 1 on refusal (unknown/broken/occupied/would lose
# work) or failure.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() { echo "usage: clean.sh <clone-name> [--full] [--force]" >&2; exit 2; }

name="" full=0 force=0
for arg in "$@"; do
    case "$arg" in
        --full)  full=1 ;;
        --force) force=1 ;;
        -*)      usage ;;
        *)       [[ -n "$name" ]] && usage
                 name=$(basename "${arg%/}") ;;
    esac
done
[[ -n "$name" ]] || usage

path="$BASE_DIR/$name"
url=$(git -C "$path" config --get remote.origin.url 2>/dev/null || echo "")
if [[ ! -d "$path" || "$url" != "$ORIGIN_URL" ]]; then
    echo "No such clone: $name (try \`just status\`)." >&2
    exit 1
fi

# A repo that can't even report status can't be surgically cleaned.
if ! git -C "$path" status --porcelain >/dev/null 2>&1; then
    echo "$name is broken — git can't read it, so cleaning can't fix it." >&2
    echo "Remove the directory and run \`just clone\` for a fresh clone." >&2
    exit 1
fi

if clone_occupied "$path"; then
    echo "$name is in use — a session or terminal is attached to it. Exit that" >&2
    echo "first (\`just status\` shows who's where)." >&2
    exit 1
fi

# Reset target: origin's tracking ref when the clone has one, else the local
# trunk tip (a clone that's never fetched still comes back to a clean tree).
base="refs/heads/$TRUNK_BRANCH"
if git -C "$path" rev-parse -q --verify "refs/remotes/origin/$TRUNK_BRANCH" >/dev/null 2>&1; then
    base="refs/remotes/origin/$TRUNK_BRANCH"
fi

# Loss guard: only work that exists nowhere but here counts — uncommitted
# changes and unpushed trunk commits. Branch refs survive untouched, so
# branch work is never a loss. Any loss refuses without --force, keeping the
# bare command safe to reflex-run.
losses=()
dirty_count=$(git -C "$path" status --porcelain | wc -l | tr -d ' ')
(( dirty_count > 0 )) && losses+=("$dirty_count uncommitted change(s)")
if [[ "$base" == refs/remotes/* ]]; then
    ahead=$(git -C "$path" rev-list --count "$base..refs/heads/$TRUNK_BRANCH" 2>/dev/null || echo 0)
    (( ahead > 0 )) && losses+=("$ahead unpushed commit(s) on $TRUNK_BRANCH")
fi

if (( ${#losses[@]} > 0 && force == 0 )); then
    echo "$name has work a clean would discard:" >&2
    for l in "${losses[@]}"; do echo "  - $l" >&2; done
    echo "Re-run with --force to discard it." >&2
    exit 1
fi

git -C "$path" checkout -qf "$TRUNK_BRANCH" || exit 1
git -C "$path" reset -q --hard "$base" || exit 1
if (( full )); then
    git -C "$path" clean -fdqx
else
    git -C "$path" clean -fdq
fi

if (( full )) && [[ -n "${POST_CLONE:-}" ]]; then
    echo "Running POST_CLONE: $POST_CLONE"
    ( cd "$path" && eval "$POST_CLONE" ) || {
        echo "POST_CLONE failed in $name — fix the cause and re-run it there." >&2
        exit 1
    }
fi

echo "Cleaned $name → $TRUNK_BRANCH @ $(git -C "$path" rev-parse --short HEAD)"
