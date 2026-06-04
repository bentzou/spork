#!/bin/bash
# clone.sh — create the next <prefix><N> clone, sharing objects with the
# mirror.
#
# Picks N = highest-existing-<prefix><N> + 1, where <prefix> comes from
# CLONE_PREFIX in .spork.local/config (default `p`). Inits a new clone wired
# up to the mirror the same way setup-mirror.sh wires existing clones, and
# checks out the trunk branch. Skips network — all objects come from the
# local mirror.

set -euo pipefail
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if [[ ! -d "$MIRROR_DIR" ]]; then
    echo "Mirror $MIRROR_DIR not found. Run \`just sync-setup\` first." >&2
    exit 1
fi

# Find next number: max existing <CLONE_PREFIX><N> + 1.
max=0
shopt -s nullglob
for path in "$BASE_DIR/$CLONE_PREFIX"*/; do
    name=$(basename "$path")
    if [[ "$name" =~ ^${CLONE_PREFIX}([0-9]+)$ ]]; then
        n="${BASH_REMATCH[1]}"
        (( n > max )) && max=n
    fi
done
shopt -u nullglob

next=$(( max + 1 ))
target="$BASE_DIR/$CLONE_PREFIX$next"

if [[ -e "$target" ]]; then
    echo "Target $target already exists." >&2
    exit 1
fi

echo "Creating clone $CLONE_PREFIX$next at $target ..."
git init -q "$target"

mkdir -p "$target/.git/objects/info"
printf '%s\n' "$MIRROR_DIR/objects" > "$target/.git/objects/info/alternates"

git -C "$target" remote add origin "$ORIGIN_URL"
git -C "$target" remote add mirror "$MIRROR_DIR"
git -C "$target" config --replace-all remote.mirror.fetch '+refs/heads/*:refs/remotes/origin/*'

echo "Populating refs from mirror (no network) ..."
git -C "$target" fetch -q mirror

if ! git -C "$target" rev-parse --verify -q "refs/remotes/origin/$TRUNK_BRANCH" >/dev/null; then
    echo "Mirror has no $TRUNK_BRANCH branch — try \`just sync\` first to refresh the mirror." >&2
    exit 1
fi

echo "Checking out $TRUNK_BRANCH ..."
# --no-track + explicit branch config: both `origin` and `mirror` write to
# refs/remotes/origin/*, so git's auto-tracking errors with "ambiguous
# information for ref". We pin tracking to origin ourselves.
git -C "$target" checkout -q --no-track -b "$TRUNK_BRANCH" "origin/$TRUNK_BRANCH"
git -C "$target" config "branch.$TRUNK_BRANCH.remote" origin
git -C "$target" config "branch.$TRUNK_BRANCH.merge"  "refs/heads/$TRUNK_BRANCH"

# Make `just status` fast on this clone from the first run (see _lib.sh).
ensure_status_perf "$target"

# Optional per-workspace bootstrap (POST_CLONE in .spork/config) — e.g.
# `bun install`, `pnpm install && pnpm run prepare`. Runs in the new clone.
if [[ -n "${POST_CLONE:-}" ]]; then
    echo "Running POST_CLONE: $POST_CLONE"
    ( cd "$target" && eval "$POST_CLONE" )
fi

echo "Done: $target"
