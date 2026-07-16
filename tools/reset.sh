#!/bin/bash
# reset.sh — take a clone back to a pristine `open` state.
#
# Usage: reset.sh <clone-name> [--full] [--force]
#
# Default: checkout TRUNK_BRANCH, hard-reset it to origin's tracking ref (the
# freshest ref the mirror knows — no network, `just sync` owns freshness),
# remove untracked files, and delete local branches already merged into that
# base. Refuses to touch a clone someone is in (live claim or detected
# claude/terminal), and refuses to destroy work — a dirty tree, an unmerged
# branch, unpushed trunk commits — unless --force.
#
# --full   also wipes ignored files (git clean -x: node_modules, build
#          caches, local envs) and reruns POST_CLONE to rebuild them.
# --force  proceeds through the loss guard. The hard reset and branch
#          deletions stay reflog-recoverable for a while; clean does not.
#
# Exits 2 on usage error, 1 on refusal (unknown/broken/occupied/would lose
# work) or failure.

set -uo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() { echo "usage: reset.sh <clone-name> [--full] [--force]" >&2; exit 2; }

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

# A repo that can't even report status can't be surgically reset.
if ! git -C "$path" status --porcelain >/dev/null 2>&1; then
    echo "$name is broken — git can't read it, so a reset can't fix it." >&2
    echo "Remove the directory and run \`just clone\` for a fresh clone." >&2
    exit 1
fi

if clone_occupied "$path"; then
    echo "$name is in use — a session or terminal is attached to it. Exit that" >&2
    echo "first (\`just status\` shows who's where)." >&2
    exit 1
fi

# Reset target: origin's tracking ref when the clone has one, else the local
# trunk tip (a clone that's never fetched still resets to a clean tree).
base="refs/heads/$TRUNK_BRANCH"
if git -C "$path" rev-parse -q --verify "refs/remotes/origin/$TRUNK_BRANCH" >/dev/null 2>&1; then
    base="refs/remotes/origin/$TRUNK_BRANCH"
fi

# Loss guard: spell out everything a reset would destroy; any of it refuses
# without --force, so the bare command is always safe to reflex-run.
losses=()
dirty_count=$(git -C "$path" status --porcelain | wc -l | tr -d ' ')
(( dirty_count > 0 )) && losses+=("$dirty_count uncommitted change(s)")
if [[ "$base" == refs/remotes/* ]]; then
    ahead=$(git -C "$path" rev-list --count "$base..refs/heads/$TRUNK_BRANCH" 2>/dev/null || echo 0)
    (( ahead > 0 )) && losses+=("$ahead unpushed commit(s) on $TRUNK_BRANCH")
fi
while read -r b n; do
    [[ -n "$b" ]] || continue
    losses+=("branch $b ($n unmerged commit(s))")
done < <(clone_unmerged_branches "$path" "$base")

if (( ${#losses[@]} > 0 && force == 0 )); then
    echo "$name has work a reset would destroy:" >&2
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

# The loss guard passed (or --force): every non-trunk branch is disposable.
while IFS= read -r b; do
    [[ "$b" == "$TRUNK_BRANCH" ]] && continue
    git -C "$path" branch -qD "$b"
done < <(git -C "$path" for-each-ref refs/heads --format='%(refname:short)')

if (( full )) && [[ -n "${POST_CLONE:-}" ]]; then
    echo "Running POST_CLONE: $POST_CLONE"
    ( cd "$path" && eval "$POST_CLONE" ) || {
        echo "POST_CLONE failed in $name — fix the cause and re-run it there." >&2
        exit 1
    }
fi

echo "Reset $name → $TRUNK_BRANCH @ $(git -C "$path" rev-parse --short HEAD)"
